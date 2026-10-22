import Foundation

// ── Pausing Claude at the battery limit ──
//
// At the battery limit Ephedrine stops keeping the Mac awake, but Claude Code
// keeps the Mac up by itself (it runs `caffeinate` while it works) and works on
// in every nap. So once the owner is away, Claude Code is paused (SIGSTOP) and
// the Mac put to sleep, and what's left of the battery is still there when
// they're back. With the owner at the Mac it only says so. Claude carries on
// once the Mac is on the charger or the owner is back.

public enum BatteryResumeReason: String {
    case pluggedIn, back, turnedOff
}

public enum BatteryPauseEvent: Equatable {
    case warnHere                          // at the limit, owner at the Mac, Claude working: say what happens next
    case headsUp                           // lid open and owner idle: pausing in headsUpDelay unless they touch the Mac
    case cancelled                         // they did
    case pauseAndSleep
    case resume(BatteryResumeReason)
}

public struct BatteryPauseInputs {
    public var enabled: Bool          // the setting
    public var stopped: Bool          // BatteryStop.stopped: on battery at the limit
    public var onBattery: Bool
    public var lidShutAlone: Bool     // lid shut and no external display
    public var fullyAwake: Bool       // systemFullyAwake: false in a nap
    public var idle: TimeInterval     // HID idle, which leaves out time asleep
    public var awayAfter: TimeInterval   // idle this long with the lid open = away (the sleep countdown's grace)
    public var claudeBusy: Bool       // only decides whether there's anything to warn about
    public var now: Date
    public init(enabled: Bool, stopped: Bool, onBattery: Bool, lidShutAlone: Bool, fullyAwake: Bool,
                idle: TimeInterval, awayAfter: TimeInterval, claudeBusy: Bool, now: Date) {
        self.enabled = enabled; self.stopped = stopped; self.onBattery = onBattery
        self.lidShutAlone = lidShutAlone; self.fullyAwake = fullyAwake; self.idle = idle
        self.awayAfter = awayAfter; self.claudeBusy = claudeBusy; self.now = now
    }
}

public struct BatteryPause: Equatable {
    public static let headsUpDelay: TimeInterval = 10
    /// Input this soon after pausing is the same visit, not a return.
    public static let backAfter: TimeInterval = 15
    /// Idle under this, awake with the lid open: the owner is back.
    public static let backIdle: TimeInterval = 5

    public private(set) var paused = false
    public private(set) var pausedAt: Date?
    public private(set) var headsUpAt: Date?
    private var warned = false
    public init() {}

    /// Call every tick. Pausing also needs the Mac asleep after it (the app
    /// does both on .pauseAndSleep), even when nothing Claude was running.
    public mutating func step(_ i: BatteryPauseInputs) -> BatteryPauseEvent? {
        if paused {
            if !i.onBattery { return resume(.pluggedIn) }
            if !i.enabled { return resume(.turnedOff) }
            if i.fullyAwake, !i.lidShutAlone, i.idle < Self.backIdle,
               let at = pausedAt, i.now.timeIntervalSince(at) >= Self.backAfter { return resume(.back) }
            return nil
        }
        if !i.stopped { warned = false }
        guard i.enabled, i.stopped, i.onBattery else { headsUpAt = nil; return nil }
        // Lid shut: away, even in a nap (Claude would run in every one).
        if i.lidShutAlone { return pause(i.now) }
        guard i.fullyAwake else { headsUpAt = nil; return nil }
        if i.idle >= i.awayAfter {
            guard let h = headsUpAt else { headsUpAt = i.now; return .headsUp }
            return i.now.timeIntervalSince(h) >= Self.headsUpDelay ? pause(i.now) : nil
        }
        if headsUpAt != nil { headsUpAt = nil; return .cancelled }
        if i.claudeBusy && !warned { warned = true; return .warnHere }
        return nil
    }

    private mutating func pause(_ now: Date) -> BatteryPauseEvent {
        paused = true; pausedAt = now; headsUpAt = nil
        return .pauseAndSleep
    }

    private mutating func resume(_ why: BatteryResumeReason) -> BatteryPauseEvent {
        paused = false; pausedAt = nil
        return .resume(why)
    }
}

/// A process's executable path (`ps -o comm=`, which may be a title the
/// process set, like "claude bg-pty-host") and its command line (`ps -o args=`).
public struct ProcText: Equatable {
    public let comm: String
    public let args: String
    public init(comm: String, args: String) { self.comm = comm; self.args = args }
}

private func baseName(_ path: String) -> String {
    let base = path.split(separator: "/").last.map(String.init) ?? path
    return base.hasPrefix("-") ? String(base.dropFirst()) : base   // a login shell: "-zsh"
}

/// Claude Code itself: the `claude` CLI (sessions, its daemon and pty hosts),
/// a versioned binary under claude/versions/, or the npm package under node.
/// Not the Chrome extension's native host (the browser owns it), and not the
/// desktop app ("Claude") or anything that only mentions Claude.
public func isClaudeCode(_ p: ProcText) -> Bool {
    if p.args.contains("--chrome-native-host") { return false }
    if baseName(p.comm).split(separator: " ").first == "claude" { return true }
    if p.comm.contains("/claude/versions/") { return true }
    return p.args.contains("@anthropic-ai/claude-code/")
}

private let jobControlShells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]

/// A shell that may run Claude Code as its foreground job.
public func isJobControlShell(_ comm: String) -> Bool { jobControlShells.contains(baseName(comm)) }

/// What a battery pause stops, in the order stopRecorded wants (it stops back
/// to front and resumes front to back): every Claude Code process with all it
/// runs, parents first, then the shells sessions run in. A shell has to be
/// stopped before its foreground job and resumed after it: zsh that sees its
/// job stop prints "suspended", takes the terminal back, and the job dies on
/// resume (tested 2026-10-21; stopped shell-first, vim got every key typed
/// meanwhile). Never caffeinate (Claude's sleep assertion would outlast the
/// pause), Ephedrine or what it runs, or launchd.
public func claudePausePlan(procs: [ProcEntry], info: [Int32: ProcText], selfPID: Int32) -> [ProcEntry] {
    var spared = Set(descendants(of: [selfPID], in: procs).map(\.pid))
    spared.insert(selfPID)
    for p in procs where info[p.pid].map({ baseName($0.comm) == "caffeinate" }) ?? false { spared.insert(p.pid) }
    let walkable = procs.filter { $0.pid > 1 && !spared.contains($0.pid) }
    let roots = walkable.filter { info[$0.pid].map(isClaudeCode) ?? false }
    let tree = descendants(of: roots.map(\.pid), in: walkable)
    let inTree = Set(tree.map(\.pid))
    let byPID = Dictionary(walkable.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    var shells: [ProcEntry] = []
    for r in roots {
        guard let parent = byPID[r.ppid], !inTree.contains(parent.pid),
              let text = info[parent.pid], isJobControlShell(text.comm),
              !shells.contains(parent) else { continue }
        shells.append(parent)
    }
    return tree + shells
}
