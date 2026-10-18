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

/// What a surface's prompt holds on its live screen (cmux reads the bottom of
/// the terminal for this, not the part the owner may have scrolled to).
public func cmuxInputStateArgs(_ id: String) -> [String] {
    let params = (try? JSONSerialization.data(withJSONObject: ["surface_id": id]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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
