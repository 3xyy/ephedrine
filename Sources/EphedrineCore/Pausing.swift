import Foundation

// Who "I'm leaving" and the lid pause stop, and how a stopped process is
// recognised later. Pure, so the rules are unit-testable; the process table
// read and the signals live in the app target.

/// A running app, as far as pausing cares (from NSRunningApplication).
public struct RunningAppInfo {
    public let pid: Int32
    public let bundleID: String?
    public let name: String
    /// activationPolicy == .regular: it has a Dock icon. Menu-bar apps don't.
    public let regular: Bool
    public init(pid: Int32, bundleID: String?, name: String, regular: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.regular = regular
    }
    /// The name for logs and the menu: its name, else its bundle id, else its pid.
    public var displayName: String { name.isEmpty ? (bundleID ?? "pid \(pid)") : name }
}

/// One row of the kernel's process table. `start` is the start time in
/// microseconds (seconds×1_000_000 + micros). A pid gets reused; a pid with
/// its start time doesn't.
public struct ProcEntry: Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let start: Int64
    public init(pid: Int32, ppid: Int32, start: Int64) { self.pid = pid; self.ppid = ppid; self.start = start }
}

/// A process we stopped, with its start time so resume never signals a reused pid.
public struct PausedProcess: Codable, Equatable {
    public let pid: Int32
    public let start: Int64
    public init(pid: Int32, start: Int64) { self.pid = pid; self.start = start }
}

/// Bundle id prefixes never paused: every JetBrains IDE, and Zoom's and
/// Webex's helper apps (freezing one drops a call).
public let builtInKeepRunningPrefixes: [String] = ["com.jetbrains.", "us.zoom.", "com.cisco.webex."]

/// An app whose name has one of these is never paused: browsers Claude or a
/// test run may be driving, whatever their bundle id.
public let pauseExemptBrowserWords = ["chrome", "chromium", "brave", "safari", "edge", "arc", "firefox", "playwright"]

/// Pause every regular app except the keep-running ones; an app on Always
/// pause is paused even if it's on the keep-running list. Never launchd or
/// Ephedrine itself, whatever the lists say: a stopped Ephedrine can't resume anything.
public func shouldPause(_ app: RunningAppInfo, keepRunning: Set<String>, alwaysPause: Set<String>, selfPID: Int32) -> Bool {
    guard app.pid > 1, app.pid != selfPID else { return false }
    if let id = app.bundleID, alwaysPause.contains(id) { return true }
    let id = app.bundleID ?? ""
    guard app.regular, !keepRunning.contains(id),
          !builtInKeepRunningPrefixes.contains(where: { id.hasPrefix($0) }) else { return false }
    let name = app.name.lowercased()
    return !pauseExemptBrowserWords.contains { name.contains($0) }
}

/// The roots and every process below them, breadth-first: the roots first,
/// then their children, then grandchildren. Each pid once, even with a
/// parent loop (pid 0 is its own parent). A root missing from `procs` (it
/// exited) is left out.
public func descendants(of roots: [Int32], in procs: [ProcEntry]) -> [ProcEntry] {
    var byPID: [Int32: ProcEntry] = [:]
    var children: [Int32: [ProcEntry]] = [:]
    for p in procs {
        byPID[p.pid] = p
        children[p.ppid, default: []].append(p)
    }
    var seen = Set<Int32>()
    var out: [ProcEntry] = []
    for r in roots { if let p = byPID[r], seen.insert(r).inserted { out.append(p) } }
    var i = 0
    while i < out.count {
        for c in children[out[i].pid] ?? [] where seen.insert(c.pid).inserted { out.append(c) }
        i += 1
    }
    return out
}

/// Pids whose command line mentions Claude, from `ps -axo pid=,args=` lines
/// (the same test interactiveShellRunningCommand uses). A stray match only
/// means less pausing.
public func claudePids(psLines: [String]) -> Set<Int32> {
    var out = Set<Int32>()
    for line in psLines {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
        if parts[1].lowercased().contains("claude") { out.insert(pid) }
    }
    return out
}

/// What one pause stops: the apps `shouldPause` picks, and each one's process
/// tree, apps first (stop it in reverse, resume it in order). The walk down
/// stops at Ephedrine (its watchdog is its child) and at a regular app that's
/// kept running, even if a paused app started it. Helper apps aren't regular
/// (Electron's helpers are menu-bar apps), so they're paused with their app,
/// even one the keep-running rules name when its app is on Always pause.
/// An app with Claude Code anywhere in its tree (`claudePIDs`) isn't paused at
/// all, Always pause or not: its name goes in `keptForClaude`.
/// Empty when `procs` is: no snapshot, no start times, nothing we could safely resume.
public func pausePlan(apps: [RunningAppInfo], procs: [ProcEntry], keepRunning: Set<String>,
                      alwaysPause: Set<String>, selfPID: Int32, claudePIDs: Set<Int32>)
    -> (apps: [RunningAppInfo], processes: [ProcEntry], keptForClaude: [String]) {
    var chosen: [RunningAppInfo] = []
    var spared: Set<Int32> = [selfPID]
    for app in apps {
        if shouldPause(app, keepRunning: keepRunning, alwaysPause: alwaysPause, selfPID: selfPID) {
            chosen.append(app)
        } else if app.regular {
            spared.insert(app.pid)
        }
    }
    let walkable = procs.filter { $0.pid > 1 && !spared.contains($0.pid) }
    let hosts = chosen.filter { app in descendants(of: [app.pid], in: walkable).contains { claudePIDs.contains($0.pid) } }
    let hostPIDs = Set(hosts.map(\.pid))
    chosen.removeAll { hostPIDs.contains($0.pid) }
    let tree = descendants(of: chosen.map(\.pid), in: walkable)   // no host is below a chosen app: that app would be a host too
    let inTree = Set(tree.map(\.pid))
    return (chosen.filter { inTree.contains($0.pid) }, tree, hosts.map(\.displayName))
}

/// True if the paused process is still running as itself (same pid, same start).
public func stillSame(_ p: PausedProcess, in procs: [ProcEntry]) -> Bool {
    procs.contains { $0.pid == p.pid && $0.start == p.start }
}

/// Which paused processes to SIGCONT, in order: those still running as
/// themselves. An empty snapshot means the process table couldn't be read,
/// so all of them: a stray SIGCONT does far less harm than an app left frozen.
public func toResume(_ paused: [PausedProcess], in procs: [ProcEntry]) -> [PausedProcess] {
    procs.isEmpty ? paused : paused.filter { stillSame($0, in: procs) }
}

/// away-state.json: what an interrupted pause leaves for the next launch to undo.
public struct AwayState: Codable, Equatable {
    /// What was stopped, apps before their helpers. nil in a file an older version wrote.
    public var processes: [PausedProcess]?
    /// The same pids without start times: all an older version wrote, and still written for one.
    public var pids: [Int32]?
    public var brightness: Double?
    public init(processes: [PausedProcess]?, pids: [Int32]?, brightness: Double?) {
        self.processes = processes; self.pids = pids; self.brightness = brightness
    }

    /// The pids to SIGCONT: the recorded processes still running as
    /// themselves, or every pid of a file from before start times were kept.
    public func pidsToResume(in procs: [ProcEntry]) -> [Int32] {
        if let processes = processes { return toResume(processes, in: procs).map(\.pid) }
        return pids ?? []
    }
}
