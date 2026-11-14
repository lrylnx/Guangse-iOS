import SwiftUI
import AVFoundation
import UIKit

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraController()
    @State private var flash: CameraFlash = .off
    let onCapture: (Data) -> Void

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 12) {
                    viewfinder
                    VStack(spacing: 12) {
                        header
                        lensSelector
                        Spacer(minLength: 0)
                        help
                        shutter
                        resolution
                    }.frame(width: min(230, geometry.size.width * 0.32))
                }.padding(8)
            } else {
                VStack(spacing: 16) {
                    header
                    viewfinder
                    lensSelector
                    help
                    shutter
                    resolution
                }.padding(.horizontal, 8)
            }
        }
        .background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .interactiveDismissDisabled(camera.capturing)
        .onAppear {
            camera.onCapture = { data in camera.stop(); dismiss(); onCapture(data) }
            camera.start()
        }
        .onDisappear { camera.stop(); camera.onCapture = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            else { camera.stop() }
        }
        .alert("相机", isPresented: Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })) {
            Button("好", role: .cancel) { camera.errorMessage = nil }
        } message: { Text(camera.errorMessage ?? "") }
    }

    private var header: some View {
        HStack {
            Button { camera.stop(); dismiss() } label: {
                Image(systemName: "xmark").font(.title3).frame(width: 44, height: 44)
            }.disabled(camera.capturing).accessibilityLabel("关闭相机")
            Spacer(minLength: 0)
            Text("拍摄原片").font(.headline)
            Spacer(minLength: 0)
            Menu {
                ForEach(CameraFlash.allCases) { item in Button(item.title) { flash = item } }
            } label: {
                Image(systemName: flash == .off ? "bolt.slash" : "bolt.fill").font(.title3).frame(width: 44, height: 44)
            }.disabled(!camera.flashSupported || camera.capturing).accessibilityLabel("闪光灯：\(flash.title)")
        }
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreview(camera: camera).background(.black)
            if !camera.ready {
                VStack(spacing: 14) {
                    Text(camera.status).font(.subheadline).multilineTextAlignment(.center)
                    if camera.denied {
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.bordered)
                    }
                }.padding(25).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            }
        }.clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var lensSelector: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(camera.lenses) { lens in
                    Button { camera.chooseLens(lens.id) } label: {
                        Text(lens.name).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                            .background(lens.id == camera.selectedLens ? Color.orange : Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(lens.id == camera.selectedLens ? .black : .white)
                    }.disabled(camera.capturing)
                }
            }.padding(.horizontal, 8)
        }.fixedSize(horizontal: false, vertical: true).scrollIndicators(.hidden)
    }

    private var help: some View {
        VStack(spacing: 5) {
            Text("取景为原始画面 · 点按对焦").font(.caption).foregroundStyle(.secondary)
            Text("原片与 AI 效果分别保存到相册").font(.caption).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center)
    }

    private var shutter: some View {
        Button { camera.capture(flash: flash) } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(camera.capturing ? .gray : .white).frame(width: 64, height: 64)
                if camera.capturing { Text("拍摄中").font(.caption2).foregroundStyle(.black) }
            }
        }.disabled(!camera.ready || camera.capturing).accessibilityLabel("拍照，保存原片并生成滤镜照片")
    }

    private var resolution: some View {
        Text(camera.resolution + " · 画质优先").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.camera = camera
        camera.attachPreview(view.previewLayer)
        return view
    }
    func updateUIView(_ uiView: CameraPreviewView, context: Context) { }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    weak var camera: CameraController?
    private let focusMark = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tap)
        focusMark.fillColor = UIColor.clear.cgColor
        focusMark.strokeColor = UIColor.orange.cgColor
        focusMark.lineWidth = 1.5
        focusMark.isHidden = true
        layer.addSublayer(focusMark)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        camera?.focus(point)
        focusMark.path = UIBezierPath(roundedRect: CGRect(x: location.x - 30, y: location.y - 30, width: 60, height: 60), cornerRadius: 5).cgPath
        focusMark.isHidden = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideFocus), object: nil)
        perform(#selector(hideFocus), with: nil, afterDelay: 1)
    }
    @objc private func hideFocus() { focusMark.isHidden = true }
}
