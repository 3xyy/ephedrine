import Cocoa
import EphedrineCore

/// Custom menu row for Claude usage: one horizontal bar per limit (session,
/// weekly, per-model like "Fable only"). Clicking refreshes in place WITHOUT
/// closing the menu (view-based items don't auto-dismiss), and it redraws
/// live when the async fetch returns.
final class UsageView: NSView {
    struct Row {
        let label: String     // "Session (5h)"
        let percent: Double
        let detail: String    // "38% · resets 1:10 AM"
        let level: UsageLevel
    }

    var onClick: (() -> Void)?
    private var rows: [Row] = []
    private var status = ""
    private var message: String? = "Loading…"
    private var hovered = false

    private static let topPad: CGFloat = 4
    private static let headerH: CGFloat = 22
    private static let rowLabelH: CGFloat = 15
    private static let rowGap: CGFloat = 9
    private static let rowH: CGFloat = 25

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: Self.height(rows: 0)))
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func height(rows: Int) -> CGFloat {
        topPad + headerH + (rows == 0 ? 17 : 5 + CGFloat(rows) * rowH + CGFloat(rows - 1) * rowGap) + 6
    }

    func update(rows: [Row], status: String, message: String?) {
        self.rows = rows; self.status = status; self.message = message
        let h = Self.height(rows: message == nil ? rows.count : 0)
        if frame.height != h { setFrameSize(NSSize(width: MenuMetrics.width, height: h)) }
        setAccessibilityLabel(message ?? rows.map { "\($0.label) \($0.detail)" }.joined(separator: ", "))
        needsDisplay = true
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }

    private func barColor(_ level: UsageLevel) -> NSColor {
        switch level {
        case .normal:   return claudeOrange
        case .warning:  return menuWarningColor
        case .critical: return .systemRed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let x = MenuMetrics.inset, w = bounds.width - 2 * MenuMetrics.inset

        // header: "Claude usage" ………… "↻ click to refresh"
        let hy = Self.topPad + Self.headerH / 2
        let title = text("Claude usage", size: 12, weight: .semibold, color: .labelColor)
        title.draw(at: NSPoint(x: x, y: hy - title.size().height / 2))
        let st = text(status, size: 11, color: .tertiaryLabelColor)
        var sx = x + w - st.size().width
        st.draw(at: NSPoint(x: sx, y: hy - st.size().height / 2))
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
        if !status.isEmpty, let arrow = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            sx -= arrow.size.width + 4
            arrow.draw(in: NSRect(x: sx, y: hy - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let top0 = Self.topPad + Self.headerH
        if let m = message {
            text(m, size: 12, color: .secondaryLabelColor).draw(at: NSPoint(x: x, y: top0 + 1))
            return
        }
        for (i, r) in rows.enumerated() {
            let top = top0 + 5 + CGFloat(i) * (Self.rowH + Self.rowGap)
            text(r.label, size: 12, color: .labelColor).draw(at: NSPoint(x: x, y: top))
            let d = text(r.detail, size: 11, color: .secondaryLabelColor)
            d.draw(at: NSPoint(x: x + w - d.size().width, y: top + 1))

            let track = NSRect(x: x, y: top + Self.rowLabelH + 5, width: w, height: 5)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            let frac = CGFloat(min(max(r.percent, 0), 100) / 100)
            if frac > 0 {
                var fill = track; fill.size.width = max(track.height, track.width * frac)
                barColor(r.level).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseUp(with e: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
