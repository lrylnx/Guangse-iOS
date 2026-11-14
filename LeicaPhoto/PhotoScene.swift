import Foundation
import ImageIO

/// The APK full-M9 import path estimates its vendor exposure index from EXIF.
/// This is not physical illuminance; CCT cannot be recovered from standard EXIF.
struct PhotoScene {
    let lux: Int
    let cct: Int
    let zoom: Float
    let hasExposure: Bool
    var explanation: String {
        hasExposure ? "亮度指数根据原图曝光参数估算；白平衡缺少厂商数据，默认 5000K，可手动调整。" : "照片缺少完整曝光信息，使用原版默认场景参数，可手动调整。"
    }
    static func read(_ data: Data) -> PhotoScene {
        var lux = 300
        var zoom: Float = 1
        var valid = false
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            let time = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0
            let aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 0
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? 0
            if time.isFinite && aperture.isFinite && iso.isFinite && time > 0 && aperture > 0 && iso > 0 {
                let ev = log2(aperture * aperture / time) - log2(iso / 100)
                lux = Int(max(0, min(999, 474.9 - ev * 23.45)))
                valid = true
            }
            let equivalent = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue ?? 0
            if equivalent.isFinite && equivalent >= 50 { zoom = Float(max(3.2, min(4.3, equivalent / 23))) }
        }
        return PhotoScene(lux: lux, cct: 5000, zoom: zoom, hasExposure: valid)
    }
}
