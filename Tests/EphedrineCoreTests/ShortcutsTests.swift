import Testing
import Foundation
@testable import EphedrineCore

private let ctrlOptCmd = KeyShortcut.control | KeyShortcut.option | KeyShortcut.command

@Test func theMenuAndImLeavingHaveShortcutsOutOfTheBox() {
    let b = ShortcutBindings()
    #expect(b.shortcut(for: .openMenu) == KeyShortcut(keyCode: 14, modifiers: ctrlOptCmd))   // ⌃⌥⌘E
    #expect(b.shortcut(for: .leaving) == KeyShortcut(keyCode: 37, modifiers: ctrlOptCmd))    // ⌃⌥⌘L
    #expect(b.shortcut(for: .stayAwake) == nil)
    #expect(b.shortcut(for: .keepAwake) == nil)
    #expect(b.shortcut(for: .settings) == nil)
}

@Test func shortcutsReadTheWayMacMenusWriteThem() {
    #expect(KeyShortcut(keyCode: 14, modifiers: ctrlOptCmd).display == "⌃⌥⌘E")
    #expect(KeyShortcut(keyCode: 49, modifiers: ctrlOptCmd | KeyShortcut.shift).display == "⌃⌥⇧⌘Space")
    #expect(KeyShortcut(keyCode: 96, modifiers: 0).display == "F5")
    #expect(KeyShortcut(keyCode: 126, modifiers: KeyShortcut.control | KeyShortcut.option).display == "⌃⌥↑")
    #expect(KeyShortcut(keyCode: 200, modifiers: KeyShortcut.option | KeyShortcut.command).display == "⌥⌘Key 200")
}

@Test func aShortcutCantTakeAKeyOtherAppsNeed() {
    let cmd = KeyShortcut.command, opt = KeyShortcut.option, ctrl = KeyShortcut.control, shift = KeyShortcut.shift
    #expect(!shortcutAllowed(keyCode: 8, modifiers: cmd))                  // ⌘C: copy, everywhere
    #expect(!shortcutAllowed(keyCode: 8, modifiers: ctrl))                 // ⌃C: a terminal's interrupt
    #expect(!shortcutAllowed(keyCode: 40, modifiers: cmd | shift))         // ⌘⇧K: apps use these
    #expect(!shortcutAllowed(keyCode: 0, modifiers: 0))                    // plain typing
    #expect(shortcutAllowed(keyCode: 8, modifiers: opt | cmd))
    #expect(shortcutAllowed(keyCode: 40, modifiers: ctrl | opt))
    #expect(shortcutAllowed(keyCode: 96, modifiers: 0))                    // F5 alone
    #expect(shortcutAllowed(keyCode: 96, modifiers: shift))
    #expect(!shortcutAllowed(keyCode: 55, modifiers: ctrl | opt | cmd))    // a modifier key by itself
    #expect(!shortcutAllowed(keyCode: 53, modifiers: ctrl | opt | cmd))    // Esc cancels recording
}

@Test func givingAShortcutToOneActionTakesItFromAnother() {
    var b = ShortcutBindings()
    let l = KeyShortcut(keyCode: 37, modifiers: ctrlOptCmd)
    b.set(l, for: .stayAwake)
    #expect(b.shortcut(for: .stayAwake) == l)
    #expect(b.shortcut(for: .leaving) == nil)
    b.set(nil, for: .openMenu)
    #expect(b.shortcut(for: .openMenu) == nil)
    b.reset()
    #expect(b == ShortcutBindings())
}

@Test func aClearedDefaultStaysClearedAfterARelaunch() throws {
    var b = ShortcutBindings()
    b.set(nil, for: .leaving)
    b.set(KeyShortcut(keyCode: 1, modifiers: ctrlOptCmd), for: .settings)
    let again = try JSONDecoder().decode(ShortcutBindings.self, from: JSONEncoder().encode(b))
    #expect(again.shortcut(for: .leaving) == nil)
    #expect(again.shortcut(for: .settings) == KeyShortcut(keyCode: 1, modifiers: ctrlOptCmd))
    #expect(again.shortcut(for: .openMenu) == KeyShortcut(keyCode: 14, modifiers: ctrlOptCmd))
}

@Test func shortcutsAreSavedWithTheSettings() {
    let name = "ephedrine-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    let s = AppSettings(defaults: d)
    #expect(s.shortcuts == ShortcutBindings())
    s.shortcuts.set(nil, for: .openMenu)
    #expect(AppSettings(defaults: d).shortcuts.shortcut(for: .openMenu) == nil)
}
