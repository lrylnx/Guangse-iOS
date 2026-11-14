import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct PhotoFilter: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let resource: String
    let category: String
    let kind: String
    static let all: [PhotoFilter] = {
        guard let url = Bundle.main.url(forResource: "filters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([PhotoFilter].self, from: data) else { return [] }
        return items
    }()
}

enum PhotoError: LocalizedError {
    case invalidLUT, invalidImage, renderFailed, model(String)
    var errorDescription: String? {
        switch self {
        case .invalidLUT: return "滤镜资源损坏或格式不支持。"
        case .invalidImage: return "无法读取这张照片，请尝试 JPEG 或 HEIC 照片。"
        case .renderFailed: return "照片处理失败。"
        case .model(let reason): return reason
        }
    }
}

struct FilterEngine {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
    private static let lock = NSLock()
    private static var cubeCache = [String: (Int, Data)]()

    // PLUT v1: magic, version, cube dimension, storage type; RGB, red axis fastest.
    static func decodeCube(_ data: Data) throws -> (Int, Data) {
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard bytes.count >= 16, Array(bytes[0..<4]) == Array("PLUT".utf8), u32(4) == 1 else { throw PhotoError.invalidLUT }
        let size = u32(8), storage = u32(12)
        guard (2...64).contains(size), storage == 0 || storage == 1 else { throw PhotoError.invalidLUT }
        let width = storage == 1 ? 2 : 1
        guard bytes.count == 16 + size * size * size * 3 * width else { throw PhotoError.invalidLUT }
        var values = [Float]()
        values.reserveCapacity(size * size * size * 4)
        for offset in stride(from: 16, to: bytes.count, by: 3 * width) {
            for channel in 0..<3 {
                let p = offset + channel * width
                let raw = width == 2 ? Int(bytes[p]) | (Int(bytes[p + 1]) << 8) : Int(bytes[p])
                values.append(Float(raw) / (width == 2 ? 65535 : 255))
            }
            values.append(1)
        }
        return (size, values.withUnsafeBytes { Data($0) })
    }

    static func source(_ data: Data, maxDimension: Int? = nil) throws -> CIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw PhotoError.invalidImage }
        if let maxDimension {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxDimension]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoError.invalidImage }
            return normalized(CIImage(cgImage: image))
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw PhotoError.invalidImage }
        return normalized(image)
    }

    static func source(_ data: Data, preview: Bool) throws -> CIImage {
        try source(data, maxDimension: preview ? 1600 : nil)
    }

    static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func apply(_ image: CIImage, cube: Data, strength: Double) throws -> CIImage {
        try apply(image, decoded: decodeCube(cube), strength: strength)
    }

    static func apply(_ image: CIImage, decoded: (Int, Data), strength: Double) throws -> CIImage {
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [kCIInputImageKey: image, "inputCubeDimension": decoded.0, "inputCubeData": decoded.1, "inputColorSpace": colorSpace]), let output = filter.outputImage else { throw PhotoError.renderFailed }
        return blend(image, output, strength: strength)
    }

    static func blend(_ original: CIImage, _ result: CIImage, strength: Double) -> CIImage {
        if strength <= 0 { return original }
        if strength >= 1 { return result.cropped(to: original.extent) }
        return original.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: result, kCIInputTimeKey: strength]).cropped(to: original.extent)
    }

    static func cube(_ id: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: id, withExtension: "plut") else { throw PhotoError.invalidLUT }
        return try Data(contentsOf: url)
    }

    static func cachedCube(_ resource: String) throws -> (Int, Data) {
        lock.lock()
        let value = cubeCache[resource]
        lock.unlock()
        if let value { return value }
        let value2 = try decodeCube(cube(resource))
        lock.lock()
        cubeCache[resource] = value2
        lock.unlock()
        return value2
    }

    static func apply(_ image: CIImage, filter: PhotoFilter?, strength: Double) throws -> CIImage {
        guard let filter, strength > 0 else { return image }
        if filter.kind == "clu1" {
            let result = try ToneEffects.apply(image, resource: filter.resource)
            return blend(image, result, strength: strength)
        }
        return try apply(image, decoded: cachedCube(filter.resource), strength: strength)
    }

    static func cgImage(_ image: CIImage) throws -> CGImage {
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else { throw PhotoError.renderFailed }
        return cg
    }
}
