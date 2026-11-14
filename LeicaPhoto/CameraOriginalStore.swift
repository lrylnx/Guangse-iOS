import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Durable outbox until PhotoKit confirms that the unmodified capture is saved.
/// These bytes are never re-encoded or passed through a preview image.
struct CameraOriginalStore: Sendable {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func stage(_ data: Data, id: UUID) throws -> URL {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw PhotoError.invalidImage }
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("capture")
        try data.write(to: url, options: .atomic)
        return url
    }
    func pending() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "capture" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func confirm(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              url.pathExtension == "capture" else { return }
        try FileManager.default.removeItem(at: url)
    }
    static func type(of url: URL) throws -> (identifier: String, suffix: String) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { throw PhotoError.invalidImage }
        let identifier = type as String
        return (identifier, UTType(identifier)?.preferredFilenameExtension ?? "heic")
    }
}
