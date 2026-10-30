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
    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 190, yRadius: 190)
    NSGradient(starting: NSColor(calibratedRed: 0.07, green: 0.61, blue: 0.99, alpha: 1),
               ending: NSColor(calibratedRed: 0.11, green: 0.28, blue: 0.86, alpha: 1))!.draw(in: tile, angle: -90)
    let photo = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))!
    photo.draw(in: NSRect(x: 208, y: 325, width: 608, height: 430))
    let circle = NSBezierPath(ovalIn: NSRect(x: 596, y: 162, width: 256, height: 256))
    NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.53, alpha: 1).setFill(); circle.fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 724, y: 355)); arrow.line(to: NSPoint(x: 724, y: 233))
    arrow.move(to: NSPoint(x: 677, y: 280)); arrow.line(to: NSPoint(x: 724, y: 233)); arrow.line(to: NSPoint(x: 771, y: 280))
    arrow.lineWidth = 22; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
}
