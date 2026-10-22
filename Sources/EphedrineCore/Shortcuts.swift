import Foundation

// ── Keyboard shortcuts ──
//
// Global shortcuts for the menu's main actions, registered with the system
// hotkey API (no Accessibility permission needed). Changed in Settings ›
// Shortcuts. The app turns a press into the action (HotkeyCenter).

/// A key and modifiers, in the system hotkey API's terms: a virtual key code
/// and Carbon modifier flags.
public struct KeyShortcut: Codable, Equatable, Hashable {
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    public let keyCode: UInt32
    public let modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// "⌃⌥⌘E", modifiers in the order Mac menus show them.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }
}

/// What a shortcut can do: the menu's main actions.
public enum ShortcutAction: String, CaseIterable, Codable {
    case openMenu, leaving, stayAwake, keepAwake, settings

    public var label: String {
        switch self {
        case .openMenu:  return "Open the Ephedrine menu"
        case .leaving:   return "I'm leaving, or I'm back"
        case .stayAwake: return "Stay awake until I turn it off, or turn it off"
        case .keepAwake: return "Turn keeping awake for Claude on or off"
        case .settings:  return "Open Settings"
        }
    }

    public var defaultShortcut: KeyShortcut? {
        let m = KeyShortcut.control | KeyShortcut.option | KeyShortcut.command
        switch self {
        case .openMenu: return KeyShortcut(keyCode: 14, modifiers: m)   // ⌃⌥⌘E
        case .leaving:  return KeyShortcut(keyCode: 37, modifiers: m)   // ⌃⌥⌘L
        default:        return nil
        }
    }
}

/// Each action's shortcut: its default until changed, nil once cleared.
public struct ShortcutBindings: Codable, Equatable {
    private var changed: [String: KeyShortcut?] = [:]
    public init() {}

    public func shortcut(for a: ShortcutAction) -> KeyShortcut? {
        if let c = changed[a.rawValue] { return c }
        return a.defaultShortcut
    }

    /// Give `a` this shortcut, or none. An action that had the same one loses it.
    public mutating func set(_ s: KeyShortcut?, for a: ShortcutAction) {
        if let s {
            for other in ShortcutAction.allCases where other != a && shortcut(for: other) == s {
                changed[other.rawValue] = .some(nil)
            }
        }
        changed[a.rawValue] = .some(s)
    }

    public mutating func reset() { changed = [:] }
}

private let functionKeys: [UInt32: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
    103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
]

private let keyNames: [UInt32: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
    14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
    26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab",
    49: "Space", 50: "`", 51: "Delete", 53: "Esc", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
    119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
]

/// A key's name on a US keyboard ("E", "Space", "F5").
public func keyName(_ keyCode: UInt32) -> String {
    functionKeys[keyCode] ?? keyNames[keyCode] ?? "Key \(keyCode)"
}

/// Whether a key combination may be a global shortcut. A function key may go
/// alone; anything else needs two of ⌃ ⌥ ⌘, since a shortcut takes its keys
/// from every app (⌘C, a terminal's ⌃C, ⌘⇧K). Not a modifier key by itself,
/// and not Esc, which cancels recording.
public func shortcutAllowed(keyCode: UInt32, modifiers: UInt32) -> Bool {
    if (54...63).contains(keyCode) || keyCode == 53 { return false }
    if functionKeys[keyCode] != nil { return true }
    let held = [KeyShortcut.control, KeyShortcut.option, KeyShortcut.command].filter { modifiers & $0 != 0 }.count
    return held >= 2
}
