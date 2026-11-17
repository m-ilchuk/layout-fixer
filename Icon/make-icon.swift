// Draws the app icon (two keycaps: "A" behind, "Ї" in front, on blue) at every macOS size and builds
// AppIcon.icns. Run from the repo root: swift Icon/make-icon.swift
import AppKit

let blue = NSColor(srgbRed: 0x37 / 255, green: 0x8A / 255, blue: 0xDD / 255, alpha: 1)
let lightBlue = NSColor(srgbRed: 0xB5 / 255, green: 0xD4 / 255, blue: 0xF4 / 255, alpha: 1)
let darkBlue = NSColor(srgbRed: 0x0C / 255, green: 0x44 / 255, blue: 0x7C / 255, alpha: 1)
let navy = NSColor(srgbRed: 0x04 / 255, green: 0x2C / 255, blue: 0x53 / 255, alpha: 1)

/// The design is drawn on a 120-unit grid (the preview SVG); macOS icons put the body in 824 of 1024 pixels.
let gridBody: CGFloat = 112
let gridOrigin: CGFloat = 4
/// Below this size the letters are only a smudge, so the keycaps are drawn plain.
let lettersFromPixels = 64

func draw(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let size = CGFloat(pixels)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    // Top-left origin, like the SVG.
    cg.translateBy(x: 0, y: size)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    let body = size * 824 / 1024
    let scale = body / gridBody
    let inset = (size - body) / 2
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: inset + (x - gridOrigin) * scale, y: inset + (y - gridOrigin) * scale, width: w * scale, height: h * scale)
    }

    // Body with a soft shadow, as macOS app icons have.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: size * 0.008)
    shadow.set()
    blue.setFill()
    NSBezierPath(roundedRect: rect(4, 4, 112, 112), xRadius: 26 * scale, yRadius: 26 * scale).fill()
    NSGraphicsContext.restoreGraphicsState()

    let showLetters = pixels >= lettersFromPixels
    func keycap(_ frame: NSRect, fill: NSColor, letter: String, color: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 10 * scale, yRadius: 10 * scale).fill()
        guard showLetters else { return }
        let font = NSFont.systemFont(ofSize: 28 * scale, weight: .semibold)
        let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: color])
        let bounds = text.size()
        let capHeight = font.capHeight
        // Centre the capital letters (not the line box) in the keycap.
        let x = frame.midX - bounds.width / 2
        let baseline = frame.midY + capHeight / 2
        text.draw(at: NSPoint(x: x, y: baseline - font.ascender))
    }
    keycap(rect(19, 19, 48, 48), fill: lightBlue, letter: "A", color: darkBlue)
    keycap(rect(53, 53, 48, 48), fill: .white, letter: "Ї", color: navy)

    NSGraphicsContext.current = nil
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = draw(pixels: points * factor).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
// A preview for the README.
try draw(pixels: 256).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Icon/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote Icon/AppIcon.icns and docs/icon.png")
