import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Exports rendered pixels with an explicit SDR sRGB or HDR PQ ICC profile.
/// Never copies an old gain map: HDR output has newly reconstructed HDR pixels.
/// Maker notes, thumbnails and GPS are not copied to the edited image.
enum PhotoExport {
    enum ExportError: LocalizedError {
        case render, encode
        var errorDescription: String? {
            switch self {
            case .render: return "无法生成导出照片。"
            case .encode: return "无法写入照片文件。"
            }
        }
    }

    /// Lossless export of the current 8-bit SDR processing result, not HDR reconstruction.
    static func writePNG(_ image: CIImage, to url: URL, context: CIContext,
                         sourceData: Data? = nil) throws {
        try write(image, to: url, context: context, sourceData: sourceData,
                  type: UTType.png.identifier, quality: nil)
    }

    static func writeHDRPNG(_ image: CIImage, to url: URL, sourceData: Data? = nil) throws {
        try write(image, to: url, context: HDRPhoto.context, sourceData: sourceData,
                  type: UTType.png.identifier, quality: nil, format: .RGBA16, colorSpace: HDRPhoto.pq)
    }

    static func writeJPEG(_ image: CIImage, to url: URL, context: CIContext,
                          sourceData: Data? = nil, quality: Double = 0.97) throws {
        try write(image, to: url, context: context, sourceData: sourceData,
                  type: UTType.jpeg.identifier, quality: quality)
    }

    private static func write(_ image: CIImage, to url: URL, context: CIContext,
                              sourceData: Data?, type: String, quality: Double?, format: CIFormat = .RGBA8,
                              colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite,
              let pixels = context.createCGImage(image, from: extent, format: format,
                                                  colorSpace: colorSpace) else {
            throw ExportError.render
        }
        // Stream to the file rather than retain a second full PNG in memory.
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ExportError.encode
        }
        var properties: [String: Any] = [
            kCGImagePropertyOrientation as String: 1
        ]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality as String] = min(1, max(0, quality)) }
        if let sourceData,
           let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = original[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            // An allowlist prevents stale HDR maker notes and identifying metadata
            // from leaking into the new file. Keep only basic capture information.
            let keys = [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
                        kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength,
                        kCGImagePropertyExifFocalLenIn35mmFilm, kCGImagePropertyExifDateTimeOriginal]
            var capture: [String: Any] = [:]
            for key in keys { if let value = exif[key as String] { capture[key as String] = value } }
            capture[kCGImagePropertyExifPixelXDimension as String] = pixels.width
            capture[kCGImagePropertyExifPixelYDimension as String] = pixels.height
            capture[kCGImagePropertyExifColorSpace as String] = format == .RGBA8 ? 1 : 65535
            properties[kCGImagePropertyExifDictionary as String] = capture
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
    }
}
