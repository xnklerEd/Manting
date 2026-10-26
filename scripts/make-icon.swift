import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let inset = Double(size) * 0.06
    NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.31, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: Double(size) - inset * 2, height: Double(size) - inset * 2), xRadius: Double(size) * 0.19, yRadius: Double(size) * 0.19).fill()
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.white])) {
        symbol.draw(in: NSRect(x: Double(size) * 0.235, y: Double(size) * 0.275, width: Double(size) * 0.53, height: Double(size) * 0.45))
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: destination.appendingPathComponent("icon_\(name).png"))
}
