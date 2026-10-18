import Foundation

/// Apps whose App Nap Ephedrine can switch off: terminals and editors (the same
/// ones "I'm leaving" never pauses), the Claude app and other apps agents run
/// in, and the Chromium browsers. Core can't see the app target, so the ids are
/// listed here.
public let appNapAgentApps: [String] = [
    // terminals
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.cmuxterm.app", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
    // editors with built-in terminals
    "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",   // Cursor
    "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity", "com.google.antigravity-ide",
    "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.vscodium", "com.google.android.studio",
    // Claude app and other apps agents run in
    "com.anthropic.claudefordesktop", "com.openai.codex", "com.conductor.app", "com.t3tools.t3code",
] + chromiumBrowsers

/// A bundle id that is safe to hand to the preferences calls: ASCII letters,
/// digits, `.`, `-` and `_`, starting with a letter or digit, and not the
/// global domain or one of CFPreferences' own names (kCFPreferencesAnyApplication...).
public func appNapRestorable(_ bundleID: String) -> Bool {
    guard bundleID != "NSGlobalDomain", !bundleID.hasPrefix("kCFPreferences"), let first = bundleID.unicodeScalars.first,
          first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
    return bundleID.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
}

/// What an app's `NSAppSleepDisabled` was before Ephedrine wrote it.
public enum PriorValue: Codable, Equatable { case absent, value(Bool) }

/// The values to put back, saved before any YES is written.
public struct AppNapJournal: Codable, Equatable {
    public var prior: [String: PriorValue]
    public init(prior: [String: PriorValue]) { self.prior = prior }

    /// The ids to write YES to: restorable and not already YES. A journaled id
    /// not at YES is included again (an earlier write may have failed) and keeps
    /// its first prior value; a new one records its value (nil = no key). Sorted.
    public mutating func plan(current: [String: Bool?]) -> [String] {
        var out: [String] = []
        for id in current.keys.sorted() where appNapRestorable(id) {
            let now = current[id] ?? nil
            if now == true { continue }
            if prior[id] == nil { prior[id] = now.map { .value($0) } ?? .absent }
            out.append(id)
        }
        return out
    }

    /// The entries to put back, sorted by id. Not every journaled id: a corrupt
    /// or hand-edited file could name NSGlobalDomain or a path, which are never
    /// written (see `unrestorable`). An id no longer in appNapAgentApps still counts.
    public func restorePlan() -> [(String, PriorValue)] {
        prior.sorted { $0.key < $1.key }.filter { appNapRestorable($0.key) }.map { ($0.key, $0.value) }
    }

    /// Journaled ids that must be dropped without a write, sorted.
    public var unrestorable: [String] { prior.keys.filter { !appNapRestorable($0) }.sorted() }
}
