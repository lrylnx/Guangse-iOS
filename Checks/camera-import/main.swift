import Foundation
import CoreImage

func check(_ value: Bool,_ message:String){precondition(value,message);print("PASS \(message)")}
let project=URL(fileURLWithPath:CommandLine.arguments[1])
let run=project.appendingPathComponent("Checks/camera-import/\(UUID().uuidString)")
try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
let outbox=try CameraOriginalStore(directory:run.appendingPathComponent("durable-originals"))
let input=try Data(contentsOf:project.appendingPathComponent("Checks/sample.jpg"))
let id=UUID()
let original=try outbox.stage(input,id:id)
check(try Data(contentsOf:original)==input,"captured original stored byte-exact; no JPEG/HEIC re-encoding")
check(try outbox.pending()==[original],"unsaved original recoverable from durable outbox")
let restarted=try CameraOriginalStore(directory:outbox.directory)
check(try restarted.pending()==[original],"new session discovers unconfirmed camera original")
let type=try CameraOriginalStore.type(of:original)
check(type.identifier=="public.jpeg","original type detected from bytes, independent of filename")
let imported=run.appendingPathComponent("album-original.image")
try input.write(to:imported)
// A camera-origin file and an album-origin copy carry exactly the same source bytes.
let cameraSource=PhotoSource(id:id,url:original)
let albumSource=PhotoSource(id:UUID(),url:imported)
let actor=PhotoProcessor(directory:run)
let semaphore=DispatchSemaphore(value:0)
Task.detached {
 do {
  let settings=EditorSettings()
  let camera=try await actor.preview(cameraSource,settings:settings,original:false){_,_ in}
  let album=try await actor.preview(albumSource,settings:settings,original:false){_,_ in}
  check(camera.width==album.width && camera.height==album.height,"camera/import image geometry identical")
  check(M9Pipeline.rgba(CIImage(cgImage:camera))==M9Pipeline.rgba(CIImage(cgImage:album)),"same original + same settings produce pixel-identical M9D preview")
  let cameraPNG=try await actor.export(cameraSource,settings:settings){_,_ in}
  let albumPNG=try await actor.export(albumSource,settings:settings){_,_ in}
  let a=try FilterEngine.source(Data(contentsOf:cameraPNG))
  let b=try FilterEngine.source(Data(contentsOf:albumPNG))
  check(a.extent==b.extent && M9Pipeline.rgba(a)==M9Pipeline.rgba(b),"camera/import full PNG pixel parity")
  check(try Data(contentsOf:original)==input,"filter generation never modifies original capture file")
  await actor.clear()
  check(try restarted.pending()==[original],"clearing processing cache cannot delete unsaved original")
  try restarted.confirm(imported)
  check(FileManager.default.fileExists(atPath:imported.path),"confirmation cannot delete unrelated files")
  try restarted.confirm(original)
  check(try restarted.pending().isEmpty,"confirmed originals removed only from outbox")
  do { _=try restarted.stage(Data([0,1,2,3]),id:UUID());fatalError("invalid capture accepted") }
  catch PhotoError.invalidImage { print("PASS invalid capture rejected") }
  try FileManager.default.removeItem(at:run)
  print("ALL CAMERA INPUT / ORIGINAL PRESERVATION CHECKS PASSED")
 } catch {print("FAIL \(error)");exit(1)}
 semaphore.signal()
}
semaphore.wait()
