import Foundation
import Photos

/// Adds the exact captured resource. File data and capture metadata remain intact.
enum CameraPhotoLibrary {
    static func saveOriginal(_ url: URL, capturedAt: Date) async throws -> String? {
        let type = try CameraOriginalStore.type(of: url)
        let identifier = SavedIdentifier()
        try await PHPhotoLibrary.shared().performChanges {
            let asset = PHAssetCreationRequest.forAsset()
            asset.creationDate = capturedAt
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.uniformTypeIdentifier = type.identifier
            options.originalFilename = "光色原片-\(UUID().uuidString.prefix(8)).\(type.suffix)"
            asset.addResource(with: .photo, fileURL: url, options: options)
            identifier.set(asset.placeholderForCreatedAsset?.localIdentifier)
        }
        return identifier.get()
    }
    private final class SavedIdentifier: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ newValue: String?) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
