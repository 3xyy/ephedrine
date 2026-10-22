import AppKit
import Carbon.HIToolbox
import EphedrineCore

/// Registers the global shortcuts (Settings › Shortcuts) with the system
/// hotkey API, which needs no Accessibility permission, and reports presses.
/// A shortcut another app already registered can't be taken: it goes in
/// `taken` so Settings can say so. Main thread only.
final class HotkeyCenter {
    /// The action and when it was pressed (seconds of uptime, as ProcessInfo.systemUptime).
    var onPress: ((ShortcutAction, TimeInterval) -> Void)?
    private(set) var taken: Set<ShortcutAction> = []
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var current = ShortcutBindings()
    private var suspendedBy: Set<String> = []
    private var lastLogged = ""
    private static let signature: OSType = 0x45504844   // 'EPHD'

    /// Register `bindings`, replacing what was registered before.
    func apply(_ bindings: ShortcutBindings) {
        current = bindings
        if suspendedBy.isEmpty { registerAll() }
    }

    /// None fire while Settings records one (pressing it records it) or while
    /// the menu is open (macOS would hold the press until the menu closes; the
    /// menu carries them as key equivalents instead).
    func setSuspended(_ on: Bool, by reason: String) {
        let was = suspendedBy.isEmpty
        if on { suspendedBy.insert(reason) } else { suspendedBy.remove(reason) }
        if was && !suspendedBy.isEmpty { unregisterAll() }
        if !was && suspendedBy.isEmpty { registerAll() }
    }

    private func registerAll() {
        unregisterAll()
        installHandlerOnce()
        var on: [String] = []
        var failed: Set<ShortcutAction> = []
        for (i, a) in ShortcutAction.allCases.enumerated() {
            guard let s = current.shortcut(for: a) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(i))
            let st = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref {
                refs.append(ref)
                on.append("\(s.display) \(a.rawValue)")
            } else {
                failed.insert(a)
                logLine("shortcut \(s.display) for \(a.rawValue) couldn't be registered (\(st)), another app may use it")
            }
        }
        taken = failed
        // They're registered again each time the menu closes: log a change only.
        let line = on.isEmpty ? "shortcuts: none" : "shortcuts: " + on.joined(separator: ", ")
        if line != lastLogged { lastLogged = line; logLine(line) }
    }

    private func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
    }

    private func installHandlerOnce() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard st == noErr, id.signature == HotkeyCenter.signature,
                  Int(id.id) < ShortcutAction.allCases.count else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let action = ShortcutAction.allCases[Int(id.id)]
            let at = GetEventTime(event)   // seconds since startup, as systemUptime
            DispatchQueue.main.async { center.onPress?(action, at) }
            return noErr
        }, 1, &spec, me, &handler)
    }
}

/// The hotkey API's modifiers as AppKit flags (for menu key equivalents).
func cocoaModifiers(_ m: UInt32) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if m & KeyShortcut.command != 0 { f.insert(.command) }
    if m & KeyShortcut.shift != 0 { f.insert(.shift) }
    if m & KeyShortcut.option != 0 { f.insert(.option) }
    if m & KeyShortcut.control != 0 { f.insert(.control) }
    return f
}

/// AppKit modifier flags in the hotkey API's terms.
func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= KeyShortcut.command }
    if flags.contains(.shift) { m |= KeyShortcut.shift }
    if flags.contains(.option) { m |= KeyShortcut.option }
    if flags.contains(.control) { m |= KeyShortcut.control }
    return m
}
