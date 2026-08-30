// Packs the canonical 1024px app-icon snapshot into AppIcon.icns.
// First render it with:
//   swift run FlowClone --icon-snapshot Support/AppIcon-1024.png
// Then run:
//   swift scripts/make-icon.swift
import AppKit

func savePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let supportDir = scriptDir.deletingLastPathComponent().appendingPathComponent("Support")
let sourceURL = supportDir.appendingPathComponent("AppIcon-1024.png")
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("❌ Missing Support/AppIcon-1024.png; render --icon-snapshot first.\n", stderr)
    exit(1)
}
let iconset = supportDir.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    savePNG(source, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"), pixels: base)
    savePNG(source, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"), pixels: base * 2)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", supportDir.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "✅ Support/AppIcon.icns written" : "❌ iconutil failed")
