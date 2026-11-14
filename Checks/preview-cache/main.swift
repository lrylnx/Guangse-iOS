import Foundation
import CoreImage

func check(_ test: Bool,_ message:String) { precondition(test,message); print("PASS \(message)") }
final class Events: @unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    private var texts:[String]=[]
    private var fractions:[Double]=[]
    func render(){lock.lock();count+=1;lock.unlock()}
    func progress(_ t:String, fraction:Double){lock.lock();texts.append(t);fractions.append(fraction);lock.unlock()}
    func progressValues()->[Double]{lock.lock();defer{lock.unlock()};return fractions}
    func snapshot()->(Int,[String]){lock.lock();defer{lock.unlock()};return(count,texts)}
}
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let directory=root.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
var sources:[PhotoSource]=[]
for i in 0..<7 {
 let url=directory.appendingPathComponent("source-\(i).png")
 let image=CIImage(color:CIColor(red:0.2+CGFloat(i)/20,green:0.3,blue:0.6)).cropped(to:CGRect(x:0,y:0,width:67,height:43))
 try PhotoExport.writePNG(image,to:url,context:FilterEngine.context)
 sources.append(PhotoSource(id:UUID(),url:url))
}
let sourceList=sources
let processor=PhotoProcessor(directory:directory)
let semaphore=DispatchSemaphore(value:0)
Task.detached {
 do {
  let settings=EditorSettings()
  var first:[CGImage]=[]
  for source in sourceList.prefix(6) {
   let events=Events()
   let cg=try await processor.preview(source,settings:settings,original:false,willRender:{events.render()}){f,t in events.progress(t,fraction:f)}
   check(events.snapshot().0==1,"first preview needs render")
   let fractions=events.progressValues()
   check(fractions.last==1 && fractions.allSatisfy{$0>=0 && $0<=1},"preview progress ends at 100 percent")
   check(zip(fractions,fractions.dropFirst()).allSatisfy{$0 <= $1},"real stage progress never goes backwards")
   first.append(cg)
  }
  let aiFiles=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix("ai-")}.sorted()
  check(aiFiles.count==6,"six photos retain AI results; no four-photo eviction")
  let memory=PreviewMemoryCache()
  for (i,image) in first.enumerated(){memory.insert(image,for:PreviewKey(source:sourceList[i],settings:settings,original:false))}
  for (i,source) in sourceList.prefix(6).enumerated() {
   let cached=memory.image(for:PreviewKey(source:source,settings:settings,original:false))
   check(cached === first[i],"switch returns exact in-memory preview immediately")
  }
  memory.removeAll()
  for (i,source) in sourceList.prefix(6).enumerated() {
   let events=Events()
   let cached=try await processor.preview(source,settings:settings,original:false,willRender:{events.render()}){f,t in events.progress(t,fraction:f)}
   check(events.snapshot().0==0 && events.snapshot().1.isEmpty,"disk cache hit has no render/spinner/progress")
   check(M9Pipeline.rgba(CIImage(cgImage:cached))==M9Pipeline.rgba(CIImage(cgImage:first[i])),"disk cache preserves exact pixels")
  }
  var adjusted=settings;adjusted.filterID="leica_m9"
  let change=Events()
  _=try await processor.preview(sourceList[0],settings:adjusted,original:false,willRender:{change.render()}){f,t in change.progress(t,fraction:f)}
  check(change.snapshot().0==1,"changing settings regenerates final preview")
  check(!change.snapshot().1.contains(where:{$0.contains("准备 M9D") || $0.contains("M9D 风格处理")}),"filter change reuses AI without inference")
  let after=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix("ai-")}.sorted()
  check(after==aiFiles,"filter change does not replace AI results")
  let again=Events()
  _=try await processor.preview(sourceList[0],settings:adjusted,original:false,willRender:{again.render()}){f,t in again.progress(t,fraction:f)}
  check(again.snapshot().0==0,"returning to adjusted photo directly reuses final preview")
  let original=Events()
  _=try await processor.preview(sourceList[0],settings:adjusted,original:true,willRender:{original.render()}){_,_ in}
  let originalAgain=Events()
  _=try await processor.preview(sourceList[0],settings:settings,original:true,willRender:{originalAgain.render()}){_,_ in}
  check(originalAgain.snapshot().0==0,"original comparison independent of effect settings")
  let exported=try await processor.export(sourceList[6],settings:settings){_,_ in}
  let saved=Events()
  _=try await processor.preview(sourceList[6],settings:settings,original:false,willRender:{saved.render()}){f,t in saved.progress(t,fraction:f)}
  check(saved.snapshot().0==0,"batch-exported photo already has ready-to-display preview")
  try FileManager.default.removeItem(at:exported)
  await processor.remove(sourceList[0].id)
  let remaining=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.hasPrefix("ai-")}
  check(remaining.count==6,"removing one photo preserves all other AI cache files")
  await processor.clear()
  let files=try FileManager.default.contentsOfDirectory(atPath:directory.path)
  check(files.allSatisfy{!$0.hasPrefix("ai-") && !$0.hasPrefix("preview-")},"clear removes both cache layers")
  print("ALL PREVIEW CACHE REGRESSION CHECKS PASSED")
  try FileManager.default.removeItem(at:directory)
 } catch { print("FAIL \(error)");exit(1) }
 semaphore.signal()
}
semaphore.wait()
