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

private let functionKeyIndex: [UInt32: UInt32] = [
    122: 0, 120: 1, 99: 2, 118: 3, 96: 4, 97: 5, 98: 6, 100: 7, 101: 8, 109: 9,
    103: 10, 111: 11, 105: 12, 107: 13, 113: 14, 106: 15, 64: 16, 79: 17, 80: 18, 90: 19,
]

/// The key a menu item needs for a shortcut's key (AppKit's characters: "e",
/// " ", NSF5FunctionKey…). While a menu is open macOS holds hotkey presses until
/// it closes, so the open menu carries each shortcut as a hidden item. nil for
/// a key it can't name. US layout, like keyName.
public func menuKeyEquivalent(_ keyCode: UInt32) -> String? {
    func scalar(_ v: UInt32) -> String? { UnicodeScalar(v).map { String($0) } }
    if let i = functionKeyIndex[keyCode] { return scalar(0xF704 + i) }
    switch keyCode {
    case 49: return " "
    case 36: return "\r"
    case 48: return "\t"
    case 51: return scalar(0x08)
    case 117: return scalar(0xF728)
    case 123: return scalar(0xF702)
    case 124: return scalar(0xF703)
    case 125: return scalar(0xF701)
    case 126: return scalar(0xF700)
    case 115: return scalar(0xF729)
    case 119: return scalar(0xF72B)
    case 116: return scalar(0xF72C)
    case 121: return scalar(0xF72D)
    default:
        guard let name = keyNames[keyCode], name.count == 1 else { return nil }
        return name.lowercased()
    }
}

/// A shortcut press macOS held back while the menu was open and handed over
/// after it closed: drop it, or each extra press reopens the menu (2026-10-22).
/// `openedAt`/`closedAt` are uptimes; a menu open right now has closedAt < openedAt.
public func pressedWhileMenuWasOpen(_ at: TimeInterval, openedAt: TimeInterval?, closedAt: TimeInterval?) -> Bool {
    guard let o = openedAt else { return false }
    guard let c = closedAt, c >= o else { return at >= o }
    return at >= o && at <= c
}
