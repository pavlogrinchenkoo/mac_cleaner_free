// Generates the app icon: Assets/AppIcon.icns (+ AppIcon.png for preview).
// Run: swift scripts/make-icon.swift Assets
import AppKit

let canvas: CGFloat = 1024

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let scale = CGFloat(size) / canvas
    let cg = context.cgContext
    cg.scaleBy(x: scale, y: scale)

    // Icon body on the macOS grid: 824 with a 100 margin.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    // Shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor(red: 0.20, green: 0.30, blue: 0.95, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gradient: purple → blue → turquoise.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let gradient = NSGradient(colorsAndLocations:
        (NSColor(red: 0.52, green: 0.30, blue: 1.00, alpha: 1), 0.0),
        (NSColor(red: 0.18, green: 0.42, blue: 1.00, alpha: 1), 0.55),
        (NSColor(red: 0.08, green: 0.80, blue: 0.93, alpha: 1), 1.0))!
    gradient.draw(in: body, angle: -50)

    // Soft highlight at the top left.
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])!
    glow.draw(fromCenter: NSPoint(x: 330, y: 850), radius: 0, toCenter: NSPoint(x: 330, y: 850), radius: 560, options: [])

    // Thin inner rim for depth.
    NSColor.white.withAlphaComponent(0.20).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
    rim.lineWidth = 4
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Symbol: sparkles (cleanliness) over a "disk".
    func symbol(_ name: String, points: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(red: 0.05, green: 0.10, blue: 0.45, alpha: 0.40)
    glyphShadow.shadowBlurRadius = 26
    glyphShadow.shadowOffset = NSSize(width: 0, height: -12)
    glyphShadow.set()

    // Disk (slightly translucent), so it is clear this is about storage space.
    if let drive = symbol("internaldrive.fill", points: 420, weight: .regular) {
        let w = drive.size.width, h = drive.size.height
        drive.draw(in: NSRect(x: 497 - w / 2, y: 405 - h / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 0.96)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Sparkles on top, shifted to the upper right.
    NSGraphicsContext.saveGraphicsState()
    glyphShadow.set()
    if let sparkles = symbol("sparkles", points: 330, weight: .semibold) {
        let w = sparkles.size.width, h = sparkles.size.height
        sparkles.draw(in: NSRect(x: 625 - w / 2, y: 625 - h / 2, width: w, height: h),
                      from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Smaller sizes are made by downscaling the 1024 master with high quality: this keeps the symbols crisp
/// (SF Symbols are rasterized at a fixed size and come out blocky in a downscaled context).
func scaled(_ master: NSBitmapImageRep, to size: Int) -> NSBitmapImageRep {
    if size == master.pixelsWide { return master }
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .high
    context.cgContext.draw(master.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets", isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Standard set of .iconset sizes.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let master = render(size: 1024)
for (name, size) in variants {
    try writePNG(scaled(master, to: size), to: iconset.appendingPathComponent("\(name).png"))
}
try writePNG(master, to: root.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Done: \(root.appendingPathComponent("AppIcon.icns").path)")
