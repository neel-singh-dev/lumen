import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSBezierPath(roundedRect: rect, xRadius: 232, yRadius: 232).addClip()
NSColor.black.setFill()
rect.fill()
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
    .applying(.init(paletteColors: [NSColor.systemTeal]))
if let symbol = NSImage(systemSymbolName: "rays", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width * 2.2) / 2, y: (size - s.height * 2.2) / 2,
                           width: s.width * 2.2, height: s.height * 2.2))
}
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let dir = "Lumen/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: dir + "/icon_512x512@2x.png"))
let contents = """
{"images":[{"filename":"icon_512x512@2x.png","idiom":"mac","scale":"2x","size":"512x512"}],
 "info":{"author":"xcode","version":1}}
"""
try! contents.write(toFile: dir + "/Contents.json", atomically: true, encoding: .utf8)
try? """
{"info":{"author":"xcode","version":1}}
""".write(toFile: "Lumen/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
print("icon written")
