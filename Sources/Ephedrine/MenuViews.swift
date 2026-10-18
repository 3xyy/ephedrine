import Cocoa
import EphedrineCore

enum MenuMetrics {
    static let width: CGFloat = 320
    static let inset: CGFloat = 14
}

/// Warning text: systemOrange is unreadable on a light menu, so light looks use a darker amber.
let menuWarningColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .systemOrange
        : NSColor(srgbRed: 0xA6 / 255.0, green: 0x52 / 255.0, blue: 0, alpha: 1)
}

/// The top of the menu: one custom-drawn status card (glyph tile, headline,
/// detail, chips, notes, warnings). Not clickable, no hover.
final class StatusCardView: NSView {
    private let status: MenuStatus
    private let glyph: NSImage
    private let tint: NSColor

    private struct Layout {
        var tile = NSRect.zero
        var headline = NSRect.zero
        var detail: NSRect?
        var chips: [(rect: NSRect, chip: StatusChip)] = []
        var notes: [(rect: NSRect, text: String)] = []
        var warnings: [(rect: NSRect, text: String)] = []
        var height: CGFloat = 0
    }
    private var layout = Layout()

    private static let headlineFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let smallFont = NSFont.systemFont(ofSize: 11)
    private static let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let textX: CGFloat = 56

    init(status: MenuStatus, glyph: NSImage, tint: NSColor) {
        self.status = status; self.glyph = glyph; self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 40))
        layout = computeLayout()
        setFrameSize(NSSize(width: MenuMetrics.width, height: layout.height))
        setAccessibilityRole(.staticText)
        var parts = [status.headline]
        if let d = status.detail { parts.append(d) }
        parts += status.chips.map(\.text) + status.notes + status.warnings
        setAccessibilityLabel(parts.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func attributed(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    private func wrappedHeight(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(s.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    private static func symbolName(_ kind: StatusChip.Kind) -> String {
        switch kind {
        case .lid: return "laptopcomputer"
        case .power: return "bolt.fill"
        case .battery(let level, let charging):
            return charging ? "battery.100percent.bolt" : "battery.\(level)percent"
        case .wifi: return "wifi"
        }
    }

    private func computeLayout() -> Layout {
        var l = Layout()
        let w = MenuMetrics.width
        let textW = w - Self.textX - MenuMetrics.inset
        let h = attributed(status.headline, Self.headlineFont, .labelColor)
        let hH = wrappedHeight(h, width: textW)
        var dH: CGFloat = 0
        if let d = status.detail { dH = wrappedHeight(attributed(d, Self.smallFont, .secondaryLabelColor), width: textW) }
        let blockH = hH + (dH > 0 ? 1 + dH : 0)
        let headerH = max(32, blockH)
        var y: CGFloat = 10
        l.tile = NSRect(x: MenuMetrics.inset, y: y + (headerH - 32) / 2, width: 32, height: 32)
        let ty = y + (headerH - blockH) / 2
        l.headline = NSRect(x: Self.textX, y: ty, width: textW, height: hH)
        if dH > 0 { l.detail = NSRect(x: Self.textX, y: ty + hH + 1, width: textW, height: dH) }
        y += headerH

        if !status.chips.isEmpty {
            y += 10
            var x = MenuMetrics.inset
            let maxX = w - MenuMetrics.inset
            for chip in status.chips {
                let icon = symbol(Self.symbolName(chip.kind), size: 11, color: .secondaryLabelColor)
                let tw = ceil(attributed(chip.text, Self.chipFont, .labelColor).size().width)
                let cw = 8 + (icon?.size.width ?? 0) + 5 + tw + 8
                if x > MenuMetrics.inset && x + cw > maxX { x = MenuMetrics.inset; y += 22 + 5 }
                l.chips.append((NSRect(x: x, y: y, width: cw, height: 22), chip))
                x += cw + 5
            }
            y += 22
        }

        var first = true
        let lineW = w - 2 * MenuMetrics.inset
        for n in status.notes {
            y += first ? 9 : 0; first = false
            let nh = max(16, wrappedHeight(attributed(n, Self.smallFont, .secondaryLabelColor), width: lineW))
            l.notes.append((NSRect(x: MenuMetrics.inset, y: y, width: lineW, height: nh), n))
            y += nh
        }
        for t in status.warnings {
            y += first ? 9 : 0; first = false
            let iconW = symbol("exclamationmark.triangle.fill", size: 10, color: menuWarningColor)?.size.width ?? 0
            let tw = lineW - iconW - 5
            let wh = max(16, wrappedHeight(attributed(t, Self.smallFont, menuWarningColor), width: tw))
            l.warnings.append((NSRect(x: MenuMetrics.inset, y: y, width: lineW, height: wh), t))
            y += wh
        }
        l.height = y + 12
        return l
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        tint.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: layout.tile, xRadius: 8, yRadius: 8).fill()
        let g = NSRect(x: layout.tile.midX - 10, y: layout.tile.midY - 10, width: 20, height: 20)
        let gs = glyph.size
        let fit = min(20 / max(gs.width, 1), 20 / max(gs.height, 1), 1)
        let gr = NSRect(x: g.midX - gs.width * fit / 2, y: g.midY - gs.height * fit / 2, width: gs.width * fit, height: gs.height * fit)
        glyph.draw(in: gr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)

        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        attributed(status.headline, Self.headlineFont, .labelColor).draw(with: layout.headline, options: opts)
        if let d = layout.detail, let s = status.detail {
            attributed(s, Self.smallFont, .secondaryLabelColor).draw(with: d, options: opts)
        }

        for (rect, chip) in layout.chips {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            var x = rect.minX + 8
            if let icon = symbol(Self.symbolName(chip.kind), size: 11, color: .secondaryLabelColor) {
                let r = NSRect(x: x, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
                icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += icon.size.width + 5
            }
            let t = attributed(chip.text, Self.chipFont, .labelColor)
            t.draw(at: NSPoint(x: x, y: rect.midY - t.size().height / 2))
        }

        for (rect, text) in layout.notes {
            attributed(text, Self.smallFont, .secondaryLabelColor).draw(with: rect, options: opts)
        }
        for (rect, text) in layout.warnings {
            var x = rect.minX
            if let icon = symbol("exclamationmark.triangle.fill", size: 10, color: menuWarningColor) {
                // aligned with the first text line (16 pt tall)
                let r = NSRect(x: x, y: rect.minY + (16 - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
                icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += icon.size.width + 5
            }
            attributed(text, Self.smallFont, menuWarningColor)
                .draw(with: NSRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height), options: opts)
        }
    }
}

/// "Keep awake while Claude works": a title and a switch in one menu row. The
/// switch is drawn by hand because the menu window is never key, which turns a
/// real NSSwitch grey even when it's on. The whole row is the click target.
final class SwitchRowView: NSView {
    private var isOn: Bool
    private let title: String
    private let onToggle: (Bool) -> Void
    private var hovered = false

    init(title: String, isOn: Bool, toolTip: String?, onToggle: @escaping (Bool) -> Void) {
        self.title = title; self.isOn = isOn; self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 26))
        self.toolTip = toolTip
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        t.draw(at: NSPoint(x: MenuMetrics.inset, y: (bounds.height - t.size().height) / 2))

        let pill = NSRect(x: bounds.width - MenuMetrics.inset - 26, y: (bounds.height - 15) / 2, width: 26, height: 15)
        (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.2)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
        let kx = isOn ? pill.maxX - 14 : pill.minX + 1
        let knob = NSRect(x: kx, y: pill.minY + 1, width: 13, height: 13)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func flip() {
        isOn.toggle()
        needsDisplay = true
        onToggle(isOn)
    }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
    override func mouseUp(with e: NSEvent) { flip() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovered = false; needsDisplay = true }
}
