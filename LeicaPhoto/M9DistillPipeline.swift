import Foundation
import CoreImage
import CoreML

/// Which AI look the user asked the APK for. Android style 768/769/770 are
/// "仿色·增强 / 仿色·颗粒 / 仿色·蒸馏"; only 770 (M9D) is ported so far.
enum M9AIMode: String, CaseIterable, Identifiable, Codable {
    case full, distill
    var id: String { rawValue }
    var title: String { self == .full ? "M9 经典" : "M9D 蒸馏" }
    var detail: String {
        switch self {
        case .full:
            return "风格与色彩修正三网络，AI 工作尺寸最多 4096×3072。"
        case .distill:
            return "对应安卓样张的蒸馏模型，按原图尺寸处理；部分原版后处理仍未完整恢复。"
        }
    }
}

/// APK style 770: M9D. This path has different networks and image geometry from
/// the previous full-M9 pipeline. Reconstructed from M9Distill/TilePixels.
enum M9DistillPipeline {
    static func offsets(length: Int, core: Int) -> [Int] {
        if length <= core { return [0] }
        return (0..<((length+core-1)/core)).map { min($0*core,length-core) }
    }

    static func inputs(_ pixels: [UInt8], width: Int, height: Int, x: Int, y: Int, core: Int) throws -> (MLMultiArray, MLMultiArray) {
        let size = core+192, small = size/2
        let full = try M9Pipeline.array(channels:3,height:size,width:size)
        let low = try M9Pipeline.array(channels:3,height:small,width:small)
        let f = full.dataPointer.assumingMemoryBound(to:Float.self)
        let l = low.dataPointer.assumingMemoryBound(to:Float.self)
        let plane = size*size, lp = small*small
        let inverse: Float = 1/255
        // Cache original integer samples for exact (sum+2)>>2 byte downsampling.
        var tile=[UInt8](repeating:0,count:plane*3)
        for yy in 0..<size {
            let sy=max(0,min(height-1,y+yy-96))
            for xx in 0..<size {
                let sx=max(0,min(width-1,x+xx-96)), source=(sy*width+sx)*4, i=yy*size+xx
                for c in 0..<3 {
                    let byte=pixels[source+c]
                    tile[i*3+c]=byte
                    f[c*plane+i]=Float(byte)*inverse
                }
            }
        }
        for yy in 0..<small { for xx in 0..<small {
            let a=(yy*2*size+xx*2)*3
            for c in 0..<3 {
                let sum=Int(tile[a+c])+Int(tile[a+3+c])+Int(tile[a+size*3+c])+Int(tile[a+size*3+3+c])
                let byte=(sum+2)>>2
                l[c*lp+yy*small+xx]=Float(byte)*inverse
            }
        } }
        return (low,full)
    }

    static func encode(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8(max(0,min(255,floor(value*255+0.5))))
    }

    static func styled(_ image:CIImage,progress:@escaping(Double,String)->Void) throws -> CIImage {
        let portrait=image.extent.height>image.extent.width
        // Unlike full-M9, original M9D turns portrait counterclockwise.
        var prepared=portrait ? FilterEngine.normalized(image.oriented(.left)):image
        // Native-sized tiling preserves source pixels, including photos larger
        // than 4K. Batch jobs run sequentially and never retain multiple frames.
        let fittedWidth=Int(prepared.extent.width),fittedHeight=Int(prepared.extent.height)
        if min(fittedWidth,fittedHeight)<256 {
            let scale=256/CGFloat(min(fittedWidth,fittedHeight))
            prepared=FilterEngine.normalized(prepared.transformed(by:CGAffineTransform(scaleX:scale,y:scale)).cropped(to:CGRect(x:0,y:0,width:ceil(CGFloat(fittedWidth)*scale),height:ceil(CGFloat(fittedHeight)*scale))))
        }
        let width=Int(prepared.extent.width),height=Int(prepared.extent.height)
        let pixels=M9Pipeline.rgba(prepared)
        var result=[UInt8](repeating:255,count:width*height*4)
        let core=min(1024,min(width,height)) & ~1
        guard core>=16 else { throw PhotoError.invalidImage }
        let xs=offsets(length:width,core:core),ys=offsets(length:height,core:core)
        let total=xs.count*ys.count
        var done=0
        progress(0.02,"准备 M9D 分块")
        for y in ys { for x in xs {
            try Task.checkCancellation()
            try autoreleasepool {
                let (low,full)=try inputs(pixels,width:width,height:height,x:x,y:y,core:core)
                let output=try M9DistillModel.shared.predict(lowres:low,full:full)
                let size=core+192
                guard output.shape.map(\.intValue)==[1,3,size,size] else { throw PhotoError.model("M9D 模型输出尺寸不正确。") }
                let strides=output.strides.map(\.intValue)
                if output.dataType == .float32 {
                    let p=output.dataPointer.assumingMemoryBound(to:Float.self)
                    for yy in 0..<core { for xx in 0..<core {
                        let dest=((y+yy)*width+x+xx)*4
                        for c in 0..<3 { result[dest+c]=encode(p[c*strides[1]+(yy+96)*strides[2]+(xx+96)*strides[3]]) }
                    } }
                } else {
                    for yy in 0..<core { for xx in 0..<core {
                        let dest=((y+yy)*width+x+xx)*4
                        for c in 0..<3 { result[dest+c]=encode(M9Pipeline.value(output,channel:c,y:yy+96,x:xx+96)) }
                    } }
                }
            }
            done+=1
            progress(0.04+Double(done)/Double(total)*0.85,"M9D 风格处理 \(done)/\(total)")
        } }
        var output=M9Pipeline.image(result,width:width,height:height)
        if width != fittedWidth || height != fittedHeight {
            output=FilterEngine.normalized(output.transformed(by:CGAffineTransform(scaleX:CGFloat(fittedWidth)/CGFloat(width),y:CGFloat(fittedHeight)/CGFloat(height))))
        }
        if portrait { output=FilterEngine.normalized(output.oriented(.right)) }
        return output
    }

    static func process(_ image:CIImage,progress:@escaping(Double,String)->Void) throws -> CIImage {
        // Mirror the full-M9 pipeline: drop the cached MLModel when the run ends so
        // the phone does not hold four networks at once.
        defer { M9DistillModel.shared.releaseCachedModel() }
        let output=try styled(image,progress:progress)
        try Task.checkCancellation()
        progress(0.94,"原版 M9D 调色")
        let result=try M9DistillPost.apply(output)
        progress(1,"M9D 处理完成")
        return result
    }
}
