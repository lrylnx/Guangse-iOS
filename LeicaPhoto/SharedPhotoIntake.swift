import Foundation
import CoreGraphics

/// Sequentially stages the exact bytes supplied by Shortcuts. Thumbnails are
/// separate; they are never substituted for the full-resolution source.
@MainActor
enum SharedPhotoIntake {
    struct Outcome {
        var sources: [PhotoSource] = []
        var unreadable: [Int] = []
    }
    static func receive(count: Int, directory: URL,
                        load: @escaping @Sendable (Int) async throws -> Data,
                        didRead: (PhotoSource, CGImage) -> Void,
                        progress: (Double, String) -> Void) async throws -> Outcome {
        var outcome = Outcome()
        for index in 0..<count {
            try Task.checkCancellation()
            progress(Double(index) / Double(count), "读取分享照片 \(index + 1)/\(count)")
            let id = UUID(), url = directory.appendingPathComponent("source-\(id).image")
            do {
                let data = try await load(index)
                try Task.checkCancellation()
                let thumbnail = try await Task.detached(priority: .userInitiated) {
                    try data.write(to: url, options: .atomic)
                    return try FilterEngine.cgImage(FilterEngine.source(data, maxDimension: 160))
                }.value
                try Task.checkCancellation()
                let source = PhotoSource(id: id, url: url)
                outcome.sources.append(source)
                didRead(source, thumbnail)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: url)
                outcome.unreadable.append(index)
            }
            progress(Double(index + 1) / Double(count), "读取照片完成 \(index + 1)/\(count)")
        }
        return outcome
    }
}
