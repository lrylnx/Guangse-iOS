import SwiftUI
import PhotosUI
import Photos

struct ImportedPhoto: Identifiable {
    let source: PhotoSource
    let thumbnail: UIImage
    var assetIdentifier: String?
    var savedSettings: EditorSettings?
    var failure: String?
    var cameraBackup: URL? = nil
    var capturedAt: Date? = nil
    var id: UUID { source.id }
}

@MainActor
final class PhotoEditorModel: ObservableObject {
    static let shared = PhotoEditorModel()
    @Published private(set) var quickRunning = false
    @Published var quickStatus: String?
    var cameraActive = false
    private var quickTask: Task<Int, Error>?
    @Published var photos: [ImportedPhoto] = []
    @Published var selectedID: UUID?
    @Published var settings = PhotoSettingsStore.load() {
        didSet { if settings != oldValue { PhotoSettingsStore.save(settings); settingsChanged() } }
    }
    @Published var preview: UIImage?
    @Published var showingOriginal = false
    @Published private(set) var comparisonOriginal: UIImage?
    private var comparisonID: UUID?
    private var comparisonTask: Task<Void, Never>?
    @Published var importing = false
    @Published var preparingCamera = false
    @Published var saving = false
    @Published var previewing = false
    @Published var progress = 0.0
    @Published var stage = ""
    @Published var message: String?
    private let previewCache = PreviewMemoryCache()
    private var displayedPreviewKey: PreviewKey?
    private var previewTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var previewID = UUID()
    private var importID = UUID()
    private var saveID = UUID()
    let directory: URL
    private let processor: PhotoProcessor
    private let cameraOriginals: CameraOriginalStore?

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Guangse-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        processor = PhotoProcessor(directory: directory)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cameraOriginals = try? CameraOriginalStore(directory: support.appendingPathComponent("Guangse/PendingCameraOriginals", isDirectory: true))
        // Reclaim only this app's abandoned sessions, never the user's originals.
        let temp = FileManager.default.temporaryDirectory
        if let folders = try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for folder in folders where folder.lastPathComponent.hasPrefix("Guangse-") && folder != directory {
                if let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) > 86400 { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }

    var previewIsHDR: Bool { preview?.cgImage?.colorSpace?.isHDR() == true }
    var selected: ImportedPhoto? { photos.first { $0.id == selectedID } }
    var pendingCount: Int { photos.filter { $0.savedSettings != settings || $0.cameraBackup != nil }.count }
    var completedCount: Int { photos.count - pendingCount }
    private var processing: Bool { importing || saving || preparingCamera }
    var busy: Bool { processing || quickRunning }
    var selectedPosition: String {
        guard let index = photos.firstIndex(where: { $0.id == selectedID }) else { return "" }
        return "\(index + 1) / \(photos.count)"
    }

    func select(_ id: UUID) {
        guard !busy, photos.contains(where: { $0.id == id }) else { return }
        if selectedID == id && !showingOriginal { return }
        selectedID = id
        showingOriginal = false
        schedulePreview()
    }

    private func settingsChanged() {
        guard !busy else { return }
        for index in photos.indices { photos[index].failure = nil }
        showingOriginal = false
        schedulePreview()
    }

    private func prepareComparison(_ source: PhotoSource) {
        guard comparisonID != source.id else { return }
        comparisonTask?.cancel()
        comparisonID = source.id; comparisonOriginal = nil
        comparisonTask = Task {
            do {
                // Independent of the serial AI actor, so holding comparison cannot
                // cancel an inference or queue an original behind one.
                let cg = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: source.url)
                    if let hdr = try? HDRPhoto.source(data), let pixels = try? HDRPhoto.display(hdr.image) { return pixels }
                    return try FilterEngine.cgImage(FilterEngine.source(data, maxDimension: 1600))
                }.value
                try Task.checkCancellation()
                guard comparisonID == source.id else { return }
                comparisonOriginal = UIImage(cgImage: cg)
            } catch { }
        }
    }

    func schedulePreview() {
        previewTask?.cancel()
        let token = UUID(); previewID = token
        guard let source = selected?.source, !busy else { previewing = false; return }
        prepareComparison(source)
        let snapshot = settings, before = showingOriginal
        let key = PreviewKey(source: source, settings: snapshot, original: before)
        previewing = false
        if let cached = previewCache.image(for: key) {
            preview = UIImage(cgImage: cached)
            displayedPreviewKey = key
            return
        }
        progress = 0
        stage = "准备生成预览"
        if displayedPreviewKey?.id != source.id || before {
            preview = selected?.thumbnail
            displayedPreviewKey = nil
        }
        previewTask = Task {
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let cg = try await processor.preview(source, settings: snapshot, original: before,
                    willRender: { [weak observer = self] in
                        Task { @MainActor in
                            guard let self = observer, self.previewID == token, !self.busy,
                                  self.displayedPreviewKey != key else { return }
                            self.previewing = true
                        }
                    }) { [weak observer = self] fraction, text in
                    Task { @MainActor in
                        guard let self = observer, self.previewID == token, !self.saving else { return }
                        self.progress = max(self.progress, min(1, max(0, fraction))); self.stage = text
                    }
                }
                try Task.checkCancellation()
                guard previewID == token else { return }
                previewCache.insert(cg, for: key)
                preview = UIImage(cgImage: cg)
                displayedPreviewKey = key
            } catch is CancellationError { } catch {
                guard previewID == token else { return }
                message = error.localizedDescription
            }
            if previewID == token { previewing = false }
        }
    }

    func importPhotos(_ items: [PhotosPickerItem]) {
        guard !saving, !items.isEmpty else { return }
        importTask?.cancel(); previewTask?.cancel(); previewID = UUID()
        let token = UUID(); importID = token
        importing = true; previewing = false; stage = "正在读取照片"; progress = 0
        importTask = Task {
            var failures = 0
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                if let identifier = item.itemIdentifier, photos.contains(where: { $0.assetIdentifier == identifier }) {
                    progress = Double(index + 1) / Double(items.count)
                    continue
                }
                var importedURL: URL?
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoError.invalidImage }
                    try Task.checkCancellation()
                    let id = UUID(), url = directory.appendingPathComponent("source-\(id).image")
                    importedURL = url
                    let thumbnail = try await Task.detached(priority: .userInitiated) {
                        try data.write(to: url, options: .atomic)
                        let image = try FilterEngine.source(data, maxDimension: 160)
                        return try FilterEngine.cgImage(image)
                    }.value
                    try Task.checkCancellation()
                    photos.append(ImportedPhoto(source: PhotoSource(id: id, url: url), thumbnail: UIImage(cgImage: thumbnail), assetIdentifier: item.itemIdentifier))
                    if selectedID == nil { selectedID = id; preview = UIImage(cgImage: thumbnail) }
                } catch is CancellationError {
                    if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
                    break
                } catch {
                    if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
                    failures += 1
                }
                progress = Double(index + 1) / Double(items.count)
                stage = "读取照片 \(index + 1)/\(items.count)"
            }
            guard importID == token else { return }
            importing = false
            if failures > 0 { message = "有 \(failures) 张照片未能读取，其余照片已加入。" }
            schedulePreview()
        }
    }

    func saveAll() {
        guard !busy, pendingCount > 0 else { return }
        savePhotos(photos.filter { $0.savedSettings != settings || $0.cameraBackup != nil })
    }

    private func savePhotos(_ requested: [ImportedPhoto], quiet: Bool = false) {
        guard !processing, (!quickRunning || quiet), !requested.isEmpty else { return }
        previewTask?.cancel(); previewID = UUID(); previewing = false
        let snapshot = settings, pending = requested
        let token = UUID(); saveID = token
        saving = true; progress = 0; stage = "准备保存 \(pending.count) 张照片"
        saveTask = Task {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                saving = false
                let text = "请在系统设置中允许“光色”添加照片，然后重试。"
                if quiet { quickStatus = text } else { message = text }
                schedulePreview()
                return
            }
            var success = 0, failed = 0, originalsSaved = 0
            var details: [String] = []
            var lastSaveDate = Date.distantPast
            for (index, photo) in pending.enumerated() {
                if Task.isCancelled { break }
                let originalWrite: (() async throws -> Void)? = photo.cameraBackup.map { backup in
                    return {
                        self.stage = "\(index + 1)/\(pending.count) · 保存拍摄原片"
                        let identifier = try await CameraPhotoLibrary.saveOriginal(backup, capturedAt: photo.capturedAt ?? Date())
                        if let i = self.photos.firstIndex(where: { $0.id == photo.id }) {
                            self.photos[i].cameraBackup = nil; self.photos[i].assetIdentifier = identifier
                        }
                        try? self.cameraOriginals?.confirm(backup)
                    }
                }
                let effectWrite: (() async throws -> Void)? = photo.savedSettings == snapshot ? nil : {
                    let url = try await self.processor.export(photo.source, settings: snapshot) { [weak observer = self] fraction, text in
                        Task { @MainActor in
                            guard let self = observer, self.saving, self.saveID == token else { return }
                            self.progress = max(self.progress, (Double(index) + min(0.98, max(0, fraction))) / Double(pending.count))
                            self.stage = "\(index + 1)/\(pending.count) · \(text)"
                        }
                    }
                    defer { try? FileManager.default.removeItem(at: url) }
                    try Task.checkCancellation()
                    let saveDate = max(Date(), lastSaveDate.addingTimeInterval(0.001))
                    lastSaveDate = saveDate
                    self.stage = "\(index + 1)/\(pending.count) · 保存效果照"
                    try await PHPhotoLibrary.shared().performChanges {
                        let creation = PHAssetCreationRequest.forAsset()
                        creation.creationDate = saveDate
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = url.lastPathComponent
                        options.shouldMoveFile = false
                        creation.addResource(with: .photo, fileURL: url, options: options)
                    }
                    if let i = self.photos.firstIndex(where: { $0.id == photo.id }) { self.photos[i].savedSettings = snapshot }
                }
                let outcome = await PhotoSaveTransaction.run(original: originalWrite, effect: effectWrite)
                if outcome.originalSaved { originalsSaved += 1 }
                if outcome.effectSaved { success += 1 }
                var errors: [String] = []
                if let error = outcome.originalError { errors.append("原片：" + Self.saveError(error)) }
                if let error = outcome.effectError { errors.append("效果照：" + Self.saveError(error)) }
                if let i = photos.firstIndex(where: { $0.id == photo.id }) {
                    photos[i].failure = errors.isEmpty ? nil : errors.joined(separator: "；")
                }
                if !errors.isEmpty {
                    failed += 1
                    if details.count < 3 { details.append("第\(index + 1)张 · " + errors.joined(separator: "；")) }
                }
                progress = Double(index + 1) / Double(pending.count)
            }
            saving = false
            let summary = "本次保存原片 \(originalsSaved) 张、效果照 \(success) 张。"
            let status: String
            if Task.isCancelled { status = summary + "已停止，再次保存会跳过已成功的项目。" }
            else if failed > 0 {
                status = summary + "\n" + details.joined(separator: "\n") + "\n可再次保存重试。尚未保存的拍摄原片仍保留在本机。"
            } else { status = summary + "已全部保存到相册。" }
            if quiet { quickStatus = status } else { message = status }
            schedulePreview()
        }
    }

    func generateSharedPhotos(count: Int, load: @escaping @Sendable (Int) async throws -> Data) async throws -> Int {
        guard count > 0 else { throw QuickPhotoError.empty }
        guard !busy, !cameraActive else { throw QuickPhotoError.busy }
        quickRunning = true; quickStatus = nil; message = nil
        previewTask?.cancel(); previewID = UUID(); previewing = false
        let task = Task { try await self.runSharedPhotos(count: count, load: load) }
        quickTask = task
        defer {
            importing = false; quickRunning = false; quickTask = nil
            schedulePreview()
        }
        do {
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        } catch is CancellationError {
            quickStatus = "已停止一键生成；已读取的未保存照片可手动继续保存。"
            throw CancellationError()
        }
    }

    private func runSharedPhotos(count: Int, load: @escaping @Sendable (Int) async throws -> Data) async throws -> Int {
        importing = true; progress = 0; stage = "接收相册分享的照片"
        let snapshot = settings
        var added: [ImportedPhoto] = []
        let received = try await SharedPhotoIntake.receive(count: count, directory: directory, load: load,
            didRead: { source, thumbnail in
                let photo = ImportedPhoto(source: source, thumbnail: UIImage(cgImage: thumbnail), assetIdentifier: nil)
                photos.append(photo); added.append(photo)
                if added.count == 1 {
                    selectedID = source.id; preview = photo.thumbnail; displayedPreviewKey = nil; showingOriginal = false
                }
            }, progress: { fraction, text in progress = fraction; stage = text })
        let unreadable = received.unreadable.count
        importing = false
        try Task.checkCancellation()
        guard !added.isEmpty else {
            quickStatus = "未能读取分享照片，请分享 JPEG、HEIC 或 PNG 照片。"
            throw QuickPhotoError.unreadable
        }
        // Only the shared batch is auto-saved, never older editor selections.
        savePhotos(added, quiet: true)
        if let task = saveTask {
            await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        }
        try Task.checkCancellation()
        let ids = Set(added.map { $0.id })
        let saved = photos.filter { ids.contains($0.id) && $0.savedSettings == snapshot }.count
        if unreadable > 0 || saved != added.count {
            let detail = "分享 \(count) 张，成功保存 \(saved) 张；\(unreadable) 张未能读取。" + (quickStatus.map { "\n" + $0 } ?? "")
            quickStatus = detail
            throw QuickPhotoError.partial(detail)
        }
        quickStatus = "已自动生成并保存 \(saved) 张照片到相册。"
        return saved
    }

    private enum QuickPhotoError: LocalizedError {
        case empty, busy, unreadable, partial(String)
        var errorDescription: String? {
            switch self {
            case .empty: return "没有收到照片。请在快捷指令中将“照片”设为“快捷指令输入”。"
            case .busy: return "光色正在拍照或处理其他照片，请完成后重试。"
            case .unreadable: return "无法读取分享照片，请使用 JPEG、HEIC 或 PNG 照片。"
            case .partial(let detail): return detail
            }
        }
    }

    private static func saveError(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain):\(ns.code)]"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " / \(underlying.domain):\(underlying.code) \(underlying.localizedDescription)"
        }
        return text
    }

    func prepareForCamera() async -> Bool {
        guard !busy else { return false }
        preparingCamera = true
        previewTask?.cancel(); previewID = UUID(); previewing = false
        var granted = false
        defer { preparingCamera = false; if !granted { schedulePreview() } }
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            message = "拍摄后需要保存原片和效果照，请在系统设置中允许“光色”添加照片。"
            return false
        }
        granted = true
        return true
    }

    func acceptCapture(_ data: Data) {
        guard !busy else { return }
        previewTask?.cancel(); previewID = UUID(); previewing = false
        importing = true; progress = 0; stage = "保留拍摄原片"
        importTask = Task {
            defer { if importing { importing = false } }
            do {
                guard let store = cameraOriginals else { throw CaptureImportError.storage }
                let id = UUID(), temp = directory.appendingPathComponent("source-\(id).image")
                let capturedAt = Date()
                let (backup, cg) = try await Task.detached(priority: .userInitiated) {
                    let backup = try store.stage(data, id: id)
                    try data.write(to: temp, options: .atomic)
                    let image = try FilterEngine.source(data, maxDimension: 160)
                    return (backup, try FilterEngine.cgImage(image))
                }.value
                // Retain the durable outbox even if the user stops this operation.
                let photo = ImportedPhoto(source: PhotoSource(id: id, url: temp), thumbnail: UIImage(cgImage: cg),
                    assetIdentifier: nil, cameraBackup: backup, capturedAt: capturedAt)
                photos.append(photo); selectedID = id; preview = UIImage(cgImage: cg)
                displayedPreviewKey = nil; showingOriginal = false
                importing = false
                if Task.isCancelled {
                    message = "原片已暂存，点“保存到相册”可继续处理。"
                } else {
                    // Same settings and PhotoProcessor as importing the exact file.
                    savePhotos([photo])
                }
            } catch {
                message = "拍摄原片未完成保存：\(error.localizedDescription)。已写入的原片会保留供下次恢复。"
            }
        }
    }

    func recoverCameraOriginals() {
        guard !busy, let store = cameraOriginals else { return }
        guard let pending = try? store.pending(), !pending.isEmpty else { return }
        importing = true; stage = "恢复未保存的拍摄原片"; progress = 0
        importTask = Task {
            for (index, backup) in pending.enumerated() {
                if Task.isCancelled { break }
                do {
                    let id = UUID(uuidString: backup.deletingPathExtension().lastPathComponent) ?? UUID()
                    guard !photos.contains(where: { $0.id == id }) else { continue }
                    let temp = directory.appendingPathComponent("source-\(id).image")
                    let cg = try await Task.detached {
                        let data = try Data(contentsOf: backup)
                        try data.write(to: temp, options: .atomic)
                        return try FilterEngine.cgImage(FilterEngine.source(data, maxDimension: 160))
                    }.value
                    let capturedAt = (try? backup.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    photos.append(ImportedPhoto(source: PhotoSource(id: id, url: temp), thumbnail: UIImage(cgImage: cg),
                        assetIdentifier: nil, cameraBackup: backup, capturedAt: capturedAt))
                    if selectedID == nil { selectedID = id; preview = UIImage(cgImage: cg) }
                } catch { }
                progress = Double(index + 1) / Double(pending.count)
            }
            importing = false
            message = "已恢复未完成保存的拍摄原片。点“保存到相册”可继续。"
            schedulePreview()
        }
    }

    private enum CaptureImportError: LocalizedError {
        case storage
        var errorDescription: String? { "无法建立原片暂存目录，请检查设备剩余空间。" }
    }

    func releasePreviewMemory() {
        previewCache.removeAll()
        // Finished previews remain on disk and can be read without reprocessing.
    }

    func cancel() {
        if quickRunning {
            quickTask?.cancel(); saveTask?.cancel(); stage = "正在停止，已保存的照片会保留"
            quickStatus = "已停止一键生成；已读取的未保存照片可手动继续保存。"
        }
        else if saving { saveTask?.cancel(); stage = "正在停止，已保存的照片会保留" }
        else if importing { importTask?.cancel() }
    }

    func remove(_ id: UUID) {
        guard !busy, let index = photos.firstIndex(where: { $0.id == id }) else { return }
        previewTask?.cancel(); previewID = UUID(); previewing = false
        let removed = photos.remove(at: index)
        previewCache.remove(id)
        if selectedID == id {
            selectedID = photos.isEmpty ? nil : photos[min(index, photos.count - 1)].id
            preview = selected?.thumbnail
        }
        Task {
            await processor.remove(id)
            try? FileManager.default.removeItem(at: removed.source.url)
        }
        schedulePreview()
    }

    func clear() {
        guard !busy else { return }
        previewTask?.cancel(); previewID = UUID()
        let oldSources = photos.map { $0.source.url }
        comparisonTask?.cancel(); comparisonID = nil; comparisonOriginal = nil
        previewCache.removeAll(); displayedPreviewKey = nil
        photos.removeAll(); selectedID = nil; preview = nil; previewing = false
        Task {
            await processor.clear()
            for file in oldSources { try? FileManager.default.removeItem(at: file) }
        }
    }
}
