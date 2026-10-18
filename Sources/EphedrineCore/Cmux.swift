import Foundation

// ── cmux, the Ghostty-based terminal, as a second place Claude Code runs ──
// The app drives cmux's CLI (Ephedrine/Cmux.swift); these are the pure parts.
// Formats are cmux 0.65.2's, pinned from its CLI and socket source and from a
// live access-denied run (task 12 report).

/// One terminal surface: a tab inside a cmux pane.
public struct CmuxSurface: Equatable {
    public let id: String      // the surface's UUID, stable while it's open
    public let label: String   // "workspace › tab title", for the log
    public init(id: String, label: String) { self.id = id; self.label = label }
}

/// Every window's tree as JSON, with UUIDs. The default ids are refs like
/// "surface:3", which renumber as tabs open and close, so never type by them.
public let cmuxListArgs = ["--json", "--id-format", "uuids", "tree", "--all"]

public func cmuxReadArgs(_ id: String) -> [String] { ["read-screen", "--surface", id] }

/// Without force, cmux itself refuses to type over a half-written prompt or
/// into an open question. The text goes after "--" so it can't read as a flag.
public func cmuxSendArgs(_ id: String, _ text: String, force: Bool) -> [String] {
    ["send", "--surface", id] + (force ? ["--force"] : []) + ["--", text]
}

public func cmuxEnterArgs(_ id: String, force: Bool) -> [String] {
    ["send-key", "--surface", id] + (force ? ["--force"] : []) + ["enter"]
}

/// The bottom of a pane, whatever the owner has scrolled to: with --lines,
/// read-screen takes the last N lines of the whole buffer (scrollback plus the
/// live screen). cmux captures the whole buffer either way, so a roomy N costs
/// nothing more and leaves space for blank rows under the cursor.
public func cmuxLiveTailArgs(_ id: String) -> [String] { ["read-screen", "--surface", id, "--lines", "100"] }

/// What a surface's prompt holds on its live screen (cmux reads the bottom of
/// the terminal for this, not the part the owner may have scrolled to). nil
/// unless `id` is a UUID: without a surface, cmux answers for the focused one.
public func cmuxInputStateArgs(_ id: String) -> [String]? {
    guard UUID(uuidString: id) != nil,
          let data = try? JSONSerialization.data(withJSONObject: ["surface_id": id]),
          let params = String(data: data, encoding: .utf8) else { return nil }
    return ["rpc", "surface.input_state", params]
}

/// `cmux rpc surface.input_state`, cmux 0.65.2: `state` is "empty", "draft",
/// "dialog" (a question, permission ask or menu with its key hint) or "unknown"
/// (no agent prompt on screen); `agent` says cmux's hooks report an agent there.
public struct CmuxInputState: Equatable {
    public enum Prompt: Equatable { case empty, draft, dialog, unknown }
    public let prompt: Prompt
    public let agent: Bool
    public let terminal: Bool
    public init(prompt: Prompt, agent: Bool, terminal: Bool) {
        self.prompt = prompt; self.agent = agent; self.terminal = terminal
    }
}

/// nil when the output isn't an input_state result (an error, or garbage).
public func parseCmuxInputState(_ output: String) -> CmuxInputState? {
    guard let data = output.data(using: .utf8),
          let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let state = d["state"] as? String else { return nil }
    let prompt: CmuxInputState.Prompt
    switch state {
    case "empty": prompt = .empty
    case "draft": prompt = .draft
    case "dialog": prompt = .dialog
    default: prompt = .unknown
    }
    return CmuxInputState(prompt: prompt, agent: d["agent"] as? Bool ?? false, terminal: d["terminal"] as? Bool ?? false)
}

public enum CmuxTypePurpose: Equatable {
    case continuePrompt    // "continue" after an API error or a usage-limit reset
    case limitMenuAnswer   // a number picking the "wait" option of Claude Code's limit menu
}

public enum CmuxTypeDecision: Equatable { case send, force, skip(String) }

/// What a send is answering, checked once more on the pane's live tail
/// (cmuxLiveTailShows) right before typing.
public enum CmuxLiveTrigger: Equatable {
    case apiError                 // "continue" for an unanswered API error
    case limitMenu(LimitChoice)   // this "wait" option of Claude Code's usage-limit menu
    case limitReset               // "continue" at a plain prompt once a usage limit has reset

    public var purpose: CmuxTypePurpose {
        if case .limitMenu = self { return .limitMenuAnswer }
        return .continuePrompt
    }
    /// The log's reason when the live tail doesn't show it.
    public var missing: String {
        switch self {
        case .apiError: return "the live screen doesn't show an unanswered API error"
        case .limitMenu: return "menu on screen isn't the usage-limit menu"
        case .limitReset: return "the live screen isn't the usage limit at a plain prompt"
        }
    }
}

/// A numbered option line of a select menu, box borders allowed ("│ ❯ 1. Yes │").
private func liveOption(_ raw: String) -> (cursor: Bool, number: String, label: String)? {
    let s = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃")))
    guard let g = regexGroups("^([❯›▸▶]?)\\s*([1-9])[.)]\\s+(\\S.*?)$", s) else { return nil }
    return (!g[1].isEmpty, g[2], g[3])
}

/// Whether the pane's live tail (the bottom of its buffer, from
/// cmuxLiveTailArgs) still shows what the scan saw. Trailing blank rows are
/// dropped first. A menu answer needs the usage-limit text, then a single
/// menu below it (one selection cursor, no repeated numbers, at most a footer
/// after it) offering the chosen option; a permission prompt or any other
/// question at the bottom fails that. "continue" needs no menu or question
/// at the bottom at all.
public func cmuxLiveTailShows(_ trigger: CmuxLiveTrigger, in tail: String) -> Bool {
    var lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let blank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    while let last = lines.last, blank(last) { lines.removeLast() }
    lines = Array(lines.suffix(60))
    let text = lines.joined(separator: "\n")
    let menuOpen = lines.suffix(20).contains { liveOption($0)?.cursor == true }
    switch trigger {
    case .apiError:
        return !menuOpen && claudeErrorStatus(text) == .unanswered
    case .limitReset:
        return !menuOpen && usageLimitVisible(text) && claudeUIVisible(text) && !menuVisible(text)
            && !claudeWorkingVisible(text) && !claudeAutoResumeVisible(text)
    case .limitMenu(let choice):
        let recent = Array(lines.suffix(25))
        guard let h = recent.lastIndex(where: { usageLimitVisible($0) }) else { return false }
        let after = Array(recent[(h + 1)...])
        let opts = after.indices.compactMap { i in liveOption(after[i]).map { (i, $0) } }
        guard let lastOption = opts.last?.0,
              opts.filter({ $0.1.cursor }).count == 1,
              Set(opts.map { $0.1.number }).count == opts.count,
              after[(lastOption + 1)...].filter({ !blank($0) }).count <= 3 else { return false }
        let menu = opts.map { "\($0.1.cursor ? "❯" : " ") \($0.1.number). \($0.1.label)" }.joined(separator: "\n")
        return limitMenuChoice(menu) == choice
    }
}

/// The last word before typing into a cmux pane, from its live input state
/// read right before. "continue" goes only into an empty Claude Code prompt,
/// with cmux's own draft and dialog guard still on. A menu answer is forced
/// past that guard (which sees the menu as an open question), and only while
/// a menu or question is open. Anything else, or no answer, types nothing.
public func cmuxTypeDecision(state: CmuxInputState?, purpose: CmuxTypePurpose) -> CmuxTypeDecision {
    guard let state else { return .skip("couldn't read what its live screen shows") }
    guard state.terminal else { return .skip("it isn't a terminal") }
    guard state.agent else { return .skip("cmux doesn't report Claude Code running in it") }
    switch (purpose, state.prompt) {
    case (.continuePrompt, .empty): return .send
    case (.limitMenuAnswer, .dialog): return .force
    case (_, .draft): return .skip("someone is typing in its prompt")
    case (.continuePrompt, .dialog): return .skip("a question or menu is open")
    case (.limitMenuAnswer, .empty): return .skip("no menu is open on its live screen")
    case (_, .unknown): return .skip("no Claude Code prompt on its live screen")
    }
}

/// Terminal surfaces from `cmux --json --id-format uuids tree --all`
/// (windows › workspaces › panes › surfaces). Browser and other surfaces are
/// left out, and so is anything without a UUID. Any other shape gives none.
public func parseCmuxSurfaces(_ output: String) -> [CmuxSurface] {
    guard let data = output.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let windows = root["windows"] as? [[String: Any]] else { return [] }
    func title(_ d: [String: Any]) -> String {
        ((d["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var seen = Set<String>()
    var res: [CmuxSurface] = []
    for window in windows {
        for ws in window["workspaces"] as? [[String: Any]] ?? [] {
            for pane in ws["panes"] as? [[String: Any]] ?? [] {
                for s in pane["surfaces"] as? [[String: Any]] ?? [] {
                    guard s["type"] as? String == "terminal", let id = s["id"] as? String,
                          UUID(uuidString: id) != nil, seen.insert(id).inserted else { continue }
                    res.append(CmuxSurface(id: id, label: [title(ws), title(s)].filter { !$0.isEmpty }.joined(separator: " › ")))
                }
            }
        }
    }
    return res
}

/// What cmux's socket says to Ephedrine. `failed` carries cmux's own error
/// line for anything that isn't about access (socket off, overloaded, quitting).
public enum CmuxAccess: Equatable { case notInstalled, denied, needsPassword, badPassword, failed(String), ok }

/// The exit code the app's runner reports when the CLI couldn't be started.
public let cmuxLaunchFailed: Int32 = -1

/// The socket's answer, from one CLI run's exit code and output (stderr and
/// stdout). The error text decides, not just the exit code: the access-denied
/// line has been seen with exit 0. Only the CLI's own "Error:" lines count,
/// so a tab titled "Invalid password" in a good listing changes nothing.
/// Any other failure is `failed` with cmux's first error line.
public func cmuxAccess(exitCode: Int32, output: String) -> CmuxAccess {
    if exitCode == cmuxLaunchFailed { return .notInstalled }
    let errorLines = output.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("Error:") || $0.hasPrefix("ERROR:") }
    let errors = errorLines.joined(separator: "\n").lowercased()
    // "only processes started inside cmux can connect": Automation is on its default
    if errors.contains("access denied") || errors.contains("unable to verify client process") { return .denied }
    if errors.contains("invalid password") || errors.contains("auth_failed") { return .badPassword }
    // no password sent, or password mode is on but none is set in cmux
    if errors.contains("authentication required") || errors.contains("auth_required")
        || errors.contains("no socket password is configured") || errors.contains("auth_unconfigured") {
        return .needsPassword
    }
    if exitCode == 0 { return .ok }
    guard var line = errorLines.first else { return .failed("exit \(exitCode)") }
    while let p = ["Error:", "ERROR:"].first(where: { line.hasPrefix($0) }) {   // "Error: ERROR: …"
        line = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
    }
    return .failed(String(line.prefix(200)))
}

public let cmuxNotConnectedText =
    "Not connected: in cmux, open Settings › Automation, choose Password and set one, then enter it here"

/// The keychain's answer about the saved cmux password.
public enum CmuxSavedPassword: Equatable { case none, saved, unreadable(Int32) }

/// The cmux line in Settings › Claude Code. `access` is the last check's
/// answer (nil: not checked yet), `panes` the terminal tabs it listed.
public func cmuxStatusText(installed: Bool, running: Bool, password: CmuxSavedPassword, access: CmuxAccess?, panes: Int) -> String {
    if !installed { return "Not installed" }
    switch password {
    case .none: return cmuxNotConnectedText
    case .unreadable(let status): return "Couldn't read the saved password (OSStatus \(status))"
    case .saved: break
    }
    if !running { return "Password saved. Connects when cmux is open" }
    switch access {
    case nil: return "Checking…"
    case .notInstalled: return "Not installed"
    case .denied, .needsPassword: return cmuxNotConnectedText
    case .badPassword: return "Password not accepted"
    case .failed(let why): return "Not connected: \(why)"
    case .ok: return "Connected, \(panes) pane\(panes == 1 ? "" : "s")"
    }
}
