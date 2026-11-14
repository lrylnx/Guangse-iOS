import Foundation
import AVFoundation
import Combine
import UIKit

struct CameraLens: Identifiable {
    let id: String
    let name: String
}

enum CameraFlash: String, CaseIterable, Identifiable {
    case off, auto, on
    var id: String { rawValue }
    var title: String { self == .off ? "关闭" : self == .auto ? "自动" : "开启" }
    var mode: AVCaptureDevice.FlashMode { self == .off ? .off : self == .auto ? .auto : .on }
}

/// All capture/session/device mutations are confined to sessionQueue; published
/// view state and the final data callback are delivered on the main thread.
final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published private(set) var ready = false
    @Published private(set) var capturing = false
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var selectedLens = ""
    @Published private(set) var flashSupported = false
    @Published private(set) var resolution = ""
    @Published private(set) var status = "正在启动相机"
    @Published private(set) var denied = false
    @Published var errorMessage: String?
    var onCapture: ((Data) -> Void)?

    private let sessionQueue = DispatchQueue(label: "local.guangse.camera", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var devices: [AVCaptureDevice] = []
    private var configured = false
    private var wantsRunning = false
    private var inFlight = false
    private var pendingID: Int64?
    private var pendingData: Data?
    private var observers: [NSObjectProtocol] = []
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.ready = false; self?.status = "相机被暂时占用，恢复后可继续拍摄" }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in self?.resumeSession() })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            if (notification.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.code == .mediaServicesWereReset {
                self.resumeSession()
            } else {
                self.publishFailure("相机暂时无法工作，请关闭后重新打开。")
            }
        })
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: resumeSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.resumeSession() }
                else { self?.showPermissionDenied() }
            }
        default: showPermissionDenied()
        }
    }

    private func showPermissionDenied() {
        DispatchQueue.main.async { self.denied = true; self.ready = false; self.status = "请在系统设置中允许“光色”使用相机" }
    }

    private func resumeSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            do {
                if !self.configured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning && !self.session.isInterrupted
                DispatchQueue.main.async { self.denied = false; self.ready = running; self.status = running ? "" : "等待相机恢复" }
            } catch { self.publishFailure(error.localizedDescription) }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            if !self.inFlight && self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.ready = false }
        }
    }

    private func configure() throws {
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified).devices
        let front = discovered.first(where: { $0.position == .front && $0.deviceType == .builtInWideAngleCamera }) ?? discovered.first(where: { $0.position == .front })
        devices = discovered.filter { $0.position == .back } + (front.map { [$0] } ?? [])
        devices.sort {
            func rank(_ device: AVCaptureDevice) -> Int {
                if device.position == .front { return 3 }
                if device.deviceType == .builtInUltraWideCamera { return 0 }
                if device.deviceType == .builtInTelephotoCamera { return 2 }
                return 1
            }
            return rank($0) < rank($1)
        }
        guard let camera = devices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
            throw CameraError.unavailable
        }
        session.beginConfiguration()
        var committed = false
        defer { if !committed { session.commitConfiguration() } }
        session.sessionPreset = .photo
        let deviceInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else { throw CameraError.unavailable }
        session.addInput(deviceInput)
        session.addOutput(output)
        input = deviceInput
        output.maxPhotoQualityPrioritization = .quality
        output.isLivePhotoCaptureEnabled = false
        session.commitConfiguration()
        committed = true
        configureDimensions(camera)
        configureAutoExposure(camera)
        configured = true
        publishDevice(camera)
    }

    private func configureDimensions(_ device: AVCaptureDevice) {
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { Int64($0.width)*Int64($0.height) < Int64($1.width)*Int64($1.height) }) {
            output.maxPhotoDimensions = largest
        }
    }

    private func configureAutoExposure(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        } catch { /* Capture remains available with the device's automatic defaults. */ }
    }

    private func publishDevice(_ device: AVCaptureDevice) {
        let lensList = devices.map { device -> CameraLens in
            let name: String
            if device.position == .front { name = "前置" }
            else if device.deviceType == .builtInUltraWideCamera { name = "超广角" }
            else if device.deviceType == .builtInTelephotoCamera { name = "长焦" }
            else { name = "主摄" }
            return CameraLens(id: device.uniqueID, name: name)
        }
        let dimensions = output.maxPhotoDimensions
        DispatchQueue.main.async {
            self.lenses = lensList
            self.selectedLens = device.uniqueID
            self.flashSupported = device.hasFlash
            self.resolution = "最高 \(dimensions.width)×\(dimensions.height)"
            self.updateRotation(device)
        }
    }

    func chooseLens(_ id: String) {
        sessionQueue.async { [weak self] in
            guard let self, !self.inFlight, let camera = self.devices.first(where: { $0.uniqueID == id }), self.input?.device.uniqueID != id else { return }
            DispatchQueue.main.async { self.ready = false }
            do {
                let replacement = try AVCaptureDeviceInput(device: camera)
                self.session.beginConfiguration()
                if let previous = self.input { self.session.removeInput(previous) }
                if self.session.canAddInput(replacement) {
                    self.session.addInput(replacement); self.input = replacement
                    self.configureAutoExposure(camera)
                } else if let previous = self.input { self.session.addInput(previous) }
                self.session.commitConfiguration()
                if let device = self.input?.device { self.configureDimensions(device); self.publishDevice(device) }
                DispatchQueue.main.async { self.ready = self.session.isRunning && !self.session.isInterrupted }
            } catch { self.publishFailure(error.localizedDescription) }
        }
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspect
        sessionQueue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            DispatchQueue.main.async { self.updateRotation(device) }
        }
    }

    private func updateRotation(_ device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self, weak coordinator] _, _ in
            DispatchQueue.main.async {
                guard let self, let coordinator, self.rotationCoordinator === coordinator,
                      let connection = self.previewLayer?.connection else { return }
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
        }
    }

    func focus(_ point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.input?.device else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
            } catch { }
        }
    }

    func capture(flash: CameraFlash) {
        guard ready && !capturing else { return }
        capturing = true
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        sessionQueue.async { [weak self] in
            guard let self, !self.inFlight, self.session.isRunning, !self.session.isInterrupted else {
                DispatchQueue.main.async { self?.capturing = false }
                return
            }
            let settings: AVCapturePhotoSettings
            if self.output.availablePhotoCodecTypes.contains(.hevc) { settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]) }
            else { settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) }
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            settings.flashMode = self.output.supportedFlashModes.contains(flash.mode) ? flash.mode : .off
            if self.output.isContentAwareDistortionCorrectionSupported { settings.isAutoContentAwareDistortionCorrectionEnabled = true }
            if let connection = self.output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
            }
            self.inFlight = true; self.pendingID = settings.uniqueID; self.pendingData = nil
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        sessionQueue.async { [weak self] in
            guard let self, self.pendingID == photo.resolvedSettings.uniqueID else { return }
            self.pendingData = data
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self, self.pendingID == resolvedSettings.uniqueID else { return }
            let data = self.pendingData
            self.pendingData = nil; self.pendingID = nil; self.inFlight = false
            if !self.wantsRunning && self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async {
                self.capturing = false
                if let error { self.errorMessage = error.localizedDescription }
                else if let data { self.onCapture?(data) }
                else { self.errorMessage = "未能取得拍摄原片，请再拍一次。" }
            }
        }
    }

    private func publishFailure(_ text: String) {
        DispatchQueue.main.async { self.ready = false; self.status = text; self.errorMessage = text }
    }
    private enum CameraError: LocalizedError {
        case unavailable
        var errorDescription: String? { "当前设备没有可用的相机。模拟器无法实际拍照。" }
    }
}
