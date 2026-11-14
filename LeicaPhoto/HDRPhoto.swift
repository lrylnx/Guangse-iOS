import Foundation
import CoreImage
import ImageIO

/// SDR-only M9 networks stay unchanged. This sidecar transfers the original's
/// spatial luminance gain to the FINISHED, rendered SDR edit in linear light.
/// It does not recover color/detail lost by the SDR network or manufacture HDR
/// from an SDR input. Geometry is matched before deriving the new HDR pixels.
enum HDRPhoto {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    static let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    private static let transfer = CIColorKernel(source: """
        kernel vec4 transferOriginalGain(__sample edit, __sample base, __sample hdr) {
            vec3 weights = vec3(0.2126, 0.7152, 0.0722);
            float s = max(dot(base.rgb, weights), 0.0);
            float h = max(dot(hdr.rgb, weights), 0.0);
            float gain = s > 0.0001 ? clamp(h / s, 0.0, 64.0) : 1.0;
            return vec4(edit.rgb * gain, edit.a);
        }
        """)

    struct Source {
        let image: CIImage
        let peak: Float
    }

    static func source(_ data: Data) throws -> Source? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true, .expandToHDR: true, .toneMapHDRtoSDR: false]) else { throw PhotoError.invalidImage }
        var declaredHDR = image.colorSpace.map { $0.isHDR() } ?? false
        if #available(iOS 18.0, macOS 15.0, *) { declaredHDR = declaredHDR || image.contentHeadroom > 1.001 }
        if !declaredHDR, let source = CGImageSourceCreateWithData(data as CFData, nil) {
            declaredHDR = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
            if #available(iOS 18.0, macOS 15.0, *) {
                declaredHDR = declaredHDR || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            }
        }
        guard declaredHDR else { return nil }
        let normalized = FilterEngine.normalized(image)
        let maximum = normalized.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: normalized.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(maximum, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        let peak = pixel.prefix(3).max() ?? 0
        guard peak.isFinite, peak > 1.001 else { return nil }
        return Source(image: normalized, peak: peak)
    }

    static func reconstruct(_ editedSDR: CIImage, sourceData: Data) throws -> CIImage? {
        guard let source = try source(sourceData) else { return nil }
        try Task.checkCancellation()
        // Render using the ORIGINAL sRGB context first. Evaluating an SDR LUT
        // graph in the new linear HDR context would change its intended colors.
        let edit = CIImage(cgImage: try FilterEngine.cgImage(editedSDR))
        let base = CIImage(cgImage: try FilterEngine.cgImage(FilterEngine.source(sourceData)))
        func matched(_ image: CIImage) -> CIImage {
            FilterEngine.normalized(image.transformed(by: CGAffineTransform(scaleX: edit.extent.width / image.extent.width,
                                                                           y: edit.extent.height / image.extent.height)))
                .cropped(to: edit.extent)
        }
        guard let transfer, let result = transfer.apply(extent: edit.extent, arguments: [edit, matched(base), matched(source.image)]) else {
            throw PhotoError.model("无法重建 HDR 照片；请关闭“保留原图 HDR”后重试。")
        }
        return result
    }

    static func writePNG(_ image: CIImage, to url: URL, sourceData: Data? = nil) throws {
        // RGBA16 + PQ explicitly stores extended luminance, with lossless PNG
        // compression. An 8-bit sRGB PNG cannot represent these HDR pixels.
        try PhotoExport.writeHDRPNG(image, to: url, sourceData: sourceData)
    }

    static func display(_ image: CIImage, maxDimension: CGFloat = 1600) throws -> CGImage {
        let scale = min(1, maxDimension / max(image.extent.width, image.extent.height))
        let small = FilterEngine.normalized(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
        guard let pixels = context.createCGImage(small, from: small.extent, format: .RGBA16, colorSpace: pq) else { throw PhotoError.renderFailed }
        return pixels
    }
}
