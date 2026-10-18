import Cocoa
import EphedrineCore

/// Claude's orange (#D97757), for the colored menu bar styles.
let claudeOrange = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)

/// Claude-style spark (same shape as icon/make-icon.swift), filled with the
/// current fill color.
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

private let iconSize = NSSize(width: 18, height: 18)

/// The menu bar icon while the Mac is kept awake: a mug with the spark cut out.
///   mono:   template, so macOS tints it like every other menu bar icon
///   accent: mug in the menu bar's text color, spark filled in orange
///   state:  the whole mug orange
func menuBarAwakeIcon(style: MenuBarIconStyle) -> NSImage {
    let img: NSImage
    switch style {
    case .mono:
        img = NSImage(size: iconSize, flipped: false) { r in drawAwakeMug(in: r, mug: .black, spark: nil); return true }
        img.isTemplate = true
    case .accent:
        // Drawn on demand, so labelColor resolves against the menu bar's
        // current look (it changes with the wallpaper).
        img = NSImage(size: iconSize, flipped: false) { r in drawAwakeMug(in: r, mug: .labelColor, spark: claudeOrange); return true }
    case .state:
        img = NSImage(size: iconSize, flipped: false) { r in drawAwakeMug(in: r, mug: claudeOrange, spark: nil); return true }
    }
    img.accessibilityDescription = "Ephedrine"
    return img
}

/// The other states' SF Symbols, tinted when `tint` is set, else template.
func menuBarSymbolIcon(_ name: String, tint: NSColor?) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Ephedrine") else { return nil }
    guard let tint = tint else { base.isTemplate = true; return base }
    let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) ?? base
    img.isTemplate = false
    return img
}

/// Tint for the non-awake states under "Color by state"; idle stays plain.
func menuBarStateTint(style: MenuBarIconStyle, away: Bool, lidSession: Bool) -> NSColor? {
    guard style == .state else { return nil }
    return away ? .systemPurple : lidSession ? .systemBlue : nil
}

/// Mug filled with `mug`, spark knocked out, then (optionally) the spark
/// filled with `spark` and a thin gap around it. Done inside a transparency
/// layer so the knock-out only ever erases the mug, never what's behind it.
func drawAwakeMug(in rect: NSRect, mug: NSColor, spark: NSColor?) {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    guard let cup = NSImage(systemSymbolName: "mug.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg),
          let ctx = NSGraphicsContext.current else { return }
    let s = cup.size
    let r = NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height)
    let center = NSPoint(x: r.minX + r.width * 0.40, y: r.minY + r.height * 0.46)
    let radius = r.height * 0.27

    ctx.saveGraphicsState()
    ctx.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    cup.draw(in: r)
    mug.setFill()
    r.fill(using: .sourceAtop)                       // recolor the symbol, keeping its shape
    ctx.compositingOperation = .destinationOut
    NSColor.black.setFill()
    drawSpark(center: center, radius: spark == nil ? radius : radius * 1.15, rays: 8)
    ctx.cgContext.endTransparencyLayer()
    ctx.restoreGraphicsState()

    if let spark = spark {
        spark.setFill()
        drawSpark(center: center, radius: radius, rays: 8)
    }
}
