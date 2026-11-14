import Foundation
import CoreImage
import CoreML

// Reconstructed from com.codex.fullm9.M9Graph and libfullm9.so frame helpers.
// Model names describe the original network branches, not scene-brightness labels.
enum M9Branch: String, CaseIterable, Identifiable {
    case high, low
    var id: String { rawValue }
    var title: String { self == .high ? "M9 · 高分支" : "M9 · 低分支" }
}

struct M9Pipeline {
    static let canvasWidth = 4096, canvasHeight = 3072
    static let styleWidth = 1120, styleHeight = 864
    static let tileSize = 544, tileInner = 512
    static let black: Float = -128.0 / 127.5

    static func reflect101(_ value: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * count - 2
        let x = (value % period + period) % period
        return x < count ? x : period - x
    }

    static func symmetric(_ value: Int, count: Int) -> Int {
        let period = 2 * count
        let x = (value % period + period) % period
        return x < count ? x : period - 1 - x
    }

    static func encode(_ x: Float) -> UInt8 {
        guard x.isFinite else { return 0 }
        return UInt8(max(0, min(255, (x * 127.5 + 128).rounded(.toNearestOrEven))))
    }

    // Bitmap row order was verified against a CGImage with asymmetric top/bottom colors.
    static func rgba(_ image: CIImage) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            FilterEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: FilterEngine.colorSpace)
        }
        return bytes
    }

    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CIImage {
        let raw = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: FilterEngine.colorSpace)
        return raw
    }

    static func array(channels: Int, height: Int, width: Int) throws -> MLMultiArray {
        try MLMultiArray(shape: [1, NSNumber(value: channels), NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
    }

    static func checkShape(_ output: MLMultiArray, channels: Int, height: Int, width: Int) throws {
        guard output.shape.map(\.intValue) == [1, channels, height, width] else { throw PhotoError.model("AI 模型输出尺寸不正确。") }
    }

    static func value(_ array: MLMultiArray, channel: Int, y: Int, x: Int) -> Float {
        // Respect runtime strides; do not assume Core ML materializes contiguous output.
        let offset = channel * array.strides[1].intValue + y * array.strides[2].intValue + x * array.strides[3].intValue
        switch array.dataType {
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        case .float16: return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        default: return array[[0, channel as NSNumber, y as NSNumber, x as NSNumber]].floatValue
        }
    }

    static func canvas(_ source: [UInt8], width: Int, height: Int) -> [UInt8] {
        let ox = (canvasWidth - width) / 2, oy = (canvasHeight - height) / 2
        var output = [UInt8](repeating: 255, count: canvasWidth * canvasHeight * 4)
        for y in 0..<canvasHeight {
            let sy = reflect101(y - oy, count: height)
            for x in 0..<canvasWidth {
                let sx = reflect101(x - ox, count: width)
                let a = (sy * width + sx) * 4, b = (y * canvasWidth + x) * 4
                output[b] = source[a]; output[b+1] = source[a+1]; output[b+2] = source[a+2]
            }
        }
        return output
    }

    static func styleInput(_ pixels: [UInt8]) throws -> MLMultiArray {
        var reduced = [UInt8](repeating: 0, count: 1024 * 768 * 3)
        for y in 0..<768 {
            for x in 0..<1024 {
                for c in 0..<3 {
                    var sum = 0
                    for dy in 0..<4 { for dx in 0..<4 { sum += Int(pixels[((y*4+dy)*canvasWidth+x*4+dx)*4+c]) } }
                    reduced[(y*1024+x)*3+c] = UInt8((Float(sum) / 16).rounded(.toNearestOrEven))
                }
            }
        }
        let tensor = try array(channels: 4, height: styleHeight, width: styleWidth)
        let p = tensor.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = styleHeight * styleWidth
        for y in 0..<styleHeight {
            let sy = symmetric(y-48, count: 768)
            for x in 0..<styleWidth {
                let sx = symmetric(x-48, count: 1024), i = y*styleWidth+x
                for c in 0..<3 { p[c*plane+i] = (Float(reduced[(sy*1024+sx)*3+c])-128)/127.5 }
                p[3*plane+i] = black
            }
        }
        return tensor
    }

    static func stylePixels(_ output: MLMultiArray) throws -> [UInt8] {
        try checkShape(output, channels: 3, height: styleHeight, width: styleWidth)
        var bytes = [UInt8](repeating: 0, count: 1024*768*3)
        let strides = output.strides.map(\.intValue)
        if output.dataType == .float32 {
            let p = output.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<768 { for x in 0..<1024 { for c in 0..<3 {
                bytes[(y*1024+x)*3+c] = encode(p[c*strides[1]+(y+48)*strides[2]+(x+48)*strides[3]])
            } } }
        } else {
            for y in 0..<768 { for x in 0..<1024 { for c in 0..<3 { bytes[(y*1024+x)*3+c] = encode(value(output,channel:c,y:y+48,x:x+48)) } } }
        }
        return bytes
    }

    static func tileInput(_ pixels: [UInt8], style: [UInt8], tileX: Int, tileY: Int) throws -> MLMultiArray {
        let tensor = try array(channels: 6, height: tileSize, width: tileSize)
        let p = tensor.dataPointer.assumingMemoryBound(to: Float.self), plane = tileSize*tileSize
        p.update(repeating: black, count: 6*plane)
        for y in 0..<tileSize {
            let cy = tileY*512+y-16
            guard cy >= 0 && cy < canvasHeight else { continue }
            for x in 0..<tileSize {
                let cx = tileX*512+x-16
                guard cx >= 0 && cx < canvasWidth else { continue }
                let i = y*tileSize+x, a = ((cy/4)*1024+cx/4)*3, b = (cy*canvasWidth+cx)*4
                for c in 0..<3 {
                    p[c*plane+i] = (Float(style[a+c])-128)/127.5
                    p[(c+3)*plane+i] = (Float(pixels[b+c])-128)/127.5
                }
            }
        }
        return tensor
    }

    static func process(_ image: CIImage, branch: M9Branch, parameters: Bool, lux: Int, cct: Int, zoom: Float = 1, progress: @escaping (Double,String) -> Void) throws -> CIImage {
        defer { M9Models.shared.releaseCachedModels() }
        let portrait = image.extent.height > image.extent.width
        var prepared = portrait ? FilterEngine.normalized(image.oriented(.right)) : image
        let scale = min(1, min(CGFloat(canvasWidth)/prepared.extent.width, CGFloat(canvasHeight)/prepared.extent.height))
        if scale < 1 { prepared = FilterEngine.normalized(prepared.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: CGRect(x:0,y:0,width:floor(prepared.extent.width*scale),height:floor(prepared.extent.height*scale)))) }
        let width = Int(prepared.extent.width), height = Int(prepared.extent.height)
        let ox = (canvasWidth-width)/2, oy = (canvasHeight-height)/2
        progress(0.02,"准备原版输入")
        let pixels = canvas(rgba(prepared), width: width, height: height)
        try Task.checkCancellation()
        progress(0.06,"M9 风格网络")
        let style: [UInt8] = try autoreleasepool {
            let input = try styleInput(pixels)
            let output = try M9Models.shared.predict(branch.rawValue, input: input)
            return try stylePixels(output)
        }
        M9Models.shared.releaseCachedModels()
        var result = [UInt8](repeating: 255, count: width*height*4)
        let x0=ox/512, x1=(ox+width-1)/512, y0=oy/512, y1=(oy+height-1)/512
        let count=(x1-x0+1)*(y1-y0+1)
        var done=0
        for ty in y0...y1 { for tx in x0...x1 {
            try Task.checkCancellation()
            try autoreleasepool {
                let input = try tileInput(pixels, style: style, tileX: tx, tileY: ty)
                let output = try M9Models.shared.predict("colorfix", input: input)
                try checkShape(output, channels: 3, height: tileSize, width: tileSize)
                let sx=max(ox,tx*512), ex=min(ox+width,(tx+1)*512)
                let sy=max(oy,ty*512), ey=min(oy+height,(ty+1)*512)
                let strides=output.strides.map(\.intValue)
                if output.dataType == .float32 {
                    let p=output.dataPointer.assumingMemoryBound(to:Float.self)
                    for cy in sy..<ey { for cx in sx..<ex {
                        let dest=((cy-oy)*width+cx-ox)*4, xx=cx-tx*512+16, yy=cy-ty*512+16
                        for c in 0..<3 { result[dest+c]=encode(p[c*strides[1]+yy*strides[2]+xx*strides[3]]) }
                    } }
                } else {
                    for cy in sy..<ey { for cx in sx..<ex {
                        let dest=((cy-oy)*width+cx-ox)*4
                        for c in 0..<3 { result[dest+c]=encode(value(output,channel:c,y:cy-ty*512+16,x:cx-tx*512+16)) }
                    } }
                }
            }
            done+=1
            progress(0.1+Double(done)/Double(count)*0.85,"色彩修正 \(done)/\(count)")
        } }
        var output = self.image(result,width:width,height:height)
        if portrait { output = FilterEngine.normalized(output.oriented(.left)) }
        if parameters {
            progress(0.97,"原版调色与暗角")
            let w=Int(output.extent.width), h=Int(output.extent.height)
            result = try M9Parameters.apply(rgba(output),width:w,height:h,lux:lux,cct:cct,zoom:zoom)
            output = self.image(result,width:w,height:h)
        }
        progress(1,"AI 处理完成")
        return output
    }
}
