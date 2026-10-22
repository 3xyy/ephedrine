import SwiftUI
import AppKit
import EphedrineCore

/// Settings › Shortcuts: one recorder per action, plus reset.
struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    let now: Date   // re-renders each second, so a shortcut another app took shows up

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.shortcuts.symbol, headline: "Shortcuts work from any app",
                           sentence: "Press one anywhere to run it. Click a shortcut to change it and press the new keys: Esc cancels, Delete clears it.")
            SettingsCard(symbol: "command", title: "Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { a in
                    let taken = controller.hotkeys.taken.contains(a)
                    SettingsRow(a.label,
                                subtitle: taken ? "Another app already uses this one, so it does nothing here. Pick another." : nil,
                                warning: taken) {
                        HStack(spacing: 6) {
                            ShortcutRecorder(shortcut: settings.shortcuts.shortcut(for: a),
                                             onChange: { settings.shortcuts.set($0, for: a) },
                                             onRecording: { controller.hotkeys.setSuspended($0) })
                                .frame(width: 150)
                            Button {
                                settings.shortcuts.set(nil, for: a)
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .opacity(settings.shortcuts.shortcut(for: a) == nil ? 0 : 1)
                            .disabled(settings.shortcuts.shortcut(for: a) == nil)
                            .help("Clear this shortcut")
                            .accessibilityLabel("Clear the shortcut for \(a.label)")
                        }
                    }
                }
                SettingsActionBar(note: "A shortcut needs two of ⌃ ⌥ ⌘ (or an F key on its own), so it never takes a key other apps use.") {
                    Button("Reset to defaults") { settings.shortcuts.reset() }
                        .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }
}

/// A button that shows a shortcut and records a new one when clicked.
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyShortcut?
    let onChange: (KeyShortcut?) -> Void
    let onRecording: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let b = ShortcutRecorderButton()
        update(b)
        return b
    }
    func updateNSView(_ b: ShortcutRecorderButton, context: Context) { update(b) }
    private func update(_ b: ShortcutRecorderButton) {
        b.onChange = onChange
        b.onRecording = onRecording
        if b.shortcut != shortcut { b.shortcut = shortcut }
    }
}

/// Click (or Space) to record: the next key press with its modifiers becomes
/// the shortcut. Esc cancels, Delete clears. A combination that isn't allowed
/// (shortcutAllowed) beeps and says what's missing. Global shortcuts are
/// suspended while it records, so pressing one records it instead of running it.
final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyShortcut? { didSet { refreshTitle() } }
    var onChange: ((KeyShortcut?) -> Void)?
    var onRecording: ((Bool) -> Void)?
    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            refreshTitle()
            onRecording?(recording)
        }
    }
    private var hint: String?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() {
        if recording { recording = false } else { recording = true; window?.makeFirstResponder(self) }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { recording = false }   // the window closed mid-recording
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with e: NSEvent) {
        guard recording else { return super.keyDown(with: e) }
        record(e)
    }

    /// ⌘ combinations arrive here, not in keyDown.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard recording, e.type == .keyDown else { return super.performKeyEquivalent(with: e) }
        record(e)
        return true
    }

    private func record(_ e: NSEvent) {
        let code = UInt32(e.keyCode)
        let mods = carbonModifiers(e.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if code == 53 && mods == 0 { recording = false; return }                         // Esc: cancel
        if (code == 51 || code == 117) && mods == 0 { onChange?(nil); recording = false; return }   // Delete: clear
        guard shortcutAllowed(keyCode: code, modifiers: mods) else {
            NSSound.beep()
            hint = "Add two of ⌃ ⌥ ⌘"
            refreshTitle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.hint = nil; self?.refreshTitle() }
            return
        }
        onChange?(KeyShortcut(keyCode: code, modifiers: mods))
        recording = false
    }

    private func refreshTitle() {
        if recording { title = hint ?? "Press keys…" } else { title = shortcut?.display ?? "Record shortcut" }
        setAccessibilityLabel(recording ? "Recording a shortcut" : "Shortcut: \(shortcut?.display ?? "none"). Click to change.")
    }
}
