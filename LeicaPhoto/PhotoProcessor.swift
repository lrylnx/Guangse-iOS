import Foundation
import CoreImage

struct EditorSettings: Hashable, Sendable, Codable {
    var preserveHDR = true
    var useAI = true
    var mode: M9AIMode = .distill
    var aiStrength = 1.0
    var filterID = "none"
    var filterStrength = 1.0
    var autoScene = true
    var lux = 300.0
    var cct = 5000.0
    var zoom = 1.0
    var parameters = true
}

struct PhotoSource: Hashable, Sendable {
    let id: UUID
    let url: URL
}

/// One actor owns all full-resolution processing: previews and batch exports
/// cannot run multiple neural networks against different photos concurrently.
actor PhotoProcessor {
    private struct AIKey: Hashable {
        let id: UUID
        let mode: M9AIMode
        let lux: Int
        let cct: Int
        let zoom: Float
        let parameters: Bool
    }
    private let directory: URL
    private var cache: [AIKey: URL] = [:]
    private var order: [AIKey] = []
    private var previews: [PreviewKey: URL] = [:]

    init(directory: URL) { self.directory = directory }

    private func processed(_ source: PhotoSource, settings: EditorSettings,
                           progress: @escaping @Sendable (Double, String) -> Void) throws -> (CIImage, Data) {
        try Task.checkCancellation()
        let data = try Data(contentsOf: source.url, options: .mappedIfSafe)
        let original = try FilterEngine.source(data)
        var image = original
        if settings.useAI && settings.aiStrength > 0 {
            let scene = PhotoScene.read(data)
            let lux = settings.autoScene ? scene.lux : Int(settings.lux)
            let cct = settings.autoScene ? scene.cct : Int(settings.cct)
            let zoom = settings.autoScene ? scene.zoom : Float(settings.zoom)
            let key = AIKey(id: source.id, mode: settings.mode,
                            lux: settings.mode == .full ? lux : 200,
                            cct: settings.mode == .full ? cct : 5500,
                            zoom: settings.mode == .full ? zoom : 1,
                            parameters: settings.mode == .full ? settings.parameters : true)
            let ai: CIImage
            if let url = cache[key], let cached = CIImage(contentsOf: url) {
                ai = cached
                progress(0.80, "读取已生成效果")
                order.removeAll { $0 == key }; order.append(key)
            } else {
                let result: CIImage
                if settings.mode == .distill {
                    result = try M9DistillPipeline.process(original) { fraction, text in progress(fraction * 0.80, text) }
                } else {
                    result = try M9Pipeline.process(original,
                        branch: lux <= 260 || cct >= 4692 ? .high : .low,
                        parameters: settings.parameters, lux: lux, cct: cct,
                        zoom: zoom) { fraction, text in progress(fraction * 0.80, text) }
                }
                try Task.checkCancellation()
                let url = directory.appendingPathComponent("ai-\(UUID().uuidString).png")
                do {
                    try PhotoExport.writePNG(result, to: url, context: FilterEngine.context)
                    try Task.checkCancellation()
                } catch { try? FileManager.default.removeItem(at: url); throw error }
                cache[key] = url
                order.append(key)
                // Keep the latest parameter configuration separately for each AI mode.
                // Switching M9 / M9D must not destroy the other mode.
                for stale in order.filter({ $0.id == key.id && $0.mode == key.mode && $0 != key }) {
                    if let url = cache.removeValue(forKey: stale) { try? FileManager.default.removeItem(at: url) }
                }
                order.removeAll { $0.id == key.id && $0.mode == key.mode && $0 != key }
                guard let cached = CIImage(contentsOf: url) else { throw PhotoError.renderFailed }
                ai = cached
            }
            // The full-M9 architecture may reduce resolution; blend in its output
            // geometry. M9D preserves source dimensions and therefore needs no resize.
            let matched = FilterEngine.normalized(original.transformed(by: CGAffineTransform(
                scaleX: ai.extent.width / original.extent.width,
                y: ai.extent.height / original.extent.height)))
            image = FilterEngine.blend(matched, ai, strength: settings.aiStrength)
        }
        try Task.checkCancellation()
        progress(0.84, "应用色彩滤镜")
        image = try FilterEngine.apply(image,
            filter: PhotoFilter.all.first { $0.id == settings.filterID }, strength: settings.filterStrength)
        return (image, data)
    }

    private func storePreview(_ image: CGImage, key: PreviewKey) throws {
        let url = directory.appendingPathComponent("preview-\(UUID().uuidString).png")
        do {
            if image.bitsPerComponent > 8, image.colorSpace.map({ $0.isHDR() }) == true {
                try HDRPhoto.writePNG(CIImage(cgImage: image), to: url)
            } else {
                try PhotoExport.writePNG(CIImage(cgImage: image), to: url, context: FilterEngine.context)
            }
            try Task.checkCancellation()
        } catch { try? FileManager.default.removeItem(at: url); throw error }
        for stale in Array(previews.keys).filter({ $0.id == key.id && $0.original == key.original && $0.settings?.mode == key.settings?.mode }) {
            if let old = previews.removeValue(forKey: stale) { try? FileManager.default.removeItem(at: old) }
        }
        previews[key] = url
    }

    private func smallImage(_ image: CIImage) throws -> CGImage {
        let scale = min(1, 1600 / max(image.extent.width, image.extent.height))
        let small = FilterEngine.normalized(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        return try FilterEngine.cgImage(small)
    }

    func preview(_ source: PhotoSource, settings: EditorSettings, original: Bool,
                 willRender: @escaping @Sendable () -> Void = {},
                 progress: @escaping @Sendable (Double, String) -> Void) throws -> CGImage {
        try autoreleasepool {
            try Task.checkCancellation()
            let key = PreviewKey(source: source, settings: settings, original: original)
            if let url = previews[key], let image = CIImage(contentsOf: url) {
                // Decode a finished 1600px preview: no AI, LUT, resize or spinner.
                if let space = image.colorSpace, space.isHDR() { return try HDRPhoto.display(image) }
                return try FilterEngine.cgImage(image)
            }
            willRender()
            let image: CIImage
            var hdr: CIImage?
            if original {
                let data = try Data(contentsOf: source.url)
                hdr = try HDRPhoto.source(data)?.image
                image = try FilterEngine.source(data, maxDimension: 1600)
            } else {
                let processed = try processed(source, settings: settings, progress: progress)
                image = processed.0
                if settings.preserveHDR {
                    progress(0.88, "保留原图 HDR")
                    hdr = try HDRPhoto.reconstruct(image, sourceData: processed.1)
                }
            }
            try Task.checkCancellation()
            progress(0.92, "生成显示预览")
            let preview = try hdr.map { try HDRPhoto.display($0) } ?? smallImage(image)
            progress(0.96, "缓存预览")
            try storePreview(preview, key: key)
            progress(1, "预览完成")
            return preview
        }
    }

    func export(_ source: PhotoSource, settings: EditorSettings,
                progress: @escaping @Sendable (Double, String) -> Void) throws -> URL {
        try autoreleasepool {
            let (image, data) = try processed(source, settings: settings, progress: progress)
            try Task.checkCancellation()
            progress(0.88, "准备保存照片")
            let url = directory.appendingPathComponent("光色-\(UUID().uuidString).png")
            do {
                let hdr: CIImage?
                if settings.preserveHDR {
                    progress(0.90, "保留原图 HDR")
                    hdr = try HDRPhoto.reconstruct(image, sourceData: data)
                } else { hdr = nil }
                if let hdr { try HDRPhoto.writePNG(hdr, to: url, sourceData: data) }
                else { try PhotoExport.writePNG(image, to: url, context: FilterEngine.context, sourceData: data) }
                try Task.checkCancellation()
                // Batch-exported photos are ready to preview without processing again.
                let key = PreviewKey(source: source, settings: settings, original: false)
                if previews[key] == nil {
                    do { try storePreview(hdr.map { try HDRPhoto.display($0) } ?? smallImage(image), key: key) }
                    catch is CancellationError { throw CancellationError() }
                    catch { /* Optional preview cache must not fail a finished export. */ }
                }
                return url
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }

    func remove(_ id: UUID) {
        for key in Array(previews.keys).filter({ $0.id == id }) {
            if let url = previews.removeValue(forKey: key) { try? FileManager.default.removeItem(at: url) }
        }
        for key in order.filter({ $0.id == id }) {
            if let url = cache.removeValue(forKey: key) { try? FileManager.default.removeItem(at: url) }
        }
        order.removeAll { $0.id == id }
    }

    func clear() {
        for url in previews.values { try? FileManager.default.removeItem(at: url) }
        previews.removeAll()
        for url in cache.values { try? FileManager.default.removeItem(at: url) }
        cache.removeAll(); order.removeAll()
        M9Models.shared.releaseCachedModels()
        M9DistillModel.shared.releaseCachedModel()
    }
}
