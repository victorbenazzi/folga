// Renders the app icon (1024x1024 PNG). Usage: swift make-icon.swift out.png
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 100, dy: 100)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.62, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.38, blue: 0.62, alpha: 1)])!.draw(in: path, angle: -60)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "wind", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
