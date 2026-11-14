import Foundation
import CoreImage
import ImageIO

final class LockedFlag: @unchecked Sendable {
    private let lock=NSLock();private var flag=false
    func set(){lock.lock();flag=true;lock.unlock()}
    var value:Bool{lock.lock();defer{lock.unlock()};return flag}
}

@main
struct HDRCheck {
    static func check(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
    static func pixel(_ image: CIImage, x: Int, y: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        HDRPhoto.context.render(image, toBitmap: &result, rowBytes: 16, bounds: CGRect(x:x,y:y,width:1,height:1), format:.RGBAf, colorSpace:HDRPhoto.linear)
        return result
    }
    static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let run = root.appendingPathComponent("hdr-export/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:run) }
        let w=64,h=48
        var floats=[Float]()
        for _ in 0..<h { for x in 0..<w { let value:Float = x<w/2 ? 0.1 : 4; floats += [value,value,value,1] } }
        let bitmap=floats.withUnsafeBytes { Data($0) }
        let hdr=CIImage(bitmapData:bitmap,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:HDRPhoto.linear)
        let input=run.appendingPathComponent("source-hdr.png")
        try HDRPhoto.writePNG(hdr,to:input)
        let data=try Data(contentsOf:input)
        let detected=try HDRPhoto.source(data)
        check(detected != nil && detected!.peak>3.9,"real HDR source detected from pixels and HDR metadata")
        let base=try FilterEngine.source(data)
        let rebuilt=try HDRPhoto.reconstruct(base,sourceData:data)!
        let file=run.appendingPathComponent("rebuilt.png")
        try HDRPhoto.writePNG(rebuilt,to:file)
        let decoded=CIImage(contentsOf:file,options:[.expandToHDR:true])!
        let properties=CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(file as CFURL,nil)!,0,nil)! as NSDictionary
        check(properties[kCGImagePropertyDepth] as? Int==16,"export is genuine 16-bit PNG")
        check((properties[kCGImagePropertyProfileName] as? String)?.contains("PQ")==true,"HDR PNG has an explicit PQ color profile")
        let high=pixel(decoded,x:48,y:20)[0], low=pixel(decoded,x:16,y:20)[0]
        print("HDR round trip linear highlights=\(high), shadow=\(low)")
        check(abs(high-4)<0.02 && abs(low-0.1)<0.002,"unity edit retains source HDR highlights beyond SDR white and stable shadows")
        let edited=CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5)).cropped(to:base.extent)
        let transferred=try HDRPhoto.reconstruct(edited,sourceData:data)!
        let value=pixel(transferred,x:48,y:20)[0]
        check(value>0.80 && value<0.90,"gain transfer multiplies edited SDR in linear light, not encoded RGB")
        let smaller=FilterEngine.normalized(edited.transformed(by:CGAffineTransform(scaleX:0.5,y:0.5)))
        let scaled=try HDRPhoto.reconstruct(smaller,sourceData:data)!
        check(scaled.extent==smaller.extent && pixel(scaled,x:24,y:12)[0]>0.8,"HDR gain aligns with reduced model output geometry")
        let sdrFile=run.appendingPathComponent("source-sdr.png")
        try PhotoExport.writePNG(edited,to:sdrFile,context:FilterEngine.context)
        let sdrData=try Data(contentsOf:sdrFile)
        check(try HDRPhoto.source(sdrData)==nil,"ordinary SDR is never relabeled as HDR")
        check(try HDRPhoto.reconstruct(edited,sourceData:sdrData)==nil,"ordinary SDR receives no artificial HDR boost")
        if #available(macOS 15.0, iOS 18.0, *) {
            let heic = run.appendingPathComponent("source-gainmap.heic")
            let baseForHEIC = CIImage(cgImage: try FilterEngine.cgImage(base))
            try HDRPhoto.context.writeHEIFRepresentation(of: baseForHEIC, to: heic, format: .RGBA8,
                colorSpace: FilterEngine.colorSpace, options: [.hdrImage: hdr])
            let heicData = try Data(contentsOf: heic)
            let gainSource = try HDRPhoto.source(heicData)
            check(gainSource != nil && gainSource!.peak > 3.5, "HEIC plus genuine adaptive HDR gain map expands and is detected")
            let rebuiltHEIC = try HDRPhoto.reconstruct(FilterEngine.source(heicData), sourceData: heicData)!
            check(abs(pixel(rebuiltHEIC,x:48,y:20)[0]-pixel(gainSource!.image,x:48,y:20)[0]) < 0.05,
                "HEIC gain-map brightness survives reconstruction without copying stale metadata")
            let portrait = run.appendingPathComponent("portrait-gainmap.heic")
            try HDRPhoto.context.writeHEIFRepresentation(of: FilterEngine.normalized(baseForHEIC.oriented(.right)), to: portrait,
                format: .RGBA8, colorSpace: FilterEngine.colorSpace,
                options: [.hdrImage: FilterEngine.normalized(hdr.oriented(.right))])
            let portraitData = try Data(contentsOf: portrait)
            let portraitEdit = try FilterEngine.source(portraitData)
            let portraitHDR = try HDRPhoto.reconstruct(portraitEdit, sourceData: portraitData)!
            check(portraitHDR.extent == portraitEdit.extent && portraitHDR.extent.width == 48 && portraitHDR.extent.height == 64,
                "portrait HDR and SDR edits have aligned geometry")
        }
        let actor=PhotoProcessor(directory:run)
        let source=PhotoSource(id:UUID(),url:input)
        var settings=EditorSettings();settings.useAI=false
        let output=try await actor.export(source,settings:settings){_,_ in}
        check(try HDRPhoto.source(Data(contentsOf:output)) != nil,"normal export pipeline retains real HDR")
        let preview=try await actor.preview(source,settings:settings,original:false){_,_ in}
        check(preview.bitsPerComponent==16 && preview.colorSpace!.isHDR(),"ready export preview retains 16-bit HDR")
        let memory=PreviewMemoryCache();let key=PreviewKey(source:source,settings:settings,original:false)
        memory.insert(preview,for:key)
        check(memory.image(for:key) === preview,"memory cache retains HDR CGImage without SDR conversion")
        let onDisk=try await actor.preview(source,settings:settings,original:false,willRender:{fatalError("cached HDR preview regenerated")}){_,_ in}
        check(onDisk.bitsPerComponent==16 && onDisk.colorSpace!.isHDR(),"disk cache retains HDR without AI reprocessing")
        check(pixel(CIImage(cgImage:onDisk),x:48,y:20)[0]>3.9,"cached HDR preview still contains values above SDR white")
        settings.preserveHDR=false
        let plain=try await actor.export(source,settings:settings){_,_ in}
        let plainProperties=CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(plain as CFURL,nil)!,0,nil)! as NSDictionary
        check(plainProperties[kCGImagePropertyDepth] as? Int==8,"HDR switch off keeps previous 8-bit SDR output")
        settings.useAI=true;settings.preserveHDR=true
        let aiHDR=try await actor.export(source,settings:settings){_,_ in}
        check(try HDRPhoto.source(Data(contentsOf:aiHDR)) != nil,"M9D neural output retains real HDR range")
        let filesBefore=try FileManager.default.contentsOfDirectory(atPath:run.path).filter{$0.hasPrefix("ai-")}
        settings.preserveHDR=false
        let reused=LockedFlag()
        _=try await actor.export(source,settings:settings){_,text in if text=="读取已生成效果" { reused.set() } }
        let filesAfter=try FileManager.default.contentsOfDirectory(atPath:run.path).filter{$0.hasPrefix("ai-")}
        check(reused.value && filesBefore == filesAfter,
              "changing HDR output reuses completed neural inference")
        await actor.clear()
        let suite="Guangse.HDRMigration.\(UUID().uuidString)";let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        var old=EditorSettings();old.mode = .full;old.filterID="leica_m9";old.aiStrength=0.63
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
        object.removeValue(forKey:"preserveHDR");defaults.set(try JSONSerialization.data(withJSONObject:object),forKey:PhotoSettingsStore.key)
        let migrated=PhotoSettingsStore.load(from:defaults)
        check(migrated==old && migrated.preserveHDR,"old presets migrate to HDR on without resetting AI/filter settings")
        print("ALL HDR RANGE / EXPORT / PREVIEW / MIGRATION CHECKS PASSED")
    }
}
