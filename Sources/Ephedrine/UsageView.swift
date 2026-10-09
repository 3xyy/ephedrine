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

    private static let width: CGFloat = 320
    private static let inset: CGFloat = 14
    private static let headerH: CGFloat = 28
    private static let rowH: CGFloat = 34

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(rows: 0)))
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func height(rows: Int) -> CGFloat {
        headerH + (rows == 0 ? 22 : CGFloat(rows) * rowH) + 6
    }

    func update(rows: [Row], status: String, message: String?) {
        self.rows = rows; self.status = status; self.message = message
        let h = Self.height(rows: message == nil ? rows.count : 0)
        if frame.height != h { setFrameSize(NSSize(width: Self.width, height: h)) }
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
        case .normal:   return .controlAccentColor
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let x = Self.inset, w = bounds.width - 2 * Self.inset

        // header: "Claude usage" ………… "click to refresh"
        text("Claude usage", size: NSFont.systemFontSize, weight: .semibold, color: .labelColor)
            .draw(at: NSPoint(x: x, y: 5))
        let st = text(status, size: NSFont.smallSystemFontSize, color: .tertiaryLabelColor)
        st.draw(at: NSPoint(x: x + w - st.size().width, y: 7))

        if let m = message {
            text(m, size: NSFont.systemFontSize, color: .secondaryLabelColor).draw(at: NSPoint(x: x, y: Self.headerH + 2))
            return
        }
        for (i, r) in rows.enumerated() {
            let top = Self.headerH + CGFloat(i) * Self.rowH
            text(r.label, size: NSFont.systemFontSize, color: .labelColor).draw(at: NSPoint(x: x, y: top))
            let d = text(r.detail, size: NSFont.smallSystemFontSize, color: .secondaryLabelColor)
            d.draw(at: NSPoint(x: x + w - d.size().width, y: top + 2))

            let track = NSRect(x: x, y: top + 19, width: w, height: 6)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            let frac = CGFloat(min(max(r.percent, 0), 100) / 100)
            if frac > 0 {
                var fill = track; fill.size.width = max(track.height, track.width * frac)
                barColor(r.level).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
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
