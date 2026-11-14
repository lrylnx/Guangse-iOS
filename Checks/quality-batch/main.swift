import Foundation
import CoreImage
import ImageIO

func check(_ test: Bool, _ label: String) { precondition(test,label); print("PASS \(label)") }
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let run=root.appendingPathComponent("quality-output")
try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
func bytes(_ image:CIImage)->[UInt8] { M9Pipeline.rgba(image) }
let w=67,h=43
var pattern=[UInt8](repeating:255,count:w*h*4)
for y in 0..<h { for x in 0..<w {
 let i=(y*w+x)*4
 pattern[i]=UInt8((x*7+y*3)%256);pattern[i+1]=UInt8((x*5+y*11)%256);pattern[i+2]=UInt8((x*17+y*13)%256)
} }
let image=M9Pipeline.image(pattern,width:w,height:h)
let file=run.appendingPathComponent("pixels.png")
try PhotoExport.writePNG(image,to:file,context:FilterEngine.context)
let decoded=try FilterEngine.source(Data(contentsOf:file))
check(bytes(decoded)==bytes(image),"PNG exact processed RGB pixels, zero lossy compression")
let src=CGImageSourceCreateWithURL(file as CFURL,nil)!
let props=CGImageSourceCopyPropertiesAtIndex(src,0,nil)! as NSDictionary
check(props[kCGImagePropertyProfileName] != nil,"PNG embeds color profile")
check(props[kCGImagePropertyPixelWidth] as? Int==w && props[kCGImagePropertyPixelHeight] as? Int==h,"PNG exact dimensions")
let source1=PhotoSource(id:UUID(),url:file)
let file2=run.appendingPathComponent("second.png")
try PhotoExport.writePNG(FilterEngine.normalized(image.oriented(.right)),to:file2,context:FilterEngine.context)
let source2=PhotoSource(id:UUID(),url:file2)
let actor=PhotoProcessor(directory:run)
let done=DispatchSemaphore(value:0)
Task.detached {
 do {
  var settings=EditorSettings();settings.useAI=false;settings.filterID="leica_m9"
  for source in [source1,source2] {
   let out=try await actor.export(source,settings:settings) { _,_ in }
   let data=try Data(contentsOf:out)
   check(data.prefix(8)==Data([137,80,78,71,13,10,26,10]),"Batch exports genuine PNG")
   let exported=try FilterEngine.source(data)
   let original=try FilterEngine.source(Data(contentsOf:source.url))
   let expected=try FilterEngine.apply(original,filter:PhotoFilter.all.first{$0.id=="leica_m9"},strength:1)
   check(bytes(exported)==bytes(expected),"Batch result equals full-resolution filter output")
   check(exported.extent==original.extent,"Batch portrait/landscape orientation and size")
   try FileManager.default.removeItem(at:out)
  }
  var ai=EditorSettings();ai.mode = .distill
  let p1=try await actor.preview(source1,settings:ai,original:false) {_,_ in}
  check(p1.width==w && p1.height==h,"Small M9D returns original dimensions")
  let caches=(try FileManager.default.contentsOfDirectory(atPath:run.path)).filter{$0.hasPrefix("ai-")}
  check(caches.count==1,"AI result cached on disk")
  let out=try await actor.export(source1,settings:ai) { _,_ in }
  let caches2=(try FileManager.default.contentsOfDirectory(atPath:run.path)).filter{$0.hasPrefix("ai-")}
  check(caches==caches2,"Save reuses identical preview AI, no second inference/cache")
  check(try bytes(FilterEngine.source(Data(contentsOf:out)))==bytes(CIImage(cgImage:p1)),"Lossless preview/save agree for unscaled image")
  try FileManager.default.removeItem(at:out)
  let cancelled=Task { () throws -> URL in
   try Task.checkCancellation()
   return try await actor.export(source1,settings:settings){_,_ in}
  }
  cancelled.cancel()
  do { _ = try await cancelled.value; fatalError("cancelled export succeeded") } catch is CancellationError { print("PASS cancellation propagated") }
  await actor.clear()
  check((try FileManager.default.contentsOfDirectory(atPath:run.path)).allSatisfy{!$0.hasPrefix("ai-")},"Clearing removes only cached results")
  check(FileManager.default.fileExists(atPath:file.path),"Clearing leaves source files intact")
  print("ALL QUALITY/BATCH PROCESSOR CHECKS PASSED")
 } catch { print("FAIL \(error)"); exit(1) }
 done.signal()
}
done.wait()
