import Foundation
import CoreImage
import ImageIO
let out=URL(fileURLWithPath:CommandLine.arguments[1])
// Larger than the former 4096-wide limit. No camera-specific input is required.
let w=4608,h=3072
let gradient=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:CGFloat(w),y:CGFloat(h)),"inputColor0":CIColor(red:0.1,green:0.2,blue:0.3),"inputColor1":CIColor(red:0.8,green:0.7,blue:0.6)])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:w,height:h))
let start=Date()
let result=try M9DistillPipeline.process(gradient){_,_ in}
precondition(result.extent.width==CGFloat(w) && result.extent.height==CGFloat(h),"source resolution reduced")
try PhotoExport.writePNG(result,to:out,context:FilterEngine.context)
let decoded=try FilterEngine.source(Data(contentsOf:out))
precondition(decoded.extent==result.extent,"PNG resolution mismatch")
let source=CGImageSourceCreateWithURL(out as CFURL,nil)!
precondition(CGImageSourceGetType(source)! as String=="public.png")
print("PASS full-resolution M9D \(w)x\(h), PNG round trip, \(Date().timeIntervalSince(start)) sec")
