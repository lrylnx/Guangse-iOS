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
    @Published var photos: [ImportedPhoto] = []
    @Published var selectedID: UUID?
    @Published var settings = EditorSettings() { didSet { if settings != oldValue { settingsChanged() } } }
    @Published var preview: UIImage?
    @Published var showingOriginal = false
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

    var selected: ImportedPhoto? { photos.first { $0.id == selectedID } }
    var pendingCount: Int { photos.filter { $0.savedSettings != settings }.count }
    var completedCount: Int { photos.count - pendingCount }
    var busy: Bool { importing || saving || preparingCamera }
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

    func compare() {
        showingOriginal.toggle()
        schedulePreview()
    }

    func schedulePreview() {
        previewTask?.cancel()
        let token = UUID(); previewID = token
        guard let source = selected?.source, !busy else { previewing = false; return }
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
        savePhotos(photos.filter { $0.savedSettings != settings })
    }

    private func savePhotos(_ requested: [ImportedPhoto]) {
        guard !busy, !requested.isEmpty else { return }
        previewTask?.cancel(); previewID = UUID(); previewing = false
        let snapshot = settings, pending = requested
        let token = UUID(); saveID = token
        saving = true; progress = 0; stage = "准备保存 \(pending.count) 张照片"
        saveTask = Task {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                saving = false
                message = "请在系统设置中允许“光色”添加照片，然后重试。"
                schedulePreview()
                return
            }
            var success = 0, failed = 0, originalsSaved = 0
            var lastSaveDate = Date.distantPast
            for (index, photo) in pending.enumerated() {
                if Task.isCancelled { break }
                do {
                    if let backup = photo.cameraBackup {
                        stage = "\(index + 1)/\(pending.count) · 保存拍摄原片"
                        let identifier = try await CameraPhotoLibrary.saveOriginal(backup, capturedAt: photo.capturedAt ?? Date())
                        // PhotoKit success is recorded even if cancellation arrived
                        // while the transaction was in flight.
                        if let i = photos.firstIndex(where: { $0.id == photo.id }) {
                            photos[i].cameraBackup = nil
                            photos[i].assetIdentifier = identifier
                        }
                        try? cameraOriginals?.confirm(backup)
                        originalsSaved += 1
                    }
                    try Task.checkCancellation()
                    let url = try await processor.export(photo.source, settings: snapshot) { [weak observer = self] fraction, text in
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
                    stage = "\(index + 1)/\(pending.count) · 保存到相册"
                    try await PHPhotoLibrary.shared().performChanges {
                        let creation = PHAssetCreationRequest.forAsset()
                        // Explicitly override the imported photo's capture date for
                        // Photos library sorting. Keep source EXIF inside the PNG.
                        creation.creationDate = saveDate
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = url.lastPathComponent
                        options.shouldMoveFile = true
                        creation.addResource(with: .photo, fileURL: url, options: options)
                    }
                    // Record confirmed Photos success before respecting cancellation;
                    // retrying a partial batch will skip these exact settings.
                    if let i = photos.firstIndex(where: { $0.id == photo.id }) {
                        photos[i].savedSettings = snapshot; photos[i].failure = nil
                    }
                    success += 1
                } catch is CancellationError { break } catch {
                    failed += 1
                    if let i = photos.firstIndex(where: { $0.id == photo.id }) { photos[i].failure = error.localizedDescription }
                }
                progress = Double(index + 1) / Double(pending.count)
            }
            let cancelled = Task.isCancelled
            saving = false
            if cancelled { message = "已停止。此次已保存 \(success) 张；再次保存会跳过已成功的照片。" }
            else if failed > 0 {
                let retained = photos.contains { $0.cameraBackup != nil }
                message = "已保存 \(success) 张，\(failed) 张失败。再次点击保存，只会重试未成功的照片。" + (retained ? "未保存的拍摄原片仍在本机暂存。" : "")
            }
            else { message = originalsSaved > 0 ? "已将 \(originalsSaved) 张拍摄原片和 \(success) 张无损效果照保存到相册。" : "已将 \(success) 张无损照片保存到相册。" }
            schedulePreview()
        }
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
        if saving { saveTask?.cancel(); stage = "正在停止，已保存的照片会保留" }
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
        previewCache.removeAll(); displayedPreviewKey = nil
        photos.removeAll(); selectedID = nil; preview = nil; previewing = false
        Task {
            await processor.clear()
            for file in oldSources { try? FileManager.default.removeItem(at: file) }
        }
    }
}
