import AppKit
let size = 1024
let image = NSImage(size:NSSize(width:size,height:size))
image.lockFocus()
NSColor(calibratedRed:0.065,green:0.07,blue:0.085,alpha:1).setFill()
NSBezierPath(rect:NSRect(x:0,y:0,width:size,height:size)).fill()
let rings: [(CGFloat,NSColor)] = [(360,NSColor(calibratedRed:0.22,green:0.15,blue:0.1,alpha:1)),(290,.orange),(225,NSColor(calibratedRed:0.11,green:0.1,blue:0.12,alpha:1)),(152,NSColor(calibratedRed:0.28,green:0.38,blue:0.42,alpha:1)),(95,NSColor(calibratedRed:0.035,green:0.045,blue:0.055,alpha:1))]
for (r,color) in rings { color.setFill(); NSBezierPath(ovalIn:NSRect(x:512-r,y:512-r,width:2*r,height:2*r)).fill() }
NSColor.white.withAlphaComponent(0.7).setFill()
NSBezierPath(ovalIn:NSRect(x:535,y:560,width:52,height:52)).fill()
image.unlockFocus()
let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
let rep=NSBitmapImageRep(cgImage:cg)
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
