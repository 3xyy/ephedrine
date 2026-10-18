import Cocoa
import IOKit
import IOKit.ps
import ServiceManagement
import UserNotifications
import EphedrineCore

// ───────────────────────────── Lid-closed mode ─────────────────────────────
//
// A MacBook sleeps on lid close no matter what power assertions are held; the
// only switch that stops it (on battery too) is `pmset disablesleep 1`, which
// needs root. A one-time setup installs a sudoers drop-in allowing exactly
// `pmset -a disablesleep 0|1`, so the app can flip it with `sudo -n`.
//
// disablesleep is system-wide and outlives this process, so ownership is
// tracked with a marker file and undone on quit, by a watchdog after a crash,
// and on next launch.

let lidSudoersPath = "/etc/sudoers.d/ephedrine"
let lidMarkerPath = "\(home)/.claude/ephedrine/lid-sleep-disabled"   // exists ⇔ we turned it on

// ── System state ──

private func rootDomainProperty(_ key: String) -> CFTypeRef? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    return IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
private func rootDomainBool(_ key: String) -> Bool? {
    let v = rootDomainProperty(key)
    return (v as? Bool) ?? (v as? NSNumber)?.boolValue
}

func lidIsClosed() -> Bool { rootDomainBool("AppleClamshellState") ?? false }
func sleepIsDisabled() -> Bool { rootDomainBool("SleepDisabled") ?? false }

/// The kernel's current system capabilities (CPU 0x1, graphics 0x2, audio 0x4,
/// network 0x8, disk 0x10), or nil if unavailable.
func systemCapabilities() -> Int? { (rootDomainProperty("System Capabilities") as? NSNumber)?.intValue }

/// Fully awake, not in a lid-closed maintenance "DarkWake" (which has no
/// graphics capability). NSWorkspace's didWake/willSleep can't be trusted for
/// this: on 2026-10-05 didWake fired during a DarkWake and no willSleep
/// followed, so lid-closed mode switched on mid-DarkWake and held the Mac there
/// for 74 minutes with Wi-Fi refusing to join ("System is sleeping").
func systemFullyAwake(fallback: Bool) -> Bool {
    systemCapabilities().map { $0 & 0x2 != 0 } ?? fallback
}

/// An external display is driving the desktop (clamshell desk setup). A shut
/// lid then doesn't mean nobody's using the Mac.
func externalDisplayActive() -> Bool {
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &n) == .success, n > 0 else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    guard CGGetActiveDisplayList(n, &ids, &n) == .success else { return false }
    return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 }
}

func batteryPercent() -> Int? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for src in list {
        guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return cur * 100 / max
    }
    return nil
}

/// Lock the screen now (what the  menu's "Lock Screen" does), via the
/// private login.framework call. Returns false if it's missing on this macOS.
func lockScreen() -> Bool {
    typealias LockFn = @convention(c) () -> Int32
    guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
          let sym = dlsym(h, "SACLockScreenImmediate") else { return false }
    _ = unsafeBitCast(sym, to: LockFn.self)()
    return true
}

/// The thermal state in the words the Lid closed settings use.
func thermalStateText(_ t: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
    switch t {
    case .nominal:  return "Normal"
    case .fair:     return "Warm"
    case .serious:  return "Hot"
    case .critical: return "Very hot"
    @unknown default: return "Unknown"
    }
}

// ── Privileged switch ──

/// Exit status of a tool, all output discarded.
func runToolStatus(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func lidSetupInstalled() -> Bool { fm.fileExists(atPath: lidSudoersPath) }

/// Flip `disablesleep` through the sudoers rule. `-n`: never prompts.
func setSleepDisabled(_ on: Bool) -> Bool {
    runToolStatus("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]) == 0
}

/// Every lid on/off goes through here, in order (see SerialSwitch).
let lidSwitch = SerialSwitch(label: "ephedrine.lid", apply: setSleepDisabled)

private let lidPasswordPrompt = "Ephedrine wants to keep your Mac awake with the lid closed. Enter your password once to allow it."

/// Install the sudoers drop-in via the standard admin password dialog.
/// Returns nil on success, else a short reason ("cancelled" if dismissed).
func installLidSetup() -> String? {
    let user = NSUserName()
    guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
        return "unexpected user name"
    }
    // Root writes the fixed rule itself (no user-writable temp file to swap),
    // stages it under a dotted name (sudo ignores those), validates, then renames.
    let rule = lidSudoersRule(user: user).trimmingCharacters(in: .newlines)
    let staged = "/etc/sudoers.d/.ephedrine.new"
    let sh = "umask 0337 && /usr/bin/printf '%s\\n' \(shellQuoted(rule)) > \(staged)"
        + " && /usr/sbin/chown root:wheel \(staged) && /usr/sbin/visudo -cf \(staged)"
        + " && /bin/mv -f \(staged) \(lidSudoersPath) || { /bin/rm -f \(staged); exit 1; }"
    let r = runOsascript("do shell script \(appleScriptQuoted(sh)) with prompt \(appleScriptQuoted(lidPasswordPrompt)) with administrator privileges")
    if !r.err.isEmpty { return r.err.contains("-128") ? "cancelled" : r.err }
    // Exercise the exact command flipLid uses (a no-op write of the current
    // value). `sudo -l` would pass on any NOPASSWD rule, not necessarily ours.
    guard setSleepDisabled(sleepIsDisabled()) else {
        return "the rule was installed but sudo still wants a password"
    }
    return nil
}

func uninstallLidSetup() -> String? {
    let sh = "/bin/rm -f \(lidSudoersPath)"
    let r = runOsascript("do shell script \(appleScriptQuoted(sh)) with prompt \(appleScriptQuoted("Ephedrine is removing its lid-closed permission.")) with administrator privileges")
    if !r.err.isEmpty { return r.err.contains("-128") ? "cancelled" : r.err }
    return nil
}

/// A detached shell that outlives a crash: once this process is gone (and no
/// new Ephedrine has taken over), it un-pauses apps and turns disablesleep back off.
final class LidWatchdog {
    private var proc: Process?
    func start() {
        if proc?.isRunning == true { return }
        let marker = shellQuoted(lidMarkerPath)
        let pids = shellQuoted(pausedPidsPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 5; done
            /usr/bin/pgrep -xq Ephedrine && exit 0
            [ -s \(pids) ] && /bin/kill -CONT $(/bin/cat \(pids)) 2>/dev/null
            [ -f \(marker) ] && /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && /bin/rm -f \(marker)
            """]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); proc = p } catch { logLine("lid watchdog failed to start: \(error)") }
    }
    func stop() { proc?.terminate(); proc = nil }
}

// ───────────────────────────── Controller ─────────────────────────────

extension AppController {

    /// Called from evaluate() every tick.
    func updateLidMode(claudeBusy: Bool) {
        let closed = lidIsClosed()
        let battery = batteryPercent()
        let thermal = ProcessInfo.processInfo.thermalState
        var inputs = LidInputs(
            whileClaude: settings.lidWhileClaude, claudeBusy: claudeBusy, lidClosed: closed,
            onBattery: !onACPower(), batteryPercent: battery, batteryFloor: settings.batteryFloor,
            hot: lidTooHot(thermal, limit: settings.lidHeatLimit),
            closedCap: TimeInterval(settings.lidClosedCapHours * 3600), now: Date())
        // Before reading the switch: starting a check-in turns sleep off right away.
        stepCheckIn(closed: closed, guarded: lidGuardActive(lidState, inputs) || batteryStop.stopped, claudeBusy: claudeBusy)
        inputs.checkIn = checkIn.isOpen
        let actual = sleepIsDisabled()
        lidActive = actual
        if closed != lidLastClosed {
            lidLastClosed = closed
            let caps = systemCapabilities().map { String(format: " (capabilities 0x%x)", $0) } ?? ""
            logLine((closed ? "lid closed" : "lid opened") + caps)
            // Kept awake with the lid shut: turn the display off now rather than
            // leave it powered until its idle timer runs out.
            if closed && actual && fullyAwake && !externalDisplayActive() { sleepDisplayNow() }
        }
        updateLidPause(closed: closed)
        updateLidLock(closed: closed)
        guard lidSetupOK else { return }

        let out = stepLid(&lidState, inputs)
        if let e = out.sessionEnded {
            logLine("lid-closed session ended (\(e.rawValue))")
            // Stay awake drives the session; a battery or heat stop ends both.
            if e != .timeUp { manualKeepAwake = false; keepAwakeUntil = nil }
        }
        if let g = out.newlyTripped {
            let why: String
            switch g {
            case .hot:        why = "Your Mac is running \(thermalStateText(thermal).lowercased())"
            case .unplugged:  why = "Your Mac is on battery"
            case .lowBattery: why = "Battery is at \(battery ?? 0)%"
            }
            logLine("lid-closed mode stopped: \(g.rawValue)")
            // On battery with "Only when plugged in" there's nothing to tell while you're at the Mac.
            let quiet = g == .unplugged && !closed && out.sessionEnded == nil
            // A Mac hovering at the heat threshold with the lid open could flap, so notify at most every 30 min.
            if !quiet && (closed || Date().timeIntervalSince(lidGuardNotedAt) > 1800) { lidGuardNotedAt = Date(); lidNotify("Lid-closed mode stopped",
                      "\(why), so Ephedrine turned it off" + (closed ? " and put the Mac to sleep." : ".")) }
        }
        if out.capReached {
            let h = settings.lidClosedCapHours
            logLine("lid-closed mode stopped: lid shut for \(h)h")
            lidNotify("Lid-closed mode stopped", "The lid's been shut for \(h == 1 ? "an hour" : "\(h) hours"), so Ephedrine put the Mac to sleep.")
        }

        // Lid shut, nothing holding the Mac awake on purpose, yet it's awake:
        // ask again (the request right after lid mode turns off can go unanswered).
        if lidSleepWatch.step(lidClosed: closed, sleepDisabled: actual, fullyAwake: fullyAwake,
                              externalDisplay: externalDisplayActive(), lidWanted: out.disableSleep,
                              sleepStarting: Date().timeIntervalSince(lastWillSleep) < 60, now: Date()) {
            logLine("lid is shut but the Mac is still awake, asking it to sleep again")
            doSleep()
        }

        guard !lidApplying, Date() >= lidRetryAfter else { return }
        let ours = fm.fileExists(atPath: lidMarkerPath)
        if out.disableSleep && !actual {
            // Never switch it on from a lid-closed DarkWake: that would hold the
            // Mac in a half-awake state with no Wi-Fi. Only when fully awake.
            guard fullyAwake else { return }
            flipLid(true)
        } else if !out.disableSleep && actual && ours {
            flipLid(false)
        } else if !actual && ours {
            // Turned off elsewhere (watchdog, or by hand), so forget it.
            try? fm.removeItem(atPath: lidMarkerPath)
            updateWatchdog()
        }
    }

    /// Remote Control check-ins (see RemoteCheckIn): turn a lid-shut nap into a
    /// full wake for a couple of minutes so `claude remote-control` can fetch
    /// messages. Once it's over, stepLid lets the Mac sleep unless Claude is working.
    private func stepCheckIn(closed: Bool, guarded: Bool, claudeBusy: Bool) {
        let enabled = settings.lidRemoteCheckIn && settings.enabled && settings.lidWhileClaude && lidSetupOK
        let ev = checkIn.step(CheckInInputs(
            enabled: enabled, lidClosed: closed, fullyAwake: fullyAwake,
            sleepStarting: Date().timeIntervalSince(lastWillSleep) < 60,
            externalDisplay: externalDisplayActive(), guarded: guarded, onBattery: !onACPower(), now: Date()))
        switch ev {
        case .started?:
            let caps = systemCapabilities().map { String(format: " (capabilities 0x%x)", $0) } ?? ""
            logLine("Remote Control check-in: the Mac is napping\(caps), waking it fully")
            lidState.restartClosedClock(now: Date())
            lidFlipGeneration += 1   // supersedes any flip still finishing
            fm.createFile(atPath: lidMarkerPath, contents: nil)
            updateWatchdog()
            // Sleep off first: a full wake with the lid shut would otherwise clamshell-sleep at once.
            guard lidSwitch.setSync(true) else {
                try? fm.removeItem(atPath: lidMarkerPath)
                updateWatchdog()
                checkIn.cancel()
                logLine("Remote Control check-in skipped: `sudo pmset` failed")
                return
            }
            lidActive = true
            declareCheckInWake()
        case .fullyAwake(let after)?:
            logLine("Remote Control check-in: fully awake after \(Int(after))s, listening for \(Int(RemoteCheckIn.window / 60)) minutes")
            sleepDisplayNow()   // the wake request turned the display on; the lid is shut
        case .ended(let why)?:
            releaseCheckInWake()
            switch why {
            case .windowOver:
                logLine("Remote Control check-in over: " + (claudeBusy ? "Claude is working, so the Mac stays awake" : "nothing came in"))
            case .noFullWake:
                logLine("Remote Control check-in gave up: still napping after \(Int(RemoteCheckIn.fullWakeTimeout))s")
            default:
                logLine("Remote Control check-in ended (\(why.rawValue))")
            }
        case nil:
            if checkIn.isOpen && checkIn.awakeAt == nil { declareCheckInWake() }   // ask again until it wakes
        }
    }

    private func declareCheckInWake() {
        let r = IOPMAssertionDeclareUserActivity("Ephedrine: Remote Control check-in" as CFString,
                                                 kIOPMUserActiveLocal, &checkInWakeID)
        if r != kIOReturnSuccess { logLine(String(format: "Remote Control check-in: wake request failed (0x%x)", r)) }
    }

    private func releaseCheckInWake() {
        if checkInWakeID != 0 { IOPMAssertionRelease(checkInWakeID); checkInWakeID = 0 }
    }

    /// App Nap can stretch the 3s tick past a nap's few seconds, so check-ins
    /// would never start. Opt out while they're on (this doesn't stop sleep).
    func updateCheckInActivity() {
        if settings.lidRemoteCheckIn, checkInActivity == nil {
            checkInActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Checking for Remote Control messages when the Mac naps")
        } else if !settings.lidRemoteCheckIn, let a = checkInActivity {
            ProcessInfo.processInfo.endActivity(a)
            checkInActivity = nil
        }
    }

    /// The watchdog undoes disablesleep and un-pauses apps if Ephedrine dies.
    /// It runs while either is ours, not only in lid mode.
    func updateWatchdog() {
        let pids = (try? String(contentsOfFile: pausedPidsPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fm.fileExists(atPath: lidMarkerPath) || !pids.isEmpty { lidWatchdog.start() } else { lidWatchdog.stop() }
    }

    private func flipLid(_ on: Bool) {
        lidApplying = true
        lidFlipGeneration += 1
        let generation = lidFlipGeneration
        if on {
            fm.createFile(atPath: lidMarkerPath, contents: nil)   // before the switch, so a crash mid-flip is still cleaned up
            updateWatchdog()
        }
        lidSwitch.setAsync(on) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lidApplying = false
                // A synchronous off (releaseLidForSleep) ran after this flip and
                // already settled the state, so don't log or apply a stale "ON".
                guard generation == self.lidFlipGeneration else { return }
                guard ok else {
                    logLine("lid-closed mode: `sudo pmset` failed (setup missing?), retrying in 1 min")
                    if on { try? fm.removeItem(atPath: lidMarkerPath); self.updateWatchdog() }
                    self.lidSetupOK = lidSetupInstalled()
                    self.lidRetryAfter = Date().addingTimeInterval(60)
                    return
                }
                self.lidActive = on
                if on {
                    logLine("lid-closed mode ON, the Mac stays awake with the lid shut")
                } else {
                    try? fm.removeItem(atPath: lidMarkerPath)
                    self.updateWatchdog()
                    logLine("lid-closed mode OFF")
                    // Nobody can be using a Mac with its lid shut and no external
                    // display, so sleep now instead of running the idle countdown.
                    if lidIsClosed() && !externalDisplayActive() {
                        logLine("lid is shut, sleeping now")
                        self.doSleep()
                    }
                }
            }
        }
    }

    /// Pause other apps (same rules as "I'm leaving") while the lid is shut and
    /// lid-closed mode is keeping the Mac awake; resume when it opens. The
    /// built-in screen is already off with the lid shut, so there's nothing to dim.
    func updateLidPause(closed: Bool) {
        if lidPaused {
            guard !closed || !settings.lidPauseApps else { return }
            let n = pausedAppCount
            resumeApps(); clearAwayState(); lidPaused = false
            logLine(closed ? "lid pause turned off, resumed \(n) apps" : "lid opened, resumed \(n) apps")
            return
        }
        guard settings.lidPauseApps, closed, lidActive, !awayMode,
              fm.fileExists(atPath: lidMarkerPath),   // our lid mode, not a by-hand disablesleep
              !externalDisplayActive() else { return }
        suspendApps(); persistAwayState(); lidPaused = true
        logLine("lid shut, paused \(pausedAppCount) apps\(pausedList)")
    }

    /// With the lid shut in lid-closed mode the Mac never sleeps, so macOS never
    /// locks it. Lock it ourselves, once per close. Done at close, not open:
    /// locking on open would show the desktop for a moment first.
    func updateLidLock(closed: Bool) {
        guard closed else { lidLockedThisClose = false; return }
        guard settings.lidLockOnClose, !lidLockedThisClose, lidActive,
              fm.fileExists(atPath: lidMarkerPath),   // our lid mode (a normal close sleeps and locks by itself)
              !externalDisplayActive() else { return }
        lidLockedThisClose = true
        logLine(lockScreen() ? "lid shut, locked the screen" : "lid shut, couldn't lock the screen (lock call missing)")
    }

    /// doSleep(): macOS refuses to sleep while disablesleep is on (e.g. the
    /// idle countdown ending inside the post-Claude linger), so switch it off first.
    func releaseLidForSleep() {
        // No sleepIsDisabled() shortcut: an "on" may still be in flight on lidSwitch.
        guard fm.fileExists(atPath: lidMarkerPath) else { return }
        lidFlipGeneration += 1   // supersedes any flip still finishing
        guard lidSwitch.setSync(false) else { logLine("lid-closed mode: couldn't turn off before sleeping"); return }
        try? fm.removeItem(atPath: lidMarkerPath)
        updateWatchdog()
        lidActive = false
        lidState.lastClaudeBusy = .distantPast   // don't let the linger flip it back on mid-sleep
        logLine("lid-closed mode OFF (sleeping)")
    }

    /// applicationWillTerminate: never leave the Mac unable to sleep.
    func releaseLidOnQuit() {
        guard fm.fileExists(atPath: lidMarkerPath) else { return }
        // Queued after any flip still running, so a pending "on" can't land after this.
        if lidSwitch.setSync(false) {
            try? fm.removeItem(atPath: lidMarkerPath)
            logLine("lid-closed mode OFF (quitting)")
        }   // else the watchdog retries once we're gone
    }

    func lidNotify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka_lid", content: c, trigger: nil))
    }

    func lidStatusText() -> String? {
        guard lidActive else { return nil }
        if !fm.fileExists(atPath: lidMarkerPath) { return "Sleep is disabled (pmset disablesleep, not by Ephedrine)" }
        if lidState.session != nil { return "The lid can be shut" }
        return "Lid can be closed while Claude works"
    }

    // MARK: actions

    @objc func setupLid() {
        logLine("lid-closed setup: asking for the admin password")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = installLidSetup()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lidSetupOK = lidSetupInstalled()
                if let err = err {
                    logLine("lid-closed setup failed: \(err)")
                    if err != "cancelled" { self.lidNotify("Lid-closed setup failed", err) }
                    return
                }
                logLine("lid-closed setup installed (\(lidSudoersPath))")
                self.lidRetryAfter = .distantPast
                let login = SMAppService.mainApp.status == .enabled
                self.lidNotify("Lid-closed mode is ready",
                    "Close the lid while Claude works and it keeps going."
                    + (login ? "" : " Tip: turn on Open at login, so it's always switched back off after a restart."))
                self.evaluate()
            }
        }
    }

    @objc func removeLidSetup() {
        lidState.session = nil
        lidApplying = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Off in order with any flip still running, but ask for the password
            // OFF the switch queue: quit and doSleep() wait on lidSwitch, and a
            // dialog left open must never block them.
            if fm.fileExists(atPath: lidMarkerPath) { lidSwitch.setSync(false) }
            let err = uninstallLidSetup()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lidApplying = false
                if !sleepIsDisabled() { try? fm.removeItem(atPath: lidMarkerPath); self.updateWatchdog() }
                self.lidSetupOK = lidSetupInstalled()
                logLine(err.map { "lid-closed setup removal failed: \($0)" } ?? "lid-closed setup removed")
                self.evaluate()
            }
        }
    }

    func startLid(_ s: LidSession) {
        lidState.session = s
        lidState.tripped = nil   // an explicit request overrides a previous battery/heat stop
        logLine("lid-closed session: \(lidSessionText(s, now: Date()))")
        evaluate()
    }
    @objc func stopLidSession() {
        lidState.session = nil
        logLine("lid-closed session stopped")
        evaluate()
    }
}
