import Foundation
import CoreImage

/// CameraLook CLU1 colour-table stage. Source: APK ToneTable.map/mapScaled.
/// Input/output are encoded sRGB, as in Android's ARGB_8888 Bitmap path.
/// This deliberately does not invent the unavailable native/AI stages.
enum ToneLUT {
    enum Failure: LocalizedError {
        case missing(String), malformed, invalidExtent
        var errorDescription: String? {
            switch self {
            case .missing(let name): return "找不到影调资源：\(name)"
            case .malformed: return "影调资源损坏或格式不支持。"
            case .invalidExtent: return "照片尺寸无法处理。"
            }
        }
    }

    struct Table {
        let dimension: Int
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let values: [SIMD3<Float>]

        init(data: Data) throws {
            let bytes = [UInt8](data)
            func u32(_ offset: Int) -> UInt32 {
                (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                    | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
            }
            func float(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }
            guard bytes.count >= 32, Array(bytes[0..<4]) == Array("CLU1".utf8) else { throw Failure.malformed }
            let n = Int(u32(4))
            guard (2...65).contains(n), bytes.count == 32 + n * n * n * 12 else { throw Failure.malformed }
            let low = SIMD3(float(8), float(12), float(16))
            let high = SIMD3(float(20), float(24), float(28))
            for channel in 0..<3 {
                guard low[channel].isFinite, high[channel].isFinite, low[channel] < high[channel] else { throw Failure.malformed }
            }
            var vertices = [SIMD3<Float>]()
            vertices.reserveCapacity(n * n * n)
            for offset in stride(from: 32, to: bytes.count, by: 12) {
                let v = SIMD3(float(offset), float(offset + 4), float(offset + 8))
                guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { throw Failure.malformed }
                vertices.append(v)
            }
            dimension = n
            minimum = low
            maximum = high
            values = vertices
        }

        /// Six tetrahedra, red axis fastest; matches ToneTable rather than
        /// Core Image's trilinear CIColorCube sampling.
        @inline(__always) func map(_ input: SIMD3<Float>) -> SIMD3<Float> {
            let n = dimension
            let normalized = (input - minimum) / (maximum - minimum)
            let r = ToneLUT.clamp(normalized.x) * Float(n - 1)
            let g = ToneLUT.clamp(normalized.y) * Float(n - 1)
            let b = ToneLUT.clamp(normalized.z) * Float(n - 1)
            let ri = min(n - 2, Int(r)), gi = min(n - 2, Int(g)), bi = min(n - 2, Int(b))
            let fr = r - Float(ri), fg = g - Float(gi), fb = b - Float(bi)
            let first: Int, second: Int
            let a: Float, c: Float, d: Float
            if fr >= fg {
                if fg >= fb { first = 1; second = 1 + n; a = fr; c = fg; d = fb }
                else if fr >= fb { first = 1; second = 1 + n * n; a = fr; c = fb; d = fg }
                else { first = n * n; second = n * n + 1; a = fb; c = fr; d = fg }
            } else {
                if fr >= fb { first = n; second = n + 1; a = fg; c = fr; d = fb }
                else if fg >= fb { first = n; second = n + n * n; a = fg; c = fb; d = fr }
                else { first = n * n; second = n * n + n; a = fb; c = fg; d = fr }
            }
            let base = ri + gi * n + bi * n * n
            let v0 = values[base], v1 = values[base + first], v2 = values[base + second]
            let v3 = values[base + 1 + n + n * n]
            let out = ((v0 + (v1 - v0) * a) + (v2 - v1) * c) + (v3 - v2) * d
            return SIMD3(ToneLUT.clamp(out.x), ToneLUT.clamp(out.y), ToneLUT.clamp(out.z))
        }
    }

    @inline(__always) static func clamp(_ value: Float) -> Float { min(1, max(0, value)) }
    private static let lock = NSLock()
    private static var tables: [String: Table] = [:]
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])

    static func table(resource: String) throws -> Table {
        lock.lock()
        let existing = tables[resource]
        lock.unlock()
        if let existing { return existing }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "lut") else { throw Failure.missing(resource) }
        let value = try Table(data: Data(contentsOf: url))
        lock.lock()
        tables[resource] = value
        lock.unlock()
        return value
    }

    static func apply(_ image: CIImage, resource: String) throws -> CIImage {
        try apply(image, table: table(resource: resource))
    }

    static func apply(_ image: CIImage, table: Table) throws -> CIImage {
        try Task.checkCancellation()
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1, extent.width <= 65_535, extent.height <= 65_535 else { throw Failure.invalidExtent }
        let width = Int(ceil(extent.width)), height = Int(ceil(extent.height))
        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        try withUnsafeCurrentTask { currentTask in
            try pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                // Core Image buffers contain premultiplied alpha. Most imported
                // photos are opaque; unpremultiply before table sampling for PNGs.
                context.render(image, toBitmap: base, rowBytes: rowBytes, bounds: CGRect(x: extent.minX, y: extent.minY, width: CGFloat(width), height: CGFloat(height)), format: .RGBA8, colorSpace: colorSpace)
                let buffer = base.assumingMemoryBound(to: UInt8.self)
                let bands = min(height, max(1, ProcessInfo.processInfo.activeProcessorCount))
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    let start = height * band / bands, end = height * (band + 1) / bands
                    for y in start..<end {
                        if y % 64 == 0 && currentTask?.isCancelled == true { return }
                        for x in 0..<width {
                            let offset = y * rowBytes + x * 4
                            let alpha = Float(buffer[offset + 3]) / 255
                            if alpha <= 0 { continue }
                            let rgb = SIMD3(Float(buffer[offset]), Float(buffer[offset + 1]), Float(buffer[offset + 2])) / (255 * alpha)
                            let out = table.map(rgb) * (255 * alpha)
                            buffer[offset] = UInt8(min(255, max(0, Int(floor(out.x + 0.5)))))
                            buffer[offset + 1] = UInt8(min(255, max(0, Int(floor(out.y + 0.5)))))
                            buffer[offset + 2] = UInt8(min(255, max(0, Int(floor(out.z + 0.5)))))
                        }
                    }
                }
                try Task.checkCancellation()
            }
        }
        return CIImage(bitmapData: pixels, bytesPerRow: rowBytes, size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBA8, colorSpace: colorSpace)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
    }
}
