import Cocoa
import Security
import EphedrineCore

// ── Reading & typing into cmux panes (auto-continue / limit-resume) ──
// cmux is a Ghostty-based terminal with a CLI that talks to its socket. Only
// its Password mode is supported: the password reaches the CLI as
// CMUX_SOCKET_PASSWORD in the child's environment, never as an argument
// (arguments show in `ps` to every user), and it is never logged.

let cmuxBundleID = "com.cmuxterm.app"
let cmuxKeyPrefix = "cmux:"   // per-tab state keys, so they can't collide with Terminal ttys
let cmuxReadBudget: TimeInterval = 10   // the whole cmux read in one scan

/// The CLI inside the running cmux, nil when cmux isn't running.
/// (NSRunningApplication is thread safe, so any queue may ask.)
func runningCmuxCLI() -> String? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: cmuxBundleID).first,
          let url = app.bundleURL else { return nil }
    return url.appendingPathComponent("Contents/Resources/bin/cmux").path
}

func cmuxInstalled() -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: cmuxBundleID) != nil }

/// The cmux socket password, a generic password in the login keychain.
enum CmuxKeychain {
    static let service = "ephedrine-cmux"
    static let account = "socket"

    /// Never shows a dialog: an item macOS would ask about is skipped.
    /// errSecItemNotFound is "none saved"; any other failure is `unreadable`.
    static func read() -> (password: String?, state: CmuxSavedPassword) {
        switch Keychain.read(service: service, account: account) {
        case .missing: return (nil, .none)
        case .unreadable(let status): return (nil, .unreadable(status))
        case .found(let pw): return pw.isEmpty ? (nil, .none) : (pw, .saved)
        }
    }

    /// Save the password, or remove it when empty. Main thread only: updating
    /// an item can make macOS ask, and nothing may wait on that answer.
    static func save(_ password: String) -> OSStatus {
        guard !password.isEmpty else { return Keychain.delete(service: service, account: account) }
        return Keychain.save(service: service, account: account, label: "Ephedrine cmux socket password", password: password)
    }
}

struct CmuxRun { let status: Int32; let out: String; let err: String; let timedOut: Bool; let timeout: TimeInterval }

/// Run the cmux CLI with the password in its environment, never waiting more
/// than `timeout` for it (plus a second or two to stop it). A stalled cmux
/// must not hold up the scan, which also serves Terminal.
func runCmux(_ cli: String, _ args: [String], password: String, timeout: TimeInterval = 5) -> CmuxRun {
    let r = runProcess(cli, args, tweakEnv: { env in
        // Inherited CMUX_* variables could point it at another socket or a default
        // surface; every call names its surface explicitly.
        env = env.filter { !$0.key.hasPrefix("CMUX_") }
        env["CMUX_SOCKET_PASSWORD"] = password
    }, timeout: timeout)
    return CmuxRun(status: r.launchFailed ? cmuxLaunchFailed : r.status, out: r.out, err: r.err, timedOut: r.timedOut, timeout: timeout)
}

/// Why a run didn't do its job, for the log (cmux's own error line).
func cmuxWhy(_ r: CmuxRun) -> String {
    if r.timedOut { return "cmux didn't answer within \(Int(r.timeout.rounded(.up)))s" }
    let line = r.err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(r.status)"
    return String(line.prefix(200))
}

/// One scan's read of cmux. `access` nil: the listing itself got no answer.
struct CmuxRead {
    var access: CmuxAccess?
    var listed: [CmuxSurface] = []
    var tabs: [(CmuxSurface, String)] = []   // the listed panes whose screen was read
    var unreadable: Set<String> = []         // listed panes whose read-screen failed outright (not a timeout)
    var stalled = false                      // a call timed out or the budget ran out
    var why = ""                             // what stalled, for the log
}

/// The listing alone (Settings counts panes from it).
func cmuxList(cli: String, password: String, timeout: TimeInterval = 5) -> (access: CmuxAccess?, surfaces: [CmuxSurface], run: CmuxRun) {
    let r = runCmux(cli, cmuxListArgs, password: password, timeout: timeout)
    if r.timedOut { return (nil, [], r) }
    let access = cmuxAccess(exitCode: r.status, output: r.err + "\n" + r.out)
    return (access, access == .ok ? parseCmuxSurfaces(r.out) : [], r)
}

/// cmux's terminal panes and each one's visible text: one listing, then one
/// read-screen per pane. Read-only. Runs off the main thread, within `budget`
/// seconds in all: when a call times out or the budget runs out, the panes not
/// read yet are left for the next scan (and keep their state).
func cmuxSurfacesSnapshot(cli: String, password: String, budget: TimeInterval = cmuxReadBudget) -> CmuxRead {
    let deadline = Date().addingTimeInterval(budget)
    let (access, surfaces, list) = cmuxList(cli: cli, password: password, timeout: min(5, budget))
    var res = CmuxRead(access: access, listed: surfaces)
    guard let access else { res.stalled = true; res.why = cmuxWhy(list); return res }
    guard access == .ok else { return res }
    for s in surfaces {
        let left = deadline.timeIntervalSinceNow
        guard left > 0.5 else { res.stalled = true; res.why = "the \(Int(budget))s read budget ran out"; break }
        let r = runCmux(cli, cmuxReadArgs(s.id), password: password, timeout: min(5, left))
        if r.timedOut { res.stalled = true; res.why = cmuxWhy(r); break }
        // A definite error (closed since the listing, hibernated) isn't a stall:
        // the pane's state ages out as for a closed one.
        if r.status == 0 { res.tabs.append((s, r.out)) } else { res.unreadable.insert(s.id) }
    }
    return res
}

/// The pane's live input state (bottom of its screen, not the scrolled view).
func cmuxInputState(cli: String, password: String, surfaceID: String) -> CmuxInputState? {
    guard let args = cmuxInputStateArgs(surfaceID) else { return nil }
    let r = runCmux(cli, args, password: password)
    guard !r.timedOut, r.status == 0 else { return nil }
    return parseCmuxInputState(r.out)
}

/// Type text, then Enter, into one cmux surface. In order, right before
/// typing: read the bottom of the pane (not the scrolled view the scan saw)
/// and check `trigger` there, ask cmux what the live prompt holds
/// (cmuxTypeDecision), and re-check the Mac is fully awake.
func sendToCmux(_ text: String, surfaceID: String, trigger: CmuxLiveTrigger, canTypeNow: () -> Bool) -> SendResult {
    guard let cli = runningCmuxCLI() else { return .skipped("cmux isn't running") }
    guard let pw = CmuxKeychain.read().password else { return .skipped("no cmux password could be read") }
    let live = runCmux(cli, cmuxLiveTailArgs(surfaceID), password: pw)
    guard !live.timedOut, live.status == 0 else { return .skipped("couldn't read the bottom of the pane: " + cmuxWhy(live)) }
    guard cmuxLiveTailShows(trigger, in: live.out) else { return .skipped(trigger.missing) }
    let force: Bool
    switch cmuxTypeDecision(state: cmuxInputState(cli: cli, password: pw, surfaceID: surfaceID), purpose: trigger.purpose) {
    case .skip(let why): return .skipped(why)
    case .send: force = false
    case .force: force = true
    }
    guard canTypeNow() else { return .notAwake }
    let typed = runCmux(cli, cmuxSendArgs(surfaceID, text, force: force), password: pw)
    guard !typed.timedOut, typed.status == 0 else { return .skipped(cmuxWhy(typed)) }
    let enter = runCmux(cli, cmuxEnterArgs(surfaceID, force: force), password: pw)
    guard !enter.timedOut, enter.status == 0 else { return .skipped("typed “\(text)” but not Enter: " + cmuxWhy(enter)) }
    return .typed
}

/// fullyAwake and lastFullWake, written on the main thread and read by the
/// scan queue right before it types, instead of the scan's start-time copy.
final class WakeGate {
    private let lock = NSLock()
    private var fullyAwake = true
    private var lastFullWake = Date.distantPast
    func update(fullyAwake: Bool, lastFullWake: Date) {
        lock.lock(); self.fullyAwake = fullyAwake; self.lastFullWake = lastFullWake; lock.unlock()
    }
    /// Fully awake (and the kernel still says so), and not within `quiet` of waking.
    func canType(quiet: TimeInterval) -> Bool {
        lock.lock()
        let ok = fullyAwake && Date().timeIntervalSince(lastFullWake) > quiet
        lock.unlock()
        return ok && systemFullyAwake(fallback: true)
    }
}

// ── The controller's cmux side: scan, Settings ──

extension AppController {
    /// What Settings shows for cmux (main thread; checks run on continueQueue).
    /// Read once at launch so the pane's first frame isn't a wrong "Not installed".
    struct CmuxSeen {
        var installed = cmuxInstalled()
        var password = CmuxKeychain.read().state   // never shows a dialog
        var access: CmuxAccess?
        var panes = 0
    }

    /// continueQueue only.
    struct CmuxScanState {
        var lastLogged = ""                 // last cmux state logged
        var stalls = 0                      // scans in a row that cmux didn't fully answer
        var textAtSend: [String: String] = [:]   // pane key → its screen when Ephedrine last typed there
        var stuck: Set<String> = []         // panes whose screen didn't change after typing: no more typing this episode
    }

    /// Runs on continueQueue. cmux's panes for this scan, read only while cmux
    /// is running and a password is saved; otherwise none, and the scan is
    /// Terminal's alone, as before cmux support. `read(key)` says whether this
    /// read speaks for a pane's state: it was read (or its read failed outright),
    /// or the listing worked and the pane is gone. A pane whose read timed out
    /// or didn't fit the budget keeps its state.
    func scanCmux(_ flags: ScanFlags) -> (tabs: [ScanTab], read: (String) -> Bool) {
        let nothing: (String) -> Bool = { _ in false }
        guard let cli = flags.cmuxCLI else {
            // Not running: nothing can be read or typed there, so drop its
            // state rather than keep a retry or a limit wait alive for it.
            forgetCmuxTabs()
            cmuxScan.stalls = 0
            if !cmuxScan.lastLogged.isEmpty { cmuxScan.lastLogged = ""; logLine("cmux: not running, reading Terminal only") }
            return ([], nothing)
        }
        let (pw, saved) = CmuxKeychain.read()
        DispatchQueue.main.async { [weak self] in self?.cmuxSeen.password = saved }
        guard let pw else {
            forgetCmuxTabs()
            if case .unreadable(let s) = saved {
                noteCmux("cmux: couldn't read the saved password (OSStatus \(s)), so not reading it")
            } else {
                noteCmux("cmux: running, but no password saved in Settings › Claude Code, so not reading it")
            }
            return ([], nothing)
        }
        let got = cmuxSurfacesSnapshot(cli: cli, password: pw)
        // An unrecognised failure (overloaded, quitting) counts as a stall:
        // state is kept, up to three in a row.
        var failedWhy: String?
        if case .failed(let why)? = got.access { failedWhy = why }
        if got.stalled || failedWhy != nil {
            // Panes not read keep their state, but a cmux that keeps stalling
            // must not hold the Mac awake for a retry or wait it can't serve.
            cmuxScan.stalls += 1
            noteCmux(failedWhy.map { "cmux: not connected: \($0), its panes keep their state" }
                     ?? "cmux: didn't fully answer (\(got.why)), panes not read keep their state")
            if cmuxScan.stalls >= 3 {
                // A cmux that keeps stalling is unreadable until it fully answers
                // again: no panes from it, so nothing it half-read starts over.
                if cmuxScan.stalls == 3 { logLine("cmux: 3 scans in a row without a full answer, dropping its retry and limit state") }
                forgetCmuxTabs()
                return ([], nothing)
            }
        } else {
            cmuxScan.stalls = 0
        }
        guard let access = got.access else { return ([], nothing) }
        let panes = got.listed.count
        DispatchQueue.main.async { [weak self] in self?.cmuxSeen.access = access; self?.cmuxSeen.panes = panes }
        if failedWhy != nil { return ([], nothing) }
        switch access {
        case .ok where got.stalled, .failed: break   // the stall line above says it
        case .ok:   // logged when the set of panes changes, not on every scan
            let keys = got.listed.map { cmuxKeyPrefix + $0.id }
            noteCmux("cmux: connected, \(panes) pane(s): " + keys.joined(separator: ", "), key: "ok " + keys.joined(separator: " "))
        case .badPassword: noteCmux("cmux: password not accepted, not reading it")
        case .needsPassword: noteCmux("cmux: wants a password it doesn't have (set one in cmux Settings › Automation)")
        case .denied: noteCmux("cmux: not connected (its Automation setting doesn't let Ephedrine in)")
        case .notInstalled: noteCmux("cmux: couldn't start its command-line tool")
        }
        guard access == .ok else { forgetCmuxTabs(); return ([], nothing) }
        let tabs: [ScanTab] = got.tabs.map { (.cmux(surfaceID: $0.0.id), cmuxKeyPrefix + $0.0.id, $0.1) }
        let listed = Set(got.listed.map { cmuxKeyPrefix + $0.id })
        let readKeys = Set(tabs.map(\.key)).union(got.unreadable.map { cmuxKeyPrefix + $0 })
        if errorSkipLogged.keys.contains(where: { $0.hasPrefix(cmuxKeyPrefix) && !listed.contains($0) }) {
            errorSkipLogged = errorSkipLogged.filter { !$0.key.hasPrefix(cmuxKeyPrefix) || listed.contains($0.key) }
        }
        // A pane whose screen is byte-identical to when Ephedrine last typed
        // there: the typing changed nothing it can see, so stop for this episode.
        for tab in tabs where cmuxScan.textAtSend[tab.key] == tab.text && !cmuxScan.stuck.contains(tab.key) {
            cmuxScan.stuck.insert(tab.key)
            logLine("cmux: \(tab.key) looks the same as when Ephedrine last typed there, not typing into it again until this error or limit is over")
        }
        return (tabs, { key in readKeys.contains(key) || !listed.contains(key) })
    }

    /// Log a cmux state once, when it (or the `key` standing for it) changes (continueQueue).
    func noteCmux(_ state: String, key: String? = nil) {
        guard (key ?? state) != cmuxScan.lastLogged else { return }
        cmuxScan.lastLogged = key ?? state
        logLine(state)
    }

    /// Drop every cmux pane's retry, limit, log and typing state (continueQueue).
    func forgetCmuxTabs() {
        let isCmux: (String) -> Bool = { $0.hasPrefix(cmuxKeyPrefix) }
        if continueStates.keys.contains(where: isCmux) { continueStates = continueStates.filter { !isCmux($0.key) } }
        if limitEpisodes.keys.contains(where: isCmux) { limitEpisodes = limitEpisodes.filter { !isCmux($0.key) } }
        if errorSkipLogged.keys.contains(where: isCmux) { errorSkipLogged = errorSkipLogged.filter { !isCmux($0.key) } }
        cmuxScan.textAtSend.removeAll()
        cmuxScan.stuck.removeAll()
    }

    /// After a cmux send, remember the scan's screen it was typed against
    /// (continueQueue). An episode that ended takes its memory with it.
    func noteCmuxTyped(_ key: String, screen: String) {
        if key.hasPrefix(cmuxKeyPrefix) { cmuxScan.textAtSend[key] = screen }
    }

    func endCmuxEpisodes() {
        for key in Array(cmuxScan.textAtSend.keys) + Array(cmuxScan.stuck)
            where continueStates[key] == nil && limitEpisodes[key] == nil {
            cmuxScan.textAtSend.removeValue(forKey: key)
            cmuxScan.stuck.remove(key)
        }
    }

    /// Check cmux now, for Settings (pane opened, or a password saved): the
    /// listing only, off the main thread.
    func refreshCmux() {
        cmuxSeen.installed = cmuxInstalled()
        let cli = runningCmuxCLI()
        continueQueue.async { [weak self] in
            let (pw, saved) = CmuxKeychain.read()
            var access: CmuxAccess?, panes = 0
            if let cli, let pw {
                let list = cmuxList(cli: cli, password: pw)
                access = list.access
                panes = list.surfaces.count
            }
            DispatchQueue.main.async {
                self?.cmuxSeen.password = saved
                if let access { self?.cmuxSeen.access = access; self?.cmuxSeen.panes = panes }
            }
        }
    }

    /// Save (or with "", remove) the password on the main thread, where a
    /// keychain question can't stall the scan, then check again.
    func saveCmuxPassword(_ password: String) {
        let s = CmuxKeychain.save(password)
        logLine(s != errSecSuccess ? "couldn't save the cmux password (OSStatus \(s))"
                : password.isEmpty ? "cmux password removed" : "cmux password saved")
        cmuxSeen.access = nil   // "Checking…" until the answer is in
        refreshCmux()
    }

    /// The cmux line in Settings › Claude Code.
    var cmuxStatus: String {
        cmuxStatusText(installed: cmuxSeen.installed, running: runningCmuxCLI() != nil,
                       password: cmuxSeen.password, access: cmuxSeen.access, panes: cmuxSeen.panes)
    }
}
