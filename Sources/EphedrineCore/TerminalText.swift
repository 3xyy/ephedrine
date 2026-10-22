import Foundation

// Classifiers for the visible text of a Terminal tab. Pure functions so the
// Claude-Code-UI heuristics can be unit-tested against captured screen text.
// Strings here track Claude Code's TUI (checked against 2.1.284).

private func tail(_ text: String, _ n: Int) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
}

/// True if the tail looks like the Claude Code TUI (input box / footer hint).
/// Used to avoid typing "continue" into unrelated shells whose output merely
/// mentions a connection error (npm, servers, logs…). With a permission mode
/// on, the footer shows e.g. "auto mode on" instead of "? for shortcuts".
public func claudeUIVisible(_ text: String) -> Bool {
    let t = tail(text, 40)
    let markers = ["? for shortcuts", "│ >", "╭─", "auto mode on", "accept edits on", "plan mode on"]
    return markers.contains { t.contains($0) }
}

/// Numbered choices of an on-screen select menu ("❯ 1. Yes" / "  2. No"),
/// from the tail. Empty unless one line carries the selection cursor, so a
/// numbered list in Claude's prose doesn't count as a menu.
public func menuOptions(_ text: String) -> [(number: String, label: String)] {
    var opts: [(String, String)] = []
    var hasCursor = false
    for line in tail(text, 20).split(separator: "\n") {
        guard let g = regexGroups("^\\s*([❯›▸▶]?)\\s*([1-9])[.)]\\s+(\\S.*?)\\s*$", String(line)) else { continue }
        if !g[1].isEmpty { hasCursor = true }
        opts.append((g[2], g[3]))
    }
    return hasCursor ? opts : []
}

public func menuVisible(_ text: String) -> Bool { !menuOptions(text).isEmpty }

/// A line holding a prompt that was submitted (or is being typed): "❯ continue",
/// "> continue", "│ > text │". An empty input box ("❯", "│ >   │") doesn't count.
private func isPromptWithText(_ line: String) -> Bool {
    let s = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│")))
    guard let first = s.first, first == "❯" || first == ">" else { return false }
    return !s.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty
}

/// True if the screen shows a Claude API/connection error that is still
/// unanswered: it's the last thing Claude said (no newer ⏺ message), no prompt
/// was submitted after it (so one "continue" per error, never a pile of them),
/// Claude isn't working, no menu is open (typing "continue⏎" there would pick
/// an option), and the Claude Code UI is on screen. Distance from the bottom
/// doesn't matter: panels or notices can sit between the error and the prompt.
/// "Your computer went to sleep" is excluded, since that's the lid closing, not an outage.
public func claudeErrorVisible(_ text: String) -> Bool {
    claudeErrorStatus(text) == .unanswered
}

public enum ClaudeErrorStatus: Equatable {
    case none                 // no API/connection error near the bottom
    case unanswered           // eligible for an auto "continue"
    case skipped(String)      // an error is showing but we won't answer it, and why (for the log)
}

/// A real Claude Code error is its own message at the left edge: "⏺ API
/// Error: …" (older versions: "API Error: …", "Unable to connect to API").
/// Matching the words anywhere would also catch Claude's own prose about an
/// error, or an error pasted into a prompt (indented), and type "continue"
/// into a session that's fine. `line` is lowercased.
private func isAPIErrorLine(_ line: String) -> Bool {
    var s = Substring(line)
    if s.hasPrefix("⏺ ") || s.hasPrefix("● ") { s = s.dropFirst(2) }
    return s.hasPrefix("api error") || s.hasPrefix("unable to connect to api")
}

/// Same rules as claudeErrorVisible, but says which one blocked the answer.
public func claudeErrorStatus(_ text: String) -> ClaudeErrorStatus {
    // The whole visible screen (a Terminal tab is rarely taller than 60 rows):
    // panels, notices or a recap below the error must not push it out of view.
    let lines = tail(text, 60).lowercased().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let i = lines.lastIndex(where: isAPIErrorLine) else { return .none }
    let below = "; below it: " + lineShapes(Array(lines[(i + 1)...]))
    if lines[i].contains("went to sleep") { return .skipped("“went to sleep” message, not an outage") }
    if let p = lines[(i + 1)...].first(where: isPromptWithText) {
        return .skipped("already answered: \(p.trimmingCharacters(in: .whitespaces).prefix(60))" + below)
    }
    // Unanswered means the error is the last thing Claude said: no newer
    // message (⏺) below it, however far up it is.
    if lineShapes(Array(lines[(i + 1)...])).contains("⏺") { return .skipped("Claude said more after it" + below) }
    guard claudeUIVisible(text) else { return .skipped("Claude Code's input box isn't on screen" + below) }
    if menuVisible(text) { return .skipped("a menu is open" + below) }
    if claudeWorkingVisible(text) { return .skipped("Claude looks busy" + below) }
    return .unanswered
}

/// Diagnostics: one symbol per line, no text. _ blank, ─ rule, ❯ empty
/// prompt, P prompt with text, ⏺ message, ⎿ tool output, ※ recap, ✻ spinner
/// or "done" line, x anything else. Shows the screen layout in the log
/// without copying what's on it.
public func lineShapes(_ lines: [String]) -> String {
    String(lines.map { raw -> Character in
        let l = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│")))
        guard let f = l.first else { return "_" }
        if l.hasPrefix("──") || f == "╭" || f == "╰" { return "─" }
        if isPromptWithText(raw) { return "P" }
        if f == "❯" || f == ">" { return "❯" }
        if f == "⏺" || f == "●" { return "⏺" }
        if f == "⎿" { return "⎿" }
        if f == "※" { return "※" }
        if "✻✶✳✢✽·*".contains(f) { return "✻" }
        return "x"
    })
}

/// True if the visible tail shows Claude Code actively working, including a
/// background/dynamic workflow running after the main turn ended (which the
/// Stop-hook-based marker can't see). Claude Code 2.1.x dropped "esc to
/// interrupt" from its spinner, which now reads "✻ Crunching… (12s · ↓ 1.2k
/// tokens)" with a random (configurable) verb, so match the shape: spinner
/// glyph, one word, ellipsis. The finished line ("✻ Crunched for 3m") has no ellipsis.
public func claudeWorkingVisible(_ text: String) -> Bool {
    let t = tail(text, 15)
    let low = t.lowercased()
    if low.contains("esc to interrupt") || low.contains("enter to interrupt")
        || low.contains("dynamic workflow") || low.contains("workflow to finish")
        || low.contains("running in the background") { return true }
    let lines = t.split(separator: "\n").map(String.init)
    // "✻ Waiting for 2 background agents to finish" ends a main turn while its
    // agents still run. It's a transcript line that stays on screen after
    // they're done, so it counts only while nothing Claude printed follows it.
    if let newest = lines.last(where: { l in
        l.trimmingCharacters(in: .whitespaces).first.map { "✻✶✳✢✽·*⏺●".contains($0) } ?? false
    }), backgroundAgentsLine.firstMatch(in: newest, range: NSRange(newest.startIndex..., in: newest)) != nil {
        return true
    }
    return lines.contains { s in
        spinnerLine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

private let spinnerLine = try! NSRegularExpression(pattern: "^\\s*[^\\s\\w]\\s+[A-Z][\\w'-]*…(\\s|$)")   // case-sensitive
private let backgroundAgentsLine = try! NSRegularExpression(pattern: "^\\s*[^\\s\\w]\\s+Waiting for \\d+ background agents? to finish")

/// True if Claude Code is in its own API retry loop ("… · Retrying in 14s ·
/// attempt 9/10"). That phase runs ~3 min between the error lines it prints,
/// so an auto-continue episode must not count it as recovered.
public func claudeRetryingVisible(_ text: String) -> Bool {
    regexGroups("retrying in \\S+.*· attempt \\d+/\\d+", tail(text, 15).lowercased()) != nil
}

/// True if Claude Code shows a usage-limit wall: "You've hit your session limit
/// · resets 3am (…)", and also weekly / Opus / Sonnet / Fable limits, and the
/// older "usage limit reached" wording.
public func usageLimitVisible(_ text: String) -> Bool {
    let t = tail(text, 25).lowercased()
    guard t.contains("reset") else { return false }
    return regexGroups("(hit|reached) your [a-z' ]{0,24}limit", t) != nil || t.contains("usage limit reached")
}

/// True if Claude Code is itself waiting to resume ("Usage limit reached ·
/// continuing automatically at 3am · esc to cancel"), so there's nothing to type.
public func claudeAutoResumeVisible(_ text: String) -> Bool {
    tail(text, 25).lowercased().contains("continuing automatically")
}

public enum LimitChoice: Equatable {
    case claudeAutoContinue(String)   // "Wait here, then continue automatically…": Claude resumes itself
    case waitForReset(String)         // "Stop and wait for limit to reset": we type continue later
    public var number: String {
        switch self { case .claudeAutoContinue(let n), .waitForReset(let n): return n }
    }
}

/// Which option of Claude Code's usage-limit menu to pick. Picks by label,
/// never by position: the menu's order varies, and other options spend money
/// ("Switch to usage credits", "Add funds…") or open an upgrade page.
public func limitMenuChoice(_ text: String) -> LimitChoice? {
    let opts = menuOptions(text).map { ($0.number, $0.label.lowercased()) }
    if let o = opts.first(where: { $0.1.hasPrefix("wait") && $0.1.contains("continue automatically") }) {
        return .claudeAutoContinue(o.0)
    }
    if let o = opts.first(where: { $0.1.contains("wait for limit to reset") || $0.1.contains("let usage reset") }) {
        return .waitForReset(o.0)
    }
    return nil
}

/// Parse the LAST reset time in the tail ("resets 3:20am (America/Los_Angeles)",
/// "resets 3am", "continuing automatically at 3am") into the next such moment
/// after `now`. Dates further out ("resets Oct 5, 12am") deliberately don't
/// match: those are multi-day waits.
public func parseResetTime(_ text: String, now: Date = Date()) -> Date? {
    let t = tail(text, 25)
    guard let re = try? NSRegularExpression(
            pattern: "(?:reset[s]?(?: at)?|automatically at)\\s+([0-9]{1,2})(?::([0-9]{2}))?\\s*([ap])\\s*m",
            options: [.caseInsensitive]),
          let m = re.matches(in: t, range: NSRange(t.startIndex..., in: t)).last,
          let hr = Range(m.range(at: 1), in: t), let ar = Range(m.range(at: 3), in: t),
          let h12 = Int(t[hr]) else { return nil }
    let mins = Range(m.range(at: 2), in: t).flatMap { Int(t[$0]) } ?? 0
    var hour = h12 % 12
    if t[ar].lowercased() == "p" { hour += 12 }
    // Use the first parenthesized token after the time that names a real
    // zone; other parens on screen are often something else ("(esc)").
    var tz = TimeZone.current
    let after = String(t[hr.upperBound...])
    if let zre = try? NSRegularExpression(pattern: "\\(([A-Za-z_]+(?:/[A-Za-z_+-]+)*)\\)") {
        for zm in zre.matches(in: after, range: NSRange(after.startIndex..., in: after)) {
            if let r = Range(zm.range(at: 1), in: after), let z = TimeZone(identifier: String(after[r])) {
                tz = z; break
            }
        }
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let n = cal.dateComponents([.year, .month, .day], from: now)
    var c = DateComponents()
    c.year = n.year; c.month = n.month; c.day = n.day; c.hour = hour; c.minute = mins
    guard var target = cal.date(from: c) else { return nil }
    if target <= now { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
    return target
}

/// Diagnostics: the last `count` non-empty lines above Claude Code's input
/// prompt (where the spinner / status sits), skipping box-drawing rules and
/// truncated to 100 chars. Empty if no prompt line is on screen.
public func statusLinesAbovePrompt(_ text: String, count: Int = 3) -> [String] {
    let lines = tail(text, 40).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let trimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│"))
    guard let p = lines.lastIndex(where: { l in
        let s = l.trimmingCharacters(in: trimSet)
        return s.hasPrefix("❯") || s.hasPrefix(">")
    }) else { return [] }
    let above = lines[..<p].map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { l in !l.isEmpty && !l.hasPrefix("──") && !l.hasPrefix("╭") && !l.hasPrefix("╰") }
    return above.suffix(count).map { String($0.prefix(100)) }
}

/// The read's error when Terminal isn't running, worded like osascript's.
public let terminalNotRunningError = "Terminal isn't running (-600)"

/// Read Terminal only while it runs: any Apple event to Terminal launches it,
/// so the scan every 9s reopened Terminal seconds after the owner quit it.
public func readTerminalIfRunning<T>(_ running: Bool, _ read: () -> (tabs: [T], err: String)) -> (tabs: [T], err: String) {
    guard running else { return ([], terminalNotRunningError) }
    return read()
}

/// Settings → About wording for the last Terminal read. `tabs` -1 = no scan
/// yet; `error` is osascript's stderr (-1743 = Automation not allowed,
/// -600 = Terminal not running).
public func terminalControlStatus(tabs: Int, error: String) -> String {
    if tabs < 0 { return "Not checked yet" }
    if tabs > 0 { return "OK (\(tabs) tab\(tabs == 1 ? "" : "s"))" }
    if error.contains("-1743") {
        return "Not allowed. Turn on Ephedrine → Terminal in System Settings → Privacy & Security → Automation"
    }
    if error.contains("-600") { return "OK, Terminal isn't open" }
    if error.isEmpty { return "OK, no Terminal windows open" }
    return "Couldn't read Terminal (\(error.prefix(80)))"
}
