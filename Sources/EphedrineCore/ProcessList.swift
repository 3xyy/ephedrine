import Foundation

// Pure classifiers over `ps` output lines, so detector logic is unit-testable.

/// True if a terminal has a *foreground* command actually running, not just an
/// idle prompt, a background helper (gitstatusd, autosuggest), a shell/multiplexer,
/// or Claude Code itself. Input: `ps -axo tty=,pgid=,tpgid=,command=` lines.
public func interactiveShellRunningCommand(psLines: [String]) -> Bool {
    let ignore: Set<String> = ["zsh", "bash", "sh", "fish", "ksh", "tcsh", "dash", "csh",
                               "tmux", "screen", "login"]

    // Any tty hosting a Claude Code session: its whole subprocess tree (MCP
    // servers, LSPs, spawned tools) shares that tty, so exclude the tty entirely.
    var claudeTtys = Set<String>()
    for line in psLines {
        let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard p.count >= 4 else { continue }
        let tty = p[0]
        if tty == "??" || tty == "?" { continue }
        if p[3...].joined(separator: " ").lowercased().contains("claude") { claudeTtys.insert(tty) }
    }

    for line in psLines {
        let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard p.count >= 4 else { continue }
        let tty = p[0]
        if tty == "??" || tty == "?" || claudeTtys.contains(tty) { continue }
        guard let pgid = Int(p[1]), let tpgid = Int(p[2]), pgid == tpgid else { continue }  // foreground only
        let cmd = p[3...].joined(separator: " ")
        var exe = (String(cmd.split(separator: " ").first ?? "") as NSString).lastPathComponent
        if exe.hasPrefix("-") { exe.removeFirst() }
        if ignore.contains(exe) { continue }                 // idle shell / multiplexer
        if cmd.lowercased().contains("ephedrine") { continue }
        return true
    }
    return false
}

/// True if any `ps -axo comm=` line's executable name is in `names`.
public func processCommMatches(commLines: [String], names: Set<String>) -> Bool {
    for line in commLines {
        let name = (line.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        if names.contains(name) { return true }
    }
    return false
}

/// True if a monitoring command is running: top-likes by executable name, or
/// tail -f / log stream / watch by command line (watch matched as the leading
/// executable, optionally behind sudo, to avoid substring false positives).
public func monitorRunning(commLines: [String], commandLines: [String]) -> Bool {
    if processCommMatches(commLines: commLines,
                          names: ["top", "htop", "btop", "glances", "nvtop", "bpytop"]) { return true }
    for line in commandLines {
        if line.contains("tail -f") || line.contains("tail -F") || line.contains("log stream") { return true }
        var toks = line.split(separator: " ").map(String.init)
        if toks.first == "sudo" { toks.removeFirst() }
        if let first = toks.first, (first as NSString).lastPathComponent == "watch" { return true }
    }
    return false
}
