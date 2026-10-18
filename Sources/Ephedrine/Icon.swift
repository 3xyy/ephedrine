import Cocoa
import EphedrineCore

/// Claude's orange (#D97757), for the colored menu bar styles.
let claudeOrange = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)

func bezierPath(_ ops: [PathOp]) -> NSBezierPath {
    let path = NSBezierPath()
    for op in ops {
        switch op {
        case .move(let p): path.move(to: p)
        case .line(let p): path.line(to: p)
        case .quad(let c, let p):
            // NSBezierPath has no quadratic curve, so lift it to a cubic.
            let s = path.currentPoint
            path.curve(to: p, controlPoint1: NSPoint(x: s.x + 2 / 3 * (c.x - s.x), y: s.y + 2 / 3 * (c.y - s.y)),
                       controlPoint2: NSPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y)))
        case .cubic(let c1, let c2, let p): path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
        case .close: path.close()
        }
    }
    return path
}

/// The Claude spark, parsed once. nil (logged once) means draw the cup without it.
private let sparkOps: [PathOp]? = {
    let ops = parseSVGPath(claudeSparkPath)
    if ops == nil { NSLog("Ephedrine: could not parse the spark path, drawing the cup without it") }
    return ops
}()

private let iconSize = NSSize(width: 18, height: 18)

/// The menu bar icon while the Mac is kept awake: a cup with the Claude spark as its steam.
///   mono:   template, so macOS tints it like every other menu bar icon
///   accent: cup in the menu bar's text color, spark in orange
///   state:  cup and spark both orange
func menuBarAwakeIcon(style: MenuBarIconStyle) -> NSImage {
    // Flipped, so the glyph's SVG coordinates (y down) apply as written.
    func glyph(cup: @escaping () -> NSColor, spark: @escaping () -> NSColor) -> NSImage {
        NSImage(size: iconSize, flipped: true) { r in drawCupGlyph(in: r, cup: cup(), spark: spark()); return true }
    }
    let img: NSImage
    switch style {
    case .mono:
        img = glyph(cup: { .black }, spark: { .black })
        img.isTemplate = true
    case .accent:
        // Resolved on each draw, so labelColor follows the menu bar's
        // current look (it changes with the wallpaper).
        img = glyph(cup: { .labelColor }, spark: { claudeOrange })
    case .state:
        img = glyph(cup: { claudeOrange }, spark: { claudeOrange })
    }
    img.accessibilityDescription = "Ephedrine"
    return img
}

/// The cup glyph, drawn from the 18-unit design (icon-options/glyph-steam-*.svg)
/// scaled to `rect`. Needs a flipped context (y down). `spark: nil` leaves the
/// steam out.
func drawCupGlyph(in rect: NSRect, cup: NSColor, spark: NSColor?) {
    guard let ctx = NSGraphicsContext.current else { return }
    ctx.saveGraphicsState()
    let xf = NSAffineTransform()
    xf.translateX(by: rect.minX, yBy: rect.minY)
    xf.scale(by: rect.width / 18)
    xf.concat()

    // The cup's parts overlap, so draw them opaque in one layer and apply the
    // color's alpha (labelColor has some) to the whole, or the seams show.
    let opaque = cup.withAlphaComponent(1)
    ctx.cgContext.setAlpha(cup.alphaComponent)
    ctx.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    opaque.setFill()
    opaque.setStroke()
    if let body = parseSVGPath("M3.4 7.6H12.2L11.7 13.3Q11.5 15.2 9.6 15.2H6Q4.1 15.2 3.9 13.3Z") {
        bezierPath(body).fill()
    }
    NSBezierPath(roundedRect: NSRect(x: 2.9, y: 6.6, width: 9.8, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
    if let handle = parseSVGPath("M11.9 8.9C14.9 8.7 15.1 12.8 11.5 12.6") {
        let p = bezierPath(handle)
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        p.stroke()
    }
    ctx.cgContext.endTransparencyLayer()
    ctx.cgContext.setAlpha(1)
    if let spark = spark, let ops = sparkOps {
        let t = NSAffineTransform()
        t.translateX(by: 4.8, yBy: 0.2)
        t.scale(by: 0.25)
        let p = bezierPath(ops)
        p.transform(using: t as AffineTransform)
        spark.setFill()
        p.fill()
    }
    ctx.restoreGraphicsState()
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
