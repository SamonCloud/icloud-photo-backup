import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16",16), ("icon_16x16@2x",32), ("icon_32x32",32),
                        ("icon_32x32@2x",64), ("icon_128x128",128), ("icon_128x128@2x",256),
                        ("icon_256x256",256), ("icon_256x256@2x",512),
                        ("icon_512x512",512), ("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 198, yRadius: 198)
    NSGradient(starting: NSColor(calibratedRed: 0.04, green: 0.65, blue: 0.94, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.23, blue: 0.69, alpha: 1))!.draw(in: tile, angle: -72)
    let back = NSBezierPath(roundedRect: NSRect(x: 205, y: 376, width: 620, height: 370), xRadius: 58, yRadius: 58)
    NSColor.white.withAlphaComponent(0.25).setFill(); back.fill()
    let folderShape = NSBezierPath()
    folderShape.move(to: NSPoint(x: 235, y: 700))
    folderShape.line(to: NSPoint(x: 406, y: 700))
    folderShape.curve(to: NSPoint(x: 457, y: 672), controlPoint1: NSPoint(x: 433, y: 700), controlPoint2: NSPoint(x: 440, y: 672))
    folderShape.line(to: NSPoint(x: 778, y: 672))
    folderShape.curve(to: NSPoint(x: 840, y: 610), controlPoint1: NSPoint(x: 817, y: 672), controlPoint2: NSPoint(x: 840, y: 650))
    folderShape.line(to: NSPoint(x: 840, y: 322))
    folderShape.curve(to: NSPoint(x: 774, y: 256), controlPoint1: NSPoint(x: 840, y: 278), controlPoint2: NSPoint(x: 819, y: 256))
    folderShape.line(to: NSPoint(x: 242, y: 256))
    folderShape.curve(to: NSPoint(x: 176, y: 322), controlPoint1: NSPoint(x: 197, y: 256), controlPoint2: NSPoint(x: 176, y: 278))
    folderShape.line(to: NSPoint(x: 176, y: 639))
    folderShape.curve(to: NSPoint(x: 235, y: 700), controlPoint1: NSPoint(x: 176, y: 679), controlPoint2: NSPoint(x: 195, y: 700))
    folderShape.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 26; shadow.shadowOffset = NSSize(width: 0, height: -15); shadow.set()
    NSColor.white.setFill(); folderShape.fill()
    NSGraphicsContext.restoreGraphicsState()
    let photo = NSBezierPath(roundedRect: NSRect(x: 266, y: 350, width: 430, height: 253), xRadius: 32, yRadius: 32)
    NSGradient(starting: NSColor(calibratedRed: 0.11, green: 0.57, blue: 0.93, alpha: 1),
               ending: NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.78, alpha: 1))!.draw(in: photo, angle: -90)
    NSGraphicsContext.saveGraphicsState(); photo.addClip()
    let mountains = NSBezierPath()
    mountains.move(to: NSPoint(x: 264, y: 350)); mountains.line(to: NSPoint(x: 264, y: 399))
    mountains.line(to: NSPoint(x: 384, y: 498)); mountains.line(to: NSPoint(x: 467, y: 429))
    mountains.line(to: NSPoint(x: 556, y: 519)); mountains.line(to: NSPoint(x: 700, y: 385))
    mountains.line(to: NSPoint(x: 700, y: 350)); mountains.close()
    NSColor.white.withAlphaComponent(0.93).setFill(); mountains.fill()
    NSColor(calibratedRed: 0.73, green: 0.97, blue: 0.89, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 330, y: 510, width: 52, height: 52)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let badge = NSBezierPath(ovalIn: NSRect(x: 624, y: 168, width: 244, height: 244))
    NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.59, alpha: 1).setFill(); badge.fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 746, y: 355)); arrow.line(to: NSPoint(x: 746, y: 259))
    arrow.move(to: NSPoint(x: 703, y: 301)); arrow.line(to: NSPoint(x: 746, y: 258)); arrow.line(to: NSPoint(x: 789, y: 301))
    arrow.move(to: NSPoint(x: 689, y: 241)); arrow.line(to: NSPoint(x: 689, y: 224))
    arrow.line(to: NSPoint(x: 803, y: 224)); arrow.line(to: NSPoint(x: 803, y: 241))
    arrow.lineWidth = 18; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
}
