import Foundation
import CoreImage

/// Original CameraLook ToneMath.toned/film stages and the ToneFast 3x3 luma
/// neighbourhood. QualityPass/native denoise, detail recovery and HDR are
/// separate APK stages and are not represented by this implementation.
enum ToneEffects {
    struct Params: Decodable {
        let strength: Float
        let grain: Float
        let shadows: Float
        let midtones: Float
        let highlights: Float
        let grainSize: Float
        let roughness: Float
        let colorVariation: Float
        let vignette: Float
        let midpoint: Float
        let clarity: Float
        let luma: [Float]
        let rgb: [Float]
        var usesFilm: Bool { grain != 0 || vignette != 0 || clarity != 0 }
        var valid: Bool {
            let scalars = [strength,grain,shadows,midtones,highlights,grainSize,roughness,colorVariation,vignette,midpoint,clarity]
            return scalars.allSatisfy(\.isFinite) && Self.validCurve(luma) && Self.validCurve(rgb)
        }
        private static func validCurve(_ values: [Float]) -> Bool {
            guard values.count >= 4, values.count % 2 == 0, values.allSatisfy(\.isFinite) else { return false }
            for i in stride(from: 2, to: values.count, by: 2) { if values[i] <= values[i-2] { return false } }
            return true
        }
    }
    struct Profile: Decodable {
        let resource: String
        let sourceToneID: Int
        let originalParams: Params
    }
    private static let lock = NSLock()
    private static var cachedProfiles: [Profile]?
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])

    static func profile(resource: String) throws -> Profile {
        lock.lock()
        let existing = cachedProfiles
        lock.unlock()
        let profiles: [Profile]
        if let existing { profiles = existing }
        else {
            guard let url = Bundle.main.url(forResource: "tone-catalog", withExtension: "json") else { throw ToneLUT.Failure.missing("tone-catalog") }
            profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url))
            guard profiles.count == 23, profiles.allSatisfy({ $0.originalParams.valid && (16...38).contains($0.sourceToneID) }) else { throw ToneLUT.Failure.malformed }
            lock.lock()
            cachedProfiles = profiles
            lock.unlock()
        }
        guard let profile = profiles.first(where: { $0.resource == resource }) else { throw ToneLUT.Failure.missing(resource) }
        return profile
    }

    static func apply(_ image: CIImage, resource: String) throws -> CIImage {
        let configuration = try profile(resource: resource)
        return try apply(image, table: ToneLUT.table(resource: resource), params: configuration.originalParams, seed: Int32(configuration.sourceToneID - 16))
    }

    @inline(__always) static func curve(_ input: Float, _ points: [Float]) -> Float {
        let value = ToneLUT.clamp(input) * 255
        if value <= points[0] { return ToneLUT.clamp(points[1] / 255) }
        for i in stride(from: 2, to: points.count, by: 2) {
            if value <= points[i] {
                return ToneLUT.clamp((points[i-1] + (points[i+1] - points[i-1]) * (value - points[i-2]) / (points[i] - points[i-2])) / 255)
            }
        }
        return ToneLUT.clamp(points[points.count-1] / 255)
    }

    @inline(__always) static func intensify(_ input: Float, _ output: Float, _ strength: Float) -> Float {
        let delta = (max(1, min(1.8, strength)) - 1) * (output - input)
        let headroom = delta < 0 ? output : 1 - output
        var result = output
        if headroom > 0 { result += delta * headroom / (headroom + abs(delta)) }
        return ToneLUT.clamp(result)
    }

    @inline(__always) static func luminance(_ rgb: SIMD3<Float>) -> Float {
        ((rgb.x * 0.2126) + (rgb.y * 0.7152)) + (rgb.z * 0.0722)
    }

    @inline(__always) static func toned(_ input: SIMD3<Float>, table: ToneLUT.Table, params: Params) -> SIMD3<Float> {
        let mapped = table.map(input)
        let rgb = SIMD3(curve(mapped.x, params.rgb), curve(mapped.y, params.rgb), curve(mapped.z, params.rgb))
        let y = luminance(rgb), adjusted = curve(y, params.luma)
        let balanced = y <= 0.000001 ? SIMD3<Float>(repeating: adjusted) : (rgb * adjusted) / y
        return SIMD3(intensify(input.x, ToneLUT.clamp(balanced.x), params.strength), intensify(input.y, ToneLUT.clamp(balanced.y), params.strength), intensify(input.z, ToneLUT.clamp(balanced.z), params.strength))
    }

    /// Java signed int overflow and arithmetic shifts, not Swift's checked
    /// arithmetic or an unsigned/logical-shift replacement.
    @inline(__always) static func hash(_ x: Int32, _ y: Int32, _ seed: Int32) -> Float {
        var h = ((x &* 521_288_629) &+ (y &* 1_597_334_677)) &+ (seed &* 1_821_285_621)
        h = (h ^ (h >> 16)) &* 2_146_121_005
        h = (h ^ (h >> 15)) &* -2_073_254_261
        return Float((h ^ (h >> 16)) & 16_777_215) / 8_388_607.5 - 1
    }

    @inline(__always) static func noise(_ x: Int, _ y: Int, _ seed: Int32, _ size: Float, _ roughness: Float) -> Float {
        let scale = max(0, size) / 25 + 1
        let px = Float(x) / scale, py = Float(y) / scale
        let ix = Int32(px), iy = Int32(py)
        let fx = px - Float(ix), fy = py - Float(iy)
        let smooth = ((hash(ix, iy, seed) * (1-fx)) + (hash(ix &+ 1, iy, seed) * fx)) * (1-fy)
            + ((hash(ix, iy &+ 1, seed) * (1-fx)) + (hash(ix &+ 1, iy &+ 1, seed) * fx)) * fy
        let amount = min(0.7, max(0, roughness) / 100)
        return smooth * (1-amount) + hash(Int32(x), Int32(y), seed &+ 83) * amount
    }

    @inline(__always) static func film(_ rgb: SIMD3<Float>, x: Int, y: Int, width: Int, height: Int, seed: Int32, params p: Params, localLuma: Float) -> SIMD3<Float> {
        let y0 = luminance(rgb)
        let clarity = (y0 - localLuma) * (max(-20, min(0, p.clarity)) / 100)
        let dx = ((Float(x) * 2 + 1) - Float(width)) / Float(max(1, width))
        let dy = ((Float(y) * 2 + 1) - Float(height)) / Float(max(1, height))
        let radius = (dx * dx + dy * dy) * 0.5
        let mid = max(0, min(0.85, p.midpoint / 100))
        let radial = ToneLUT.clamp((radius - mid) / (1 - mid))
        let smooth = radial * radial * (3 - radial * 2)
        let exposure = Float(pow(2.0, Double(max(-1.25, min(1.25, p.vignette / 100)) * smooth)))
        let weight: Float
        if y0 >= 0.5 { weight = p.midtones + (p.highlights-p.midtones) * (y0 * 2 - 1) }
        else { weight = p.shadows + (p.midtones-p.shadows) * (y0 * 2) }
        let amplitude = (max(0, min(100, p.grain)) / 100) * max(0, weight) / 100 * 0.06
        let mono = noise(x, y, seed, p.grainSize, p.roughness) * amplitude
        let color = min(1, max(0, p.colorVariation) / 100)
        let common = (rgb + SIMD3<Float>(repeating: clarity)) * exposure + SIMD3<Float>(repeating: mono)
        return common + SIMD3(noise(x,y,seed &+ 1,p.grainSize,p.roughness),noise(x,y,seed &+ 2,p.grainSize,p.roughness),noise(x,y,seed &+ 3,p.grainSize,p.roughness)) * amplitude * color
    }

    @inline(__always) static func channel(_ value: Float) -> UInt8 { UInt8(max(0, min(255, Int(floor(value * 255 + 0.5))))) }

    static func apply(_ image: CIImage, table: ToneLUT.Table, params: Params, seed: Int32) throws -> CIImage {
        guard params.valid else { throw ToneLUT.Failure.malformed }
        try Task.checkCancellation()
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1, extent.width <= 65_535, extent.height <= 65_535 else { throw ToneLUT.Failure.invalidExtent }
        let width = Int(ceil(extent.width)), height = Int(ceil(extent.height)), rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        try withUnsafeCurrentTask { currentTask in
            try pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                context.render(image, toBitmap: base, rowBytes: rowBytes, bounds: CGRect(x: extent.minX, y: extent.minY, width: CGFloat(width), height: CGFloat(height)), format: .RGBA8, colorSpace: colorSpace)
                let buffer = base.assumingMemoryBound(to: UInt8.self)
                let bands = min(height, max(1, ProcessInfo.processInfo.activeProcessorCount))
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    for y in (height * band / bands)..<(height * (band + 1) / bands) {
                        if y % 64 == 0 && currentTask?.isCancelled == true { return }
                        for x in 0..<width {
                            let offset = y * rowBytes + x * 4
                            let alpha = Float(buffer[offset+3]) / 255
                            guard alpha > 0 else { continue }
                            let input = SIMD3(Float(buffer[offset]),Float(buffer[offset+1]),Float(buffer[offset+2])) / (255 * alpha)
                            let output = toned(input, table: table, params: params)
                            // ToneMath.color quantizes to 8 bit before film. Keep
                            // straight RGB in the intermediate buffer.
                            buffer[offset] = channel(output.x)
                            buffer[offset+1] = channel(output.y)
                            buffer[offset+2] = channel(output.z)
                        }
                    }
                }
                try Task.checkCancellation()
                if params.usesFilm {
                    // Three immutable source rows avoid a second full-size image;
                    // updated output pixels never enter a neighbour's luma.
                    func read(_ y: Int) -> [SIMD3<Float>] {
                        let row = min(height-1,max(0,y)) * rowBytes
                        return (0..<width).map { x in
                            let o = row + x*4
                            return SIMD3(Float(buffer[o]),Float(buffer[o+1]),Float(buffer[o+2])) / 255
                        }
                    }
                    var previous = read(0), current = read(0), next = read(1)
                    for y in 0..<height {
                        if y % 64 == 0 { try Task.checkCancellation() }
                        for x in 0..<width {
                            let left = max(0,x-1), right = min(width-1,x+1)
                            let sum0 = (luminance(previous[left]) + luminance(previous[x]) * 2) + luminance(previous[right])
                            let sum1 = (luminance(current[left]) + luminance(current[x]) * 2) + luminance(current[right])
                            let sum2 = (luminance(next[left]) + luminance(next[x]) * 2) + luminance(next[right])
                            let local = ((sum0 + sum1 * 2) + sum2) / 16
                            // CIContext bitmap rows and Android Bitmap rows
                            // both start at the top (verified with colour bands).
                            let out = film(current[x], x: x, y: y, width: width, height: height, seed: seed, params: params, localLuma: local)
                            let o = y*rowBytes+x*4
                            buffer[o] = channel(out.x); buffer[o+1] = channel(out.y); buffer[o+2] = channel(out.z)
                        }
                        previous = current; current = next
                        next = y+2 < height ? read(y+2) : current
                    }
                }
                // Preserve transparency for iOS imports. The source Android JPEG
                // route is opaque; premultiply only after its colour stages.
                for o in stride(from: 0, to: raw.count, by: 4) {
                    let alpha = Float(buffer[o+3]) / 255
                    if o % (rowBytes * 64) == 0 { try Task.checkCancellation() }
                    if alpha < 1 {
                        buffer[o] = UInt8(Float(buffer[o])*alpha+0.5)
                        buffer[o+1] = UInt8(Float(buffer[o+1])*alpha+0.5)
                        buffer[o+2] = UInt8(Float(buffer[o+2])*alpha+0.5)
                    }
                }
                try Task.checkCancellation()
            }
        }
        return CIImage(bitmapData: pixels, bytesPerRow: rowBytes, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
    }
}
