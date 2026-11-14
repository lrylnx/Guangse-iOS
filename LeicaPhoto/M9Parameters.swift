import Foundation

/// Snapshot LUT and lens shading from the APK's LeicaParams + libfullm9 leicaPixel.
/// RGB bytes are encoded display RGB (not linear light). No RAW/ISP tables apply here.
final class M9Parameters: @unchecked Sendable {
    struct RangeBin: Decodable {
        let lo: Int
        let hi: Int
        let index: Int?
        let sub: [RangeBin]?
    }
    struct Zoom: Decodable { let zoom: Float; let tree: [RangeBin] }
    struct Tables: Decodable {
        let dimension: Int
        let lutCount: Int
        let lutBGR: Data
        let scenes: [String: [RangeBin]]
        let zooms: [Zoom]
        let shading: [[Float]]
    }
    struct Selection {
        let lutBGR: [UInt8]
        let shading: [Float]
    }
    enum ParameterError: Error {
        case missingResource, invalidResource, invalidPixels
    }
    private let tables: Tables
    private let rawLUT: [UInt8]
    private let cacheLock = NSLock()
    private var cache: [String: Selection] = [:]
    static let shared: Result<M9Parameters, Error> = Result { try M9Parameters() }

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "m9-parameters", withExtension: "json")
                ?? bundle.url(forResource: "m9-parameters", withExtension: "json", subdirectory: "Resources") else {
            throw ParameterError.missingResource
        }
        tables = try JSONDecoder().decode(Tables.self, from: Data(contentsOf: url))
        guard tables.dimension == 17, tables.lutBGR.count == tables.lutCount * 14739,
              tables.scenes["common"]?.isEmpty == false, !tables.zooms.isEmpty,
              tables.shading.allSatisfy({ $0.count == 8 }) else {
            throw ParameterError.invalidResource
        }
        rawLUT = [UInt8](tables.lutBGR)
    }

    // Each bin is a plateau [lo, hi]; blend across gaps between plateaus only.
    private func bounds(_ bins: [RangeBin], _ value: Int) throws -> (RangeBin, RangeBin) {
        guard let last = bins.last else { throw ParameterError.invalidResource }
        for (i, bin) in bins.enumerated() where value <= bin.hi {
            return value < bin.lo && i > 0 ? (bins[i - 1], bin) : (bin, bin)
        }
        return (last, last)
    }
    private func fraction(_ value: Int, _ a: RangeBin, _ b: RangeBin) -> Float {
        let gap = b.lo - a.hi
        return gap == 0 ? 0 : Float(value - a.hi) / Float(gap)
    }
    private func corners(_ bins: [RangeBin], lux: Int, cct: Int) throws -> [(Int, Float)] {
        let (a, b) = try bounds(bins, lux)
        guard let aSub = a.sub, let bSub = b.sub else { throw ParameterError.invalidResource }
        let (aa, ab) = try bounds(aSub, cct)
        let (ba, bb) = try bounds(bSub, cct)
        let x = fraction(lux, a, b), y = fraction(cct, aa, ab), z = fraction(cct, ba, bb)
        let values = [(aa, (1-x)*(1-y)), (ab, (1-x)*y), (ba, x*(1-z)), (bb, x*z)]
        // LinkedHashMap insertion order matches Android's Float accumulation.
        var result: [(Int, Float)] = []
        for (bin, weight) in values {
            guard let index = bin.index else { throw ParameterError.invalidResource }
            if let i = result.firstIndex(where: { $0.0 == index }) { result[i].1 += weight }
            else { result.append((index, weight)) }
        }
        return result
    }

    func selection(lux: Int, cct: Int, zoom: Float, scene: String = "common") throws -> Selection {
        let key = "\(scene):\(lux):\(cct):\(zoom.bitPattern)"
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return hit }
        guard let bins = tables.scenes[scene] ?? tables.scenes["common"] else { throw ParameterError.invalidResource }
        let weights = try corners(bins, lux: lux, cct: cct)
        var lut = [UInt8](repeating: 0, count: 14739)
        if weights.count == 1 {
            let start = weights[0].0 * 14739
            guard start >= 0, start + 14739 <= rawLUT.count else { throw ParameterError.invalidResource }
            lut.replaceSubrange(0..<14739, with: rawLUT[start..<(start+14739)])
        } else {
            var floats = [Float](repeating: 0, count: 14739)
            for (index, weight) in weights {
                guard index >= 0, index < tables.lutCount else { throw ParameterError.invalidResource }
                for i in 0..<14739 { floats[i] += weight * Float(rawLUT[index*14739+i]) }
            }
            // Java `(byte)(int)` truncates, it does not round the blended LUT.
            for i in 0..<14739 { lut[i] = UInt8(clamping: Int(floats[i])) }
        }
        var zoomIndex = 0
        for (i, value) in tables.zooms.enumerated() where zoom >= value.zoom { zoomIndex = i }
        var shade = [Float](repeating: 0, count: 8)
        for (index, weight) in try corners(tables.zooms[zoomIndex].tree, lux: lux, cct: cct) {
            guard index >= 0, index < tables.shading.count else { throw ParameterError.invalidResource }
            for i in 0..<8 { shade[i] += weight * tables.shading[index][i] }
        }
        let value = Selection(lutBGR: lut, shading: shade)
        cacheLock.lock()
        if cache.count >= 32 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        cacheLock.unlock()
        return value
    }

    static func apply(_ rgba: [UInt8], width: Int, height: Int,
                      lux: Int = 300, cct: Int = 5000, zoom: Float = 1) throws -> [UInt8] {
        try apply(rgba: rgba, width: width, height: height, lux: lux, cct: cct, zoom: zoom)
    }

    static func apply(rgba: [UInt8], width: Int, height: Int,
                      lux: Int = 300, cct: Int = 5000, zoom: Float = 1) throws -> [UInt8] {
        try shared.get().apply(rgba: rgba, width: width, height: height, lux: lux, cct: cct, zoom: zoom)
    }

    func apply(rgba: [UInt8], width: Int, height: Int,
               lux: Int = 300, cct: Int = 5000, zoom: Float = 1) throws -> [UInt8] {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { throw ParameterError.invalidPixels }
        let selected = try selection(lux: lux, cct: cct, zoom: zoom)
        let lut = selected.lutBGR, s = selected.shading
        var output = rgba
        let wf = Float(width), hf = Float(height)
        var bases = [Int](repeating: 0, count: 256), fractions = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let value = (Float(i)/255)*16
            bases[i] = min(15, Int(floor(value)))
            fractions[i] = value-Float(bases[i])
        }
        for y in 0..<height {
            let yy = (Float(y)+0.5)/hf-0.5
            for x in 0..<width {
                let i = (y*width+x)*4
                let ir = Int(rgba[i]), ig = Int(rgba[i+1]), ib = Int(rgba[i+2])
                let r = bases[ir], g = bases[ig], b = bases[ib]
                let fr = fractions[ir], fg = fractions[ig], fb = fractions[ib]
                // The binary table is R-major, but its triples are BGR.
                var cr: Float = 0, cg: Float = 0, cb: Float = 0
                for dr in 0...1 {
                    for dg in 0...1 {
                        for db in 0...1 {
                            let w = (dr == 0 ? 1-fr : fr) * (dg == 0 ? 1-fg : fg) * (db == 0 ? 1-fb : fb)
                            let j = (((r+dr)*17+(g+dg))*17+(b+db))*3
                            cr += (w*Float(lut[j+2]))/255
                            cg += (w*Float(lut[j+1]))/255
                            cb += (w*Float(lut[j]))/255
                        }
                    }
                }
                // leicaPixel uses height to normalize the horizontal radius too.
                let xx = (((Float(x)+0.5)/wf-0.5)*wf/hf+0.5)-0.5
                let noiseValue = sinf((xx-0.5)*12.9898+(yy-0.5)*78.233)*43758.546875
                let noise = (noiseValue-floorf(noiseValue))*0.04*s[2]
                let radius = sqrtf(xx*xx+yy*yy)+noise
                var t = min(1, max(0, (radius-s[0])/(s[1]-s[0])))
                t = t*t*(3-2*t)
                let unusualLum = cr*0.499+cg*0.387+cb*0.114
                let luminance = cr*0.299+cg*0.587+cb*0.114
                let base = s[7]+s[6]/(expf(s[4]*(s[5]-unusualLum))+1)
                let gain = s[3]*(base+t*(1-base))
                let delta = luminance*(gain-1)
                output[i] = Self.byte(cr+delta)
                output[i+1] = Self.byte(cg+delta)
                output[i+2] = Self.byte(cb+delta)
                output[i+3] = 255
            }
        }
        return output
    }
    private static func byte(_ value: Float) -> UInt8 {
        let scaled = value*255
        guard scaled.isFinite else { return 0 }
        return UInt8(clamping: Int(scaled.rounded(.toNearestOrEven)))
    }
}
