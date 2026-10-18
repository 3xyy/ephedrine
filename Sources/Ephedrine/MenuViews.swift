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
        var block = NSRect.zero                       // the always-on feature rows (empty when none)
        var rows: [(rect: NSRect, row: FeatureRow)] = []
        var hint: (rect: NSRect, text: String)?
        var notes: [(rect: NSRect, text: String)] = []
        var warnings: [(rect: NSRect, text: String)] = []
        var height: CGFloat = 0
    }
    private var layout = Layout()

    private static let headlineFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let smallFont = NSFont.systemFont(ofSize: 11)
    private static let chipPad: CGFloat = 6       // chip side padding
    private static let chipIconGap: CGFloat = 4   // chip icon to text
    private static let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let textX: CGFloat = 56
    private static let rowFont = NSFont.systemFont(ofSize: 11.5)
    private static let rowH: CGFloat = 24
    private static let blockPad: CGFloat = 4
    private static let rowIconX: CGFloat = 9, rowLabelX: CGFloat = 31, rowTextX: CGFloat = 109

    init(status: MenuStatus, glyph: NSImage, tint: NSColor) {
        self.status = status; self.glyph = glyph; self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 40))
        layout = computeLayout()
        setFrameSize(NSSize(width: MenuMetrics.width, height: layout.height))
        setAccessibilityRole(.staticText)
        var parts = [status.headline]
        if let d = status.detail { parts.append(d) }
        parts += status.chips.map(\.text)
        parts += status.features.map { "\($0.label), \($0.text)" }
        if let h = status.hint { parts.append(h) }
        parts += status.notes + status.warnings
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
        case .power: return "bolt.fill"
        case .battery(let level, let charging):
            return charging ? "battery.100percent.bolt" : "battery.\(level)percent"
        case .wifi: return "wifi"
        }
    }

    private static func rowSymbol(_ kind: FeatureKind) -> String {
        switch kind {
        case .lid: return "laptopcomputer"
        case .lowPower: return "leaf"
        case .whenShut: return "speaker.slash"
        case .cmux: return "terminal"
        case .hotspot: return "iphone"
        case .network: return "waveform.path.ecg"
        case .tmux: return "rectangle.split.3x1"
        }
    }

    private static func rowIconColor(_ tone: RowTone) -> NSColor {
        switch tone {
        case .active: return claudeOrange
        case .warn: return menuWarningColor
        default: return .secondaryLabelColor
        }
    }

    private static func rowTextColor(_ tone: RowTone) -> NSColor {
        switch tone {
        case .warn: return menuWarningColor
        case .dim: return .secondaryLabelColor
        default: return .labelColor
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
                let cw = Self.chipPad + (icon?.size.width ?? 0) + Self.chipIconGap + tw + Self.chipPad
                if x > MenuMetrics.inset && x + cw > maxX { x = MenuMetrics.inset; y += 22 + 5 }
                l.chips.append((NSRect(x: x, y: y, width: cw, height: 22), chip))
                x += cw + 4
            }
            y += 22
        }

        let lineW = w - 2 * MenuMetrics.inset
        if !status.features.isEmpty {
            y += 10
            let bh = Self.blockPad * 2 + Self.rowH * CGFloat(status.features.count)
            l.block = NSRect(x: MenuMetrics.inset, y: y, width: lineW, height: bh)
            var ry = y + Self.blockPad
            for r in status.features {
                l.rows.append((NSRect(x: MenuMetrics.inset, y: ry, width: lineW, height: Self.rowH), r))
                ry += Self.rowH
            }
            y += bh
            if let hint = status.hint {
                y += 8
                let hh = max(15, wrappedHeight(attributed(hint, Self.smallFont, .secondaryLabelColor), width: lineW))
                l.hint = (NSRect(x: MenuMetrics.inset, y: y, width: lineW, height: hh), hint)
                y += hh
            }
        }

        var first = true
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
            var x = rect.minX + Self.chipPad
            if let icon = symbol(Self.symbolName(chip.kind), size: 11, color: .secondaryLabelColor) {
                let r = NSRect(x: x, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
                icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += icon.size.width + Self.chipIconGap
            }
            let t = attributed(chip.text, Self.chipFont, .labelColor)
            t.draw(at: NSPoint(x: x, y: rect.midY - t.size().height / 2))
        }

        if !layout.rows.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: layout.block, xRadius: 8, yRadius: 8).fill()
        }
        for (rect, row) in layout.rows {
            if let icon = symbol(Self.rowSymbol(row.kind), size: 13, color: Self.rowIconColor(row.tone)) {
                let r = NSRect(x: rect.minX + Self.rowIconX, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
                icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let label = attributed(row.label, Self.rowFont, .secondaryLabelColor)
            label.draw(at: NSPoint(x: rect.minX + Self.rowLabelX, y: rect.midY - label.size().height / 2))
            var tx = rect.minX + Self.rowTextX
            if row.tone == .ok {
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: NSRect(x: tx, y: rect.midY - 3, width: 6, height: 6)).fill()
                tx += 11
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let t = NSAttributedString(string: row.text, attributes: [
                .font: Self.rowFont, .foregroundColor: Self.rowTextColor(row.tone), .paragraphStyle: para])
            let th = ceil(t.size().height)
            t.draw(with: NSRect(x: tx, y: rect.midY - th / 2, width: max(0, rect.maxX - Self.rowIconX - tx), height: th),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if let (rect, text) = layout.hint {
            attributed(text, Self.smallFont, .secondaryLabelColor).draw(with: rect, options: opts)
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
