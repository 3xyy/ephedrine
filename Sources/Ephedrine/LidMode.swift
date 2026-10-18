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
// `pmset -a disablesleep 0|1` and `pmset -b lowpowermode 0|1`, so the app can
// flip them with `sudo -n`.
//
// Both are system-wide and outlive this process, so ownership is tracked with
// a marker file each and undone on quit, by a watchdog after a crash, and on
// next launch.

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

/// Every lid decision reads this. A normal build is the sensor. The simulation
/// build (`LID_SIMULATION=1 scripts/build.sh`) lets `~/.claude/ephedrine/simulate-lid`
/// ("closed" or "open") stand in for it, so the lid features can be tried with the lid up.
func lidClosedNow() -> Bool {
    #if LID_SIMULATION
    let text = try? String(contentsOfFile: "\(home)/.claude/ephedrine/simulate-lid", encoding: .utf8)
    return simulatedLid(text) ?? lidIsClosed()
    #else
    return lidIsClosed()
    #endif
}
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

/// An internal battery is fitted, readable or not (a desktop has none).
func hasInternalBattery() -> Bool {
    if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
       list.contains(where: { (IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String
                                == kIOPSInternalBatteryType }) {
        return true
    }
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return false }
    IOObjectRelease(svc)
    return true
}

/// Drawing from the internal battery (not the charger, not a UPS): the power
/// source whose settings `pmset -b` changes.
func onInternalBattery() -> Bool {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return false }
    return type == kIOPMBatteryPowerKey
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

// ── Low Power Mode ──
//
// `-b` is the battery profile, the one System Settings' "Only on Battery"
// sets. isLowPowerModeEnabled shows that profile only while the Mac runs on
// its battery, so Low Power Mode is only switched on there (BatterySettle);
// on the charger an owner's "Only on Battery" mode would read as off.

let lowPowerMarkerPath = "\(home)/.claude/ephedrine/low-power-on"   // exists ⇔ we turned it on; holds the cause

/// Flip the battery profile's Low Power Mode through the sudoers rule. `-n`: never prompts.
func setLowPowerMode(_ on: Bool) -> Bool {
    runToolStatus("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-b", "lowpowermode", on ? "1" : "0"]) == 0
}

/// Every Low Power Mode write (on, off, the rule check) runs here, in order, so
/// a synchronous off at sleep or quit can't be overtaken by an earlier on.
let lowPowerQueue = DispatchQueue(label: "ephedrine.lowpower")

/// Whether the sudoers rule allows switching Low Power Mode, by writing the
/// battery profile's current value back (a no-op). nil when not on battery:
/// isLowPowerModeEnabled is then another profile's value, and writing that to
/// the battery's could change it. `sudo -n -l <command>` changes nothing but
/// says yes for any admin, whose `%admin ALL` rule allows it with a password.
func lowPowerAllowed() -> Bool? {
    guard onInternalBattery() else { return nil }
    return setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
}

enum LowPowerResult { case done, skipped, failed }

/// Runs on lowPowerQueue. The marker changes here, in order with every other
/// write, so an off queued behind this one sees whether it's still ours.
func applyLowPower(_ on: Bool) -> LowPowerResult {
    if on {
        // Checked again right before the write: switched on meanwhile (by its
        // owner) or plugged in, it isn't ours to switch on.
        if ProcessInfo.processInfo.isLowPowerModeEnabled || !onInternalBattery() {
            try? fm.removeItem(atPath: lowPowerMarkerPath)
            return .skipped
        }
        guard setLowPowerMode(true) else { try? fm.removeItem(atPath: lowPowerMarkerPath); return .failed }
        return .done
    }
    guard fm.fileExists(atPath: lowPowerMarkerPath) else { return .skipped }   // not ours, or already undone
    guard setLowPowerMode(false) else { return .failed }
    try? fm.removeItem(atPath: lowPowerMarkerPath)
    return .done
}

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
/// new Ephedrine has taken over), it un-pauses apps, turns disablesleep and
/// our Low Power Mode back off, and unmutes the sound the lid-shut hold muted.
final class LidWatchdog {
    private var proc: Process?
    /// `mutingPath`: the marker that exists while the hold has the default output muted.
    func start(mutingPath: String) {
        if proc?.isRunning == true { return }
        let marker = shellQuoted(lidMarkerPath)
        let pids = shellQuoted(pausedPidsPath)
        let lowPower = shellQuoted(lowPowerMarkerPath)
        let muting = shellQuoted(mutingPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 5; done
            /usr/bin/pgrep -xq Ephedrine && exit 0
            [ -s \(pids) ] && /bin/kill -CONT $(/bin/cat \(pids)) 2>/dev/null
            [ -f \(marker) ] && /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 && /bin/rm -f \(marker)
            [ -f \(lowPower) ] && /usr/bin/sudo -n /usr/bin/pmset -b lowpowermode 0 && /bin/rm -f \(lowPower)
            [ -f \(muting) ] && /usr/bin/osascript -e 'set volume without output muted' && /bin/rm -f \(muting)
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

    /// Called from evaluate() every tick. `battery`: the percent after
    /// BatteryReadMisses, so a battery that can't be read stops it too.
    func updateLidMode(claudeBusy: Bool, battery: Int?) {
        let closed = lidClosedNow()
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
            case .lowBattery: why = battery == 0 && batteryPercent() == nil ? "The battery level can't be read" : "Battery is at \(battery ?? 0)%"
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

    /// The watchdog undoes disablesleep and Low Power Mode, un-pauses apps
    /// and unmutes if Ephedrine dies. It runs while any of them is ours, not
    /// only in lid mode. Its unmute is blind (it hits whatever output is the
    /// default), so it's armed by the `muting` marker, which exists only while
    /// the hold has muted the default output. Entries waiting for a device to
    /// come back are left to the launch restore and evaluate's retry.
    func updateWatchdog() {
        let pids = (try? String(contentsOfFile: pausedPidsPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fm.fileExists(atPath: lidMarkerPath) || fm.fileExists(atPath: lowPowerMarkerPath) || !pids.isEmpty
            || muteWatchdogArmed() {
            lidWatchdog.start(mutingPath: mutingMarkerPath)
        } else {
            lidWatchdog.stop()
        }
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
                    if lidClosedNow() && !externalDisplayActive() {
                        logLine("lid is shut, sleeping now")
                        self.doSleep()
                    }
                }
            }
        }
    }

    /// The lid-shut hold: from lidShutHold starting to it ending, for any
    /// reason (the lid opening, lid mode ending, an external display coming
    /// on). It mutes, turns the keyboard light off and runs the Docker rule at
    /// its start, and undoes all of it at its end. Pausing other apps (same
    /// rules as "I'm leaving") and the Docker rule have their own switches:
    /// turned off mid-hold, what they paused resumes. The built-in screen is
    /// already off with the lid shut, so there's nothing to dim.
    func updateLidPause(closed: Bool) {
        let hold = lidShutHold(closed: closed)
        if lidHoldActive && !hold { endLidHold(closed: closed) }
        if dockerPaused && !settings.lidDockerRule && !awayMode { resumeDocker("Docker rule turned off") }
        if lidPaused && (!closed || !settings.lidPauseApps) {   // the lid open: only if the hold's end missed it
            let n = pausedAppCount
            resumeApps(); clearAwayState(); lidPaused = false
            logLine(closed ? "lid pause turned off, resumed \(n) apps" : "lid opened, resumed \(n) apps")
        }
        if !lidHoldActive && hold { startLidHold() }
        guard hold, settings.lidPauseApps, !lidPaused, !awayMode else { return }
        suspendApps(); persistAwayState(); lidPaused = true
        logLine("lid shut, paused \(pausedAppCount) apps\(pausedList)")
    }

    private func startLidHold() {
        lidHoldActive = true
        lidHoldGeneration += 1
        if settings.lidMute {
            lidWatchdog.start(mutingPath: mutingMarkerPath)   // before muting, so a crash right after still unmutes
            if let o = muteDefaultOutput() { logLine("lid shut, muted \(o.name ?? o.uid)") }
            updateWatchdog()
        }
        if settings.lidKeyboardOff {
            if let why = KeyboardBacklight.shared.refusal {
                logLine("lid shut, left the keyboard light alone: \(why)")
            } else {
                let n = KeyboardBacklight.shared.dim().count
                if n > 0 { logLine("lid shut, turned the keyboard light off" + (n > 1 ? " on \(n) keyboards" : "")) }
            }
        }
        // "I'm leaving" owns the paused list while it's on.
        if settings.lidDockerRule && !awayMode && !dockerPaused { pauseDockerIfIdle(generation: lidHoldGeneration) }
    }

    /// Everything the hold did comes undone, in one place: the sound and the
    /// keyboard light, and what it paused (apps and Docker).
    private func endLidHold(closed: Bool) {
        lidHoldActive = false
        lidHoldGeneration += 1   // a Docker check still running belongs to a hold that's over
        restoreLidExtras(endingHold: true)
        let why = closed ? "lid-closed hold ended" : "lid opened"
        if lidPaused {
            let n = pausedAppCount
            resumeApps(); clearAwayState(); lidPaused = false
            logLine("\(why), resumed \(n) apps")
        } else if dockerPaused && !awayMode {
            resumeDocker(why)
        }
    }

    /// Unmute what the hold muted (muteRestorePlan) and put the keyboard
    /// light back (backlightRestorePlan), from their files. Also at launch,
    /// sleep and quit, and every 30 s while something waits. `endingHold`
    /// (the hold's end, quit): the watchdog's unmute is disarmed whatever is
    /// left; a device that's gone is left to the launch restore and the retry.
    func restoreLidExtras(endingHold: Bool = false) {
        if mutedOutputsPending() { restoreOutputs() }
        if endingHold { disarmMuteWatchdog() }
        if fm.fileExists(atPath: keyboardBacklightPath), KeyboardBacklight.shared.restoreSaved() > 0 {
            logLine("turned the keyboard light back on")
        }
        updateWatchdog()
    }

    /// The lid is shut and our lid mode (not a by-hand disablesleep) keeps the
    /// Mac awake, with no external display (a desk setup is still in use).
    func lidShutHold(closed: Bool) -> Bool {
        closed && lidActive && fm.fileExists(atPath: lidMarkerPath) && !externalDisplayActive()
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
        releaseLowPower("sleeping")
        // Before the marker check: flipLid(false) removes the marker and then
        // sleeps. The hold ends here, not on a next tick that may never come
        // before sleep: a check-in on the first DarkWake tick would find the
        // hold already true again, so no new start would mute.
        if lidHoldActive { endLidHold(closed: lidClosedNow()) } else { restoreLidExtras() }
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

    // MARK: Low Power Mode

    /// Lid setup from before Low Power Mode was in the rule: the menu and the
    /// Lid pane offer to re-run it.
    var lowPowerSetupNeeded: Bool { lidSetupOK && lowPowerRuleOK == false }

    /// Called from evaluate() every tick, once keep-awake is decided.
    func updateLowPower(holding: Bool, percent: Int?) {
        let now = Date()
        let settled = batterySettle.step(onBattery: onInternalBattery(), now: now)
        if !lidSetupOK { lowPowerRuleOK = nil }   // asked again once setup is back
        let ours = fm.fileExists(atPath: lowPowerMarkerPath)
        if !ours { lowPowerOffFailures = 0; lowPowerOnAt = nil }
        let modeOn = ProcessInfo.processInfo.isLowPowerModeEnabled
        // Switched off by hand while ours: it's the owner's now. Drop the marker
        // without writing, so no later "off" can undo an "on" they make.
        let onSince = lowPowerOnAt ?? ((try? fm.attributesOfItem(atPath: lowPowerMarkerPath))?[.modificationDate] as? Date) ?? now
        if lowPowerOwnership.step(ours: ours, settled: settled, inFlight: lowPowerApplying || lowPowerChecking || lidApplying,
                                  sinceOurSwitchOn: now.timeIntervalSince(onSince), modeOn: modeOn) {
            try? fm.removeItem(atPath: lowPowerMarkerPath)
            lowPowerOnAt = nil
            updateWatchdog()
            logLine("Low Power Mode: turned off by hand, no longer Ephedrine's")
            return
        }
        let found = lowPowerCause(holding: holding, lidHold: lidShutHold(closed: lidClosedNow()),
                                  onLidShut: settings.lowPowerOnLidShut, onBattery: !onACPower(), percent: percent,
                                  floor: settings.lowPowerFloor, thermal: ProcessInfo.processInfo.thermalState)
        // Heat and battery are held 5 min while ours, and while the owner has
        // taken over (so a heat cause that flickers doesn't end the takeover
        // early). The lid isn't: opening it ends Low Power Mode at once.
        let cause = lowPowerHold.step(cause: found, ours: ours || lowPowerOwnership.ownerTookOver, now: now)
        lowPowerOwnership.noteCause(cause)
        guard !lidApplying else { return }        // a lid flip or a setup removal is running
        checkLowPowerRule(settled: settled)
        guard !lowPowerApplying, !lowPowerChecking, now >= lowPowerRetryAfter else { return }
        switch lowPowerStep(cause: cause, modeOn: modeOn, ours: ours) {
        case .turnOn(let c)?:
            // Only where isLowPowerModeEnabled is the battery profile that `-b`
            // writes, once the rule is known to allow it, and not against an
            // owner who switched ours off during this cause.
            guard settled, lowPowerRuleOK == true, !lowPowerOwnership.ownerTookOver else { return }
            flipLowPower(true, cause: c)
        case .turnOff?:
            flipLowPower(false, cause: nil)   // also after a crash: the marker is still there at launch
        case nil:
            break
        }
    }

    /// Asks whether the rule allows Low Power Mode: at launch, after setup, and
    /// while it doesn't after 1, 5, then every 15 minutes (sudo logs each
    /// refusal). Only on battery (see lowPowerAllowed).
    private func checkLowPowerRule(settled: Bool) {
        guard lidSetupOK, settled, !lowPowerChecking, !lowPowerApplying else { return }
        guard lowPowerRuleOK == nil || (lowPowerRuleOK == false
            && Date().timeIntervalSince(lowPowerCheckedAt) >= lowPowerRecheckDelay(failures: lowPowerCheckFailures)) else { return }
        lowPowerChecking = true
        lowPowerQueue.async { [weak self] in
            let ok = lowPowerAllowed()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lowPowerChecking = false
                self.lowPowerCheckedAt = Date()
                // Plugged in meanwhile, or setup changing: ask again later.
                guard let ok = ok, self.lidSetupOK, !self.lidApplying else { return }
                if ok != self.lowPowerRuleOK {
                    logLine(ok ? "Low Power Mode: lid setup allows switching it"
                               : "Low Power Mode: lid setup predates it, re-run lid setup to allow it")
                }
                self.lowPowerRuleOK = ok
                self.lowPowerCheckFailures = ok ? 0 : self.lowPowerCheckFailures + 1
            }
        }
    }

    private func flipLowPower(_ on: Bool, cause: LowPowerCause?) {
        let was = (try? String(contentsOfFile: lowPowerMarkerPath, encoding: .utf8)).flatMap(LowPowerCause.init(rawValue:))
        if on {
            // Before the switch, so a crash mid-flip is still cleaned up. No
            // record, no switch: nothing could turn it off again.
            guard fm.createFile(atPath: lowPowerMarkerPath, contents: Data((cause?.rawValue ?? "").utf8)) else {
                logLine("Low Power Mode: couldn't write \(lowPowerMarkerPath), leaving it off")
                lowPowerRetryAfter = Date().addingTimeInterval(60)
                return
            }
            updateWatchdog()
        }
        lowPowerApplying = true
        lowPowerGeneration += 1
        let generation = lowPowerGeneration
        lowPowerQueue.async { [weak self] in
            let result = applyLowPower(on)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lowPowerApplying = false
                self.updateWatchdog()
                // A synchronous off (sleep, quit, removing setup) ran after this one and settled it.
                guard generation == self.lowPowerGeneration else { return }
                switch result {
                case .done:
                    logLine(on ? "Low Power Mode ON (\(cause?.rawValue ?? "?"))"
                               : "Low Power Mode OFF" + (was.map { " (was on for \($0.rawValue))" } ?? ""))
                    if on { self.lowPowerOnAt = Date() } else { self.lowPowerOnAt = nil; self.lowPowerOffFailures = 0 }
                case .skipped:
                    if on { logLine("Low Power Mode: already on or plugged in, left it alone") }
                case .failed:
                    if !on { self.lowPowerOffFailures += 1 }   // two in a row: menuWarnings says it's stuck
                    logLine("Low Power Mode: `sudo pmset` failed, retrying in 1 min")
                    self.lowPowerRetryAfter = Date().addingTimeInterval(60)
                    self.lidSetupOK = lidSetupInstalled()
                    if on { self.lowPowerRuleOK = nil }   // ask the rule again before the next try
                }
            }
        }
    }

    /// Sleep and quit: switch our Low Power Mode off now, queued behind any
    /// flip still running. The marker is written before an "on" is queued, so
    /// without it nothing of ours is on or on its way.
    func releaseLowPower(_ why: String) {
        guard fm.fileExists(atPath: lowPowerMarkerPath) else { return }
        lowPowerGeneration += 1   // supersedes any flip still finishing
        let result = lowPowerQueue.sync { applyLowPower(false) }
        updateWatchdog()
        switch result {
        case .done:    logLine("Low Power Mode OFF (\(why))"); lowPowerOnAt = nil; lowPowerOffFailures = 0
        case .failed:  logLine("Low Power Mode: couldn't switch it off (\(why)), the watchdog retries"); lowPowerOffFailures += 1
        case .skipped: break
        }
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
                self.lowPowerRuleOK = nil   // ask the new rule about Low Power Mode, now
                self.lowPowerCheckFailures = 0
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
        lidApplying = true   // also holds Low Power Mode changes and rule checks (updateLowPower)
        lowPowerRuleOK = nil
        lowPowerGeneration += 1   // supersedes any flip still finishing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Off in order with any flip still running, but ask for the password
            // OFF the switch queue: quit and doSleep() wait on lidSwitch, and a
            // dialog left open must never block them. Low Power Mode first: once
            // the rule is gone nothing can switch it off.
            let lowPower = lowPowerQueue.sync { applyLowPower(false) }
            if fm.fileExists(atPath: lidMarkerPath) { lidSwitch.setSync(false) }
            let err = uninstallLidSetup()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lidApplying = false
                if lowPower == .done { logLine("Low Power Mode OFF (removing lid setup)") }
                if lowPower == .failed { logLine("Low Power Mode: couldn't switch it off before removing lid setup"); self.lowPowerOffFailures += 1 }
                self.updateWatchdog()
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
