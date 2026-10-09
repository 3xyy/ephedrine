// Draws Ephedrine's app icon (a steaming coffee cup) and writes AppIcon.icns.
//   swift icon/make-icon.swift [variant]   (run from the repo root)
import AppKit

let variant = CommandLine.arguments.dropFirst().first ?? "mocha"

/// Claude-style spark: tapered rays of alternating length with round tips.
func drawSpark(center c: NSPoint, radius r: CGFloat, rays: Int) {
    for i in 0..<rays {
        let a = CGFloat(i) / CGFloat(rays) * 2 * .pi + .pi / 2
        let len = r * (i % 2 == 0 ? 1.0 : 0.78)
        let base = r * 0.17, tipW = r * 0.085
        let dir = NSPoint(x: cos(a), y: sin(a)), perp = NSPoint(x: -sin(a), y: cos(a))
        let tip = NSPoint(x: c.x + dir.x * len, y: c.y + dir.y * len)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + perp.x * base, y: c.y + perp.y * base))
        p.line(to: NSPoint(x: tip.x + perp.x * tipW, y: tip.y + perp.y * tipW))
        p.line(to: NSPoint(x: tip.x - perp.x * tipW, y: tip.y - perp.y * tipW))
        p.line(to: NSPoint(x: c.x - perp.x * base, y: c.y - perp.y * base))
        p.close(); p.fill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - tipW, y: tip.y - tipW, width: tipW * 2, height: tipW * 2)).fill()
    }
    NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.2, y: c.y - r * 0.2, width: r * 0.4, height: r * 0.4)).fill()
}

func render(size px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024   // design on a 1024 canvas (macOS icon grid: 824pt body, 100pt margin)

    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // soft drop shadow under the tile
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
    sh.shadowBlurRadius = 24 * s; sh.shadowOffset = NSSize(width: 0, height: -10 * s); sh.set()
    NSColor.black.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    let (top, bottom, cup): (NSColor, NSColor, NSColor) = variant == "latte"
        ? (NSColor(srgbRed: 0.98, green: 0.93, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.90, green: 0.78, blue: 0.62, alpha: 1),
           NSColor(srgbRed: 0.36, green: 0.21, blue: 0.12, alpha: 1))
        : (NSColor(srgbRed: 0.83, green: 0.56, blue: 0.32, alpha: 1), NSColor(srgbRed: 0.36, green: 0.20, blue: 0.11, alpha: 1),
           NSColor(srgbRed: 1.00, green: 0.97, blue: 0.92, alpha: 1))
    NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

    // subtle top highlight
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: .clear)!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // steaming cup (SF Symbol), centered, with a gentle shadow
    let cfg = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [cup]))
    if let sym = NSImage(systemSymbolName: "cup.and.heat.waves.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = sym.size
        let r = NSRect(x: body.midX - sz.width / 2, y: body.midY - sz.height / 2 - 6 * s, width: sz.width, height: sz.height)
        NSGraphicsContext.saveGraphicsState()
        let cs = NSShadow(); cs.shadowColor = NSColor.black.withAlphaComponent(0.25)
        cs.shadowBlurRadius = 14 * s; cs.shadowOffset = NSSize(width: 0, height: -6 * s); cs.set()
        sym.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        // Claude spark on the cup body (the cup sits low-left of the symbol box; handle on the right)
        NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()   // ≈ #D97757
        drawSpark(center: NSPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.245),
                  radius: r.height * 0.13, rays: 12)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let set = "AppIcon.iconset"
try? fm.removeItem(atPath: set)
try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: base * scale).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(set)/\(name)"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(atPath: set)
print(p.terminationStatus == 0 ? "wrote AppIcon.icns (\(variant))" : "iconutil failed")
