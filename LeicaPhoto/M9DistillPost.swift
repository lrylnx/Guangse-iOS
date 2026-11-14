import Foundation
import CoreImage

/// Style 770 (M9D) postprocessing, kept separate from the verified model so the
/// gap is visible: this is **not** the shipped donor native chain.
///
/// What the Android 770 path actually does (Investigation/optimization-mode770.md):
/// `M9Distill.run` calls `LegendaryPostProcessor.applyWarmLutBitmapBin` with Java
/// defaults .6 / −.95 / .3, but the JNI wrapper ignores s4..s6 and only forwards
/// lux200 / cct5500 / zoom1 / time to `libd12ase.so`. That core then calls the
/// pixel worker with s4=−1, s5=−.35, s6=.025 and runs a LUT interpolation followed
/// by a shading stage that includes an sRGB→linear segment which has not been
/// reconstructed here.
///
/// Until that stage is recovered, this uses the M9 snapshot LUT/shading tables at
/// the wrapper's fixed 200 / 5500 / 1. Treat the result as a documented
/// approximation, not as pixel parity with the donor library.
enum M9DistillPost {
    static let lux = 200
    static let cct = 5500
    static let zoom: Float = 1

    /// Fixed parameters are part of the contract: the native wrapper discards the
    /// Java warm defaults, so no scene value should be threaded in here.
    static func apply(_ image: CIImage) throws -> CIImage {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let adjusted = try M9Parameters.apply(M9Pipeline.rgba(image), width: width, height: height,
                                              lux: lux, cct: cct, zoom: zoom)
        return M9Pipeline.image(adjusted, width: width, height: height)
    }
}
