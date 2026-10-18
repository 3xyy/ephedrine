import Cocoa
import EphedrineCore

/// A small dark panel under the status item for typing a Stay awake length in
/// days, hours and minutes. Enter submits, Esc or clicking away closes it, and
/// an invalid entry shakes the panel and stays open.
final class DurationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onClose: (() -> Void)?

    override func resignKey() {
        super.resignKey()
        close()
    }
    override func close() {
        super.close()
        onClose?(); onClose = nil
    }
    override func cancelOperation(_ sender: Any?) { close() }
}

final class DurationPanelController: NSObject, NSTextFieldDelegate {
    enum Mode { case start, add }

    private var panel: DurationPanel?
    private var fields: [NSTextField] = []
    private var onSubmit: ((TimeInterval) -> Void)?

    private static let size = NSSize(width: 264, height: 84)

    func show(below button: NSStatusBarButton, mode: Mode, onSubmit: @escaping (TimeInterval) -> Void) {
        panel?.close()
        self.onSubmit = onSubmit

        let panel = DurationPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                  styleMask: [.nonactivatingPanel, .borderless],
                                  backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onClose = { [weak self] in self?.panel = nil }

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        fields = ["Days", "Hours", "Minutes"].map { name in
            let f = NSTextField()
            f.placeholderString = name
            f.bezelStyle = .roundedBezel
            f.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            f.alignment = .center
            f.delegate = self
            f.setAccessibilityLabel(name)
            f.widthAnchor.constraint(equalToConstant: 76).isActive = true
            return f
        }
        for (i, f) in fields.enumerated() { f.nextKeyView = fields[(i + 1) % fields.count] }

        let row = NSStackView(views: fields)
        row.orientation = .horizontal
        row.spacing = 8
        let hint = NSTextField(labelWithString: (mode == .start ? "Start" : "Add") + " \u{21A9}")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let column = NSStackView(views: [row, hint])
        column.orientation = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        panel.contentView = bg
        panel.initialFirstResponder = fields[1]

        // Top-left just below the button, kept on screen.
        if let bw = button.window {
            let b = bw.frame
            var origin = NSPoint(x: b.minX, y: b.minY - Self.size.height - 4)
            if let screen = bw.screen ?? NSScreen.main {
                origin.x = min(origin.x, screen.visibleFrame.maxX - Self.size.width - 8)
            }
            panel.setFrameOrigin(origin)
        }
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(fields[1])
    }

    private func submit() {
        guard fields.count == 3,
              let secs = parseDuration(days: fields[0].stringValue, hours: fields[1].stringValue,
                                       minutes: fields[2].stringValue) else { shake(); return }
        let cb = onSubmit
        panel?.close()
        cb?(secs)
    }

    private func shake() {
        guard let panel = panel else { return }
        let anim = CAKeyframeAnimation(keyPath: "position.x")
        anim.values = [0, -4, 4, -4, 4, 0]   // ±4 pt over 0.3 s
        anim.isAdditive = true
        anim.duration = 0.3
        panel.contentView?.layer?.add(anim, forKey: "shake")
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        let digits = String(f.stringValue.filter { $0.isASCII && $0.isNumber }.prefix(3))
        if digits != f.stringValue { f.stringValue = digits }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): submit(); return true
        case #selector(NSResponder.cancelOperation(_:)): panel?.close(); return true
        default: return false
        }
    }
}
