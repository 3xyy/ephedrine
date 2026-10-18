import Cocoa
import EphedrineCore

/// One rounded, faintly filled slot with a borderless text field; shows an accent ring while focused.
final class DurationFieldBox: NSView {
    let field = NSTextField()
    var focused = false { didSet { needsDisplay = true } }

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered])
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
        field.alignment = .center
        field.setAccessibilityLabel(placeholder)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = focused ? 2 : 0
        }
    }
}

/// A small panel under the status item for typing a Stay awake length in
/// days, hours and minutes. Enter submits, Esc or clicking away closes it, and
/// an invalid entry shakes the panel and stays open.
final class DurationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onClose: (() -> Void)?
    var onFocusChange: (() -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if ok { onFocusChange?() }
        return ok
    }
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
    private var boxes: [DurationFieldBox] = []
    private var fields: [NSTextField] { boxes.map(\.field) }
    private var onSubmit: ((TimeInterval) -> Void)?
    private var previousApp: NSRunningApplication?

    func show(below button: NSStatusBarButton, mode: Mode, onSubmit: @escaping (TimeInterval) -> Void) {
        panel?.close()
        self.onSubmit = onSubmit
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let inset = MenuMetrics.inset
        let panel = DurationPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                  backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.onClose = { [weak self] in
            guard let self = self else { return }
            self.panel = nil
            self.previousApp?.activate()
            self.previousApp = nil
        }
        panel.onFocusChange = { [weak self] in self?.syncFocus() }

        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.separatorColor.cgColor

        boxes = ["Days", "Hours", "Minutes"].map { name in
            let b = DurationFieldBox(placeholder: name)
            b.field.delegate = self
            return b
        }
        for (i, f) in fields.enumerated() { f.nextKeyView = fields[(i + 1) % fields.count] }

        let title = NSTextField(labelWithString: mode == .start ? "Stay awake for" : "Add time")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        let row = NSStackView(views: boxes)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        let hint = NSTextField(labelWithString: "Enter to \(mode == .start ? "start" : "add") \u{B7} Esc to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let column = NSStackView(views: [title, row, hint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: inset),
            column.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -inset),
            column.topAnchor.constraint(equalTo: bg.topAnchor, constant: inset),
            column.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -inset),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            bg.widthAnchor.constraint(equalToConstant: MenuMetrics.width),
        ])
        panel.contentView = bg
        let size = bg.fittingSize
        panel.setContentSize(size)
        panel.initialFirstResponder = fields[1]

        // Top-left just below the button, kept on screen.
        if let bw = button.window {
            let b = bw.frame
            var origin = NSPoint(x: b.minX, y: b.minY - size.height - 4)
            if let screen = bw.screen ?? NSScreen.main {
                origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 8)
            }
            panel.setFrameOrigin(origin)
        }
        self.panel = panel
        // Activation is kept because a nonactivating panel can't take typing while another app is
        // active; the previous app is re-activated when the panel closes.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        _ = panel.makeFirstResponder(fields[1])
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
        guard let layer = panel?.contentView?.layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "position.x")
        anim.values = [0, -4, 4, -4, 4, 0]   // 4 pt either way over 0.3 s
        anim.isAdditive = true
        anim.duration = 0.3
        layer.add(anim, forKey: "shake")
    }

    /// The box whose field is being edited gets the accent ring.
    private func syncFocus() {
        let editor = panel?.firstResponder as? NSTextView
        for b in boxes { b.focused = editor != nil && (editor?.delegate as? NSTextField) === b.field }
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
