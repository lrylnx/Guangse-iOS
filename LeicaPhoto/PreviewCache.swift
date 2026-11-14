import Foundation
import CoreGraphics

struct PreviewKey: Hashable, Sendable {
    let id: UUID
    let settings: EditorSettings?
    init(source: PhotoSource, settings: EditorSettings, original: Bool) {
        id = source.id
        self.settings = original ? nil : settings
    }
    var original: Bool { settings == nil }
}

/// Main-thread display cache has a memory budget. Lossless disk previews in the
/// processor back it, so eviction never means another neural inference.
final class PreviewMemoryCache {
    private final class Key: NSObject {
        let value: PreviewKey
        init(_ value: PreviewKey) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.value == value }
    }
    private let cache = NSCache<Key, CGImage>()
    private var keys: Set<PreviewKey> = []
    init(costLimit: Int = 64 * 1024 * 1024) { cache.totalCostLimit = costLimit }
    func image(for key: PreviewKey) -> CGImage? { cache.object(forKey: Key(key)) }
    func insert(_ image: CGImage, for key: PreviewKey) {
        // Keep original + latest effect PER MODE, not every slider intermediate.
        for stale in keys.filter({ $0.id == key.id && $0.original == key.original && $0.settings?.mode == key.settings?.mode && $0 != key }) {
            cache.removeObject(forKey: Key(stale)); keys.remove(stale)
        }
        cache.setObject(image, forKey: Key(key), cost: image.bytesPerRow * image.height)
        keys.insert(key)
    }
    func remove(_ id: UUID) {
        for key in keys.filter({ $0.id == id }) { cache.removeObject(forKey: Key(key)); keys.remove(key) }
    }
    func removeAll() { cache.removeAllObjects(); keys.removeAll() }
}
