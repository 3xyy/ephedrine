import Cocoa
import ServiceManagement
import UserNotifications
import CoreGraphics
import EphedrineCore

// ───────────────────────────── Config ─────────────────────────────

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let stateDir = "\(home)/.claude/ephedrine/sessions"
let logPath  = "\(home)/.claude/ephedrine/ephedrine.log"
let awayStatePath = "\(home)/.claude/ephedrine/away-state.json"
let pausedPidsPath = "\(home)/.claude/ephedrine/paused-pids"   // plain pid list, for the lid watchdog's shell

let leaseFallback: TimeInterval = 300   // used only if a marker file can't be parsed
let tickInterval: TimeInterval = 3
let preSleepWarning: TimeInterval = 10  // grace given after the notification before sleeping
let usageRefresh: TimeInterval = 180    // how often to refetch Claude usage
let updateCheckEvery: TimeInterval = 6 * 3600
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

// ───────────────────────────── Controller ─────────────────────────────

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let awake = AwakeAssertions()
    var tick: Timer?

    // persisted preferences (saved to UserDefaults as they change)
    let settings = AppSettings(defaults: .standard)
    var autoContinue: Bool { settings.autoContinueMode != .off }
    /// Something reads Terminal and cmux every few ticks: retries, limit waits or the busy check.
    var terminalScanOn: Bool { autoContinue || settings.autoResumeLimit || settings.keepAwakeClaudeWorking }

    var manualKeepAwake = false
    var claudeWorkingCached = false
    var limitResumeAts: [Date] = []                 // scheduled usage-limit resumes (from the terminal scan)
    /// A usage-limit wait is keeping the Mac awake (on battery only within an hour of the reset).
    var limitWaitPending: Bool { limitWaitHolds(resumeAts: limitResumeAts, now: Date(), onBattery: !onACPower()) }
    var retryPending = false                        // an auto-continue retry is scheduled

    // lid-closed mode (LidMode.swift)
    var lidSetupOK = false                          // sudoers rule installed
    var lidState = LidState()
    var lidActive = false                           // pmset disablesleep is on (by anyone)
    var lidApplying = false
    var lidRetryAfter = Date.distantPast
    var lidGuardNotedAt = Date.distantPast
    var lidPaused = false
    var lidHoldActive = false                       // the lid-shut hold is on (updateLidPause): muted, keys dark, paused
    var lidHoldGeneration = 0                       // bumped at each hold start and end (a Docker check from an older hold is dropped)
    var dockerPausedProcesses: [PausedProcess] = [] // what the Docker rule stopped (also in pausedProcesses), roots first
    var dockerPaused: Bool { !dockerPausedProcesses.isEmpty }
    var lastExtrasRetry = Date.distantPast          // last retry of outputs that weren't connected when the hold ended
    var lidLockedThisClose = false
    var lidFlipGeneration = 0                       // newest lid on/off request (stale completions are ignored)
    var terminalScanError = ""                      // main-thread copy of the last scan's osascript error
    var lidLastClosed = false
    var lidSleepWatch = LidSleepWatch()
    let lidWatchdog = LidWatchdog()
    var checkIn = RemoteCheckIn()                   // Remote Control check-ins from lid-shut naps
    var checkInWakeID = IOPMAssertionID(0)          // the "user is active" request that makes a nap a full wake
    var checkInActivity: NSObjectProtocol?          // keeps App Nap from slowing the tick while check-ins are on
    var batteryStop = BatteryStop()                 // on battery at the floor: keep nothing awake until plugged in
    var batteryPause = BatteryPause()               // at the floor and away: Claude Code paused, the Mac asleep
    var claudePausedProcesses: [PausedProcess] = [] // what the battery pause stopped (also in pausedProcesses)
    var claudeResumedAt = Date.distantPast          // a "went to sleep" error after this was our doing (ScanFlags)
    var batteryMisses = BatteryReadMisses()         // a battery that can't be read counts as at the floor
    var heatStop = HeatStop()                       // critical heat: keep nothing awake until it cools to serious
    var heatNotedAt = Date.distantPast
    var heatLoggedAt = Date.distantPast             // the stop and cool-down log lines, at most every 30 min
    var heatEpisodeLogged = false                   // this heat stop was logged, so its cool-down is too
    // Low Power Mode (LidMode.swift)
    var batterySettle = BatterySettle()             // on battery long enough to read the battery profile
    var lowPowerApplying = false
    var lowPowerGeneration = 0                      // newest Low Power Mode request (stale completions are ignored)
    var lowPowerRetryAfter = Date.distantPast
    var lowPowerRuleOK: Bool?                       // the sudoers rule allows Low Power Mode; nil = not asked yet
    var lidRuleStamp: String?                       // lid-rule-version as last read (refreshLidRuleStamp), not read per menu open
    var lowPowerChecking = false
    var lowPowerCheckedAt = Date.distantPast
    var lowPowerCheckFailures = 0                   // rule checks that said no in a row (lowPowerRecheckDelay)
    var lowPowerHold = LowPowerHold()               // keeps a cause 5 min, so cooling doesn't flip it off and on
    var lowPowerOwnership = LowPowerOwnership()     // notices the owner switching ours off by hand
    var lowPowerOnAt: Date?                         // when our last switch-on finished
    var lowPowerOffFailures = 0                     // switch-offs that failed in a row while the marker exists
    var awaySleep = AwaySleep()                     // "I'm leaving" sleeps once Claude is done
    var awayNeededCached = false                    // last tick: something still needed the Mac during "I'm leaving"
    var lastAwayCheck = Date()                      // a long gap since means the Mac was asleep
    var latestRelease: LatestRelease?               // set only when it's newer than this version
    var lastUpdateCheck: Date?
    var extraActiveLabel: String?                   // which "also stay awake for" detector is holding it
    var sigtermSource: DispatchSourceSignal?

    // continueQueue-confined state (only touched on continueQueue)
    var continueStates: [String: AutoContinueState] = [:]
    var limitEpisodes: [String: LimitEpisode] = [:]
    var lastTabCount = -1
    var lastWorkingSeen = false
    var terminalTabsSeen = -1                 // main-thread copy of the last scan's tab count (-1 = not yet)
    var errorSkipLogged: [String: String] = [:]   // tab key → last logged reason (continueQueue only)
    var cmuxScan = CmuxScanState()                 // cmux's per-scan bookkeeping (continueQueue only; Cmux.swift)
    var cmuxSeen = CmuxSeen()                      // what Settings shows for cmux (main thread)

    var scanning = false
    var tickCount = 0
    // Sleep tracking. Code also runs during lid-closed "DarkWake" maintenance
    // wakes, which must never type or enable lid-closed mode. willSleep/didWake
    // are only a fallback: didWake has been seen firing inside a DarkWake, so
    // `fullyAwake` (kernel capabilities, read each tick) is what gates both.
    var systemSleeping = false
    var lastFullWake = Date.distantPast { didSet { wakeGate.update(fullyAwake: fullyAwake, lastFullWake: lastFullWake) } }
    var lastWillSleep = Date.distantPast   // a sleep can take ~30s to land after willSleep
    var fullyAwake = true {                // from the kernel's capabilities each tick (see systemFullyAwake)
        didSet { wakeGate.update(fullyAwake: fullyAwake, lastFullWake: lastFullWake) }
    }
    let wakeGate = WakeGate()              // the two above, for the scan queue's last check before typing
    let postWakeQuiet: TimeInterval = 60   // let the network come back before typing
    let continueQueue = DispatchQueue(label: "ephedrine.autocontinue")
    let networkWatch = NetworkWatch()
    var outage = OutageTracker()           // main thread
    // iPhone hotspot join (Hotspot.swift), main thread except the attempt itself, which runs on hotspotQueue
    var hotspotGate = HotspotJoinGate()
    let hotspotQueue = DispatchQueue(label: "ephedrine.hotspot")
    let location = LocationAccess()
    var hotspotJoining = false
    var hotspotNotified = false            // the unreadable-password notification went out this outage
    var hotspotNotedOff = false            // the "Wi-Fi is switched off" line was logged this outage
    var hotspotNoted = false               // the "Location isn't allowed" line was logged this outage
    var hotspotPassword = HotspotPasswordState.ok
    // browser throttle warning (BrowserRelaunch.swift), main thread except browserQueue's ps runs
    let browserQueue = DispatchQueue(label: "ephedrine.browsers")
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String: String] = [:]   // bundle id → what went wrong
    var browserScanning = false
    var browserScanGeneration = 0                  // bumped to drop a scan that began before a change
    var browserRelaunching = Set<String>()         // bundle ids with a relaunch in progress

    /// Settings snapshot handed to the background terminal scan, so the scan
    /// never reads main-thread-mutated properties across threads.
    struct ScanFlags {
        let mode: AutoContinueMode
        let resumeLimit: Bool
        let watchWorking: Bool
        let canType: Bool   // false while asleep / in a dark wake / just after waking
        let cmuxCLI: String?   // the running cmux's CLI, nil when cmux isn't running
        let afterOurSleep: Bool   // a battery pause slept the Mac and resumed Claude in the last 10 min
    }

    let detectors: [Detector] = [
        Detector(key: "terminal", label: "A Terminal command is running",
                 tip: "Any foreground command in a terminal: builds, scripts, servers. An idle prompt doesn't count.",
                 check: { ps in interactiveShellRunningCommand(psLines: ps.lines("tty=,pgid=,tpgid=,command=")) }),
        Detector(key: "monitor", label: "A monitor is open (top, tail -f, watch…)",
                 tip: "top, htop, btop, tail -f, watch, or log stream.",
                 check: { ps in monitorRunning(commLines: ps.lines("comm="), commandLines: ps.lines("command=")) }),
        Detector(key: "ssh", label: "An SSH session is open",
                 tip: "An outgoing ssh or mosh connection.",
                 check: { ps in processCommMatches(commLines: ps.lines("comm="), names: ["ssh", "mosh-client"]) }),
        Detector(key: "transfer", label: "A download or file transfer is running",
                 tip: "curl, wget, rsync, scp, sftp, or aria2c.",
                 check: { ps in processCommMatches(commLines: ps.lines("comm="),
                                                   names: ["curl", "wget", "rsync", "scp", "sftp", "ftp", "aria2c"]) }),
    ]

    // transient state
    var wasBlocked = false
    var extraActiveCached = false
    var extraActiveHolding = false                  // a detector is active and still within its hour on battery
    var detectorCap = DetectorBatteryCap()
    var detectorCapLogged = false
    var detectorScanInFlight = false
    var armed = false
    var awayMode = false
    var awayReturn: AwayReturn?
    var lastAwayReturnByInput: Date?
    var pausedProcesses: [PausedProcess] = []   // what suspendApps stopped, apps before their helpers
    var suspendedPids: [pid_t] { pausedProcesses.map(\.pid) }   // for the watchdog's paused-pids file
    var pausedNames: [String] = []   // one per paused app
    var savedBrightness: Float = -1
    var awayTimer: Timer?
    var idleSince = Date()
    var keepAwakeUntil: Date?          // timed "keep awake for N"
    let durationPanel = DurationPanelController()
    var pendingSleepAt: Date?          // set when the 10s pre-sleep warning is showing
    var warnedNoNotifications = false

    // cached pmset value (a subprocess, so it is refreshed off-main at most once a minute)
    var displaySleepMins = 0
    var displaySleepFetchedAt: Date?
    var displaySleepFetching = false

    // Claude usage (fetched from Anthropic with the keychain OAuth token)
    var usageLimits: [UsageLimit] = []
    var usageAlerts = UsageAlertTracker()
    var usageError = false
    var usageFetching = false
    var lastUsageFetch: Date?
    var usageView: UsageView?
    let settingsWindow = SettingsWindowController()
    let setupWindow = SetupWindowController()
    var iconActive = false                          // last `active` refreshIcon saw (the status card picks its glyph from it)
    var awakeIcons: [MenuBarIconStyle: NSImage] = [:]   // made once per style; refreshIcon runs every tick

    let graceChoices: [(secs: Int, long: String)] = [
        (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes")
    ]

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        tightenStateFolder()
        settings.onChange = { [weak self] key in self?.settingChanged(key) }
        installMainMenu()
        recoverFromInterruptedAway()
        // A mute or a dark keyboard a crash left behind, while the Mac can be
        // in use (lid open, or a desk setup). With the lid shut and nothing
        // attached, the hold or the lid opening restores them; the watchdog
        // covers a crash till then.
        if !lidClosedNow() || externalDisplayActive() { restoreLidExtras() }
        updateWatchdog()
        if settings.appNapOffForAgents { applyAppNapOverride() } else { restoreAppNapOverride() }   // the restore finishes one a crash cut short
        // `pkill`/`kill` (build.sh, logout scripts) → a normal quit, so
        // applicationWillTerminate un-pauses apps and releases lid-closed mode.
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { NSApp.terminate(nil) }
        sigtermSource?.resume()
        lidSetupOK = lidSetupInstalled()
        refreshLidRuleStamp()
        updateCheckInActivity()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if settings.setupDone {   // otherwise the setup screen asks, when you click Allow
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if !granted { logLine("notifications are off, so the pre-sleep warning won't show") }
            }
        }
        let stay = UNNotificationAction(identifier: "STAY_AWAKE", title: "Stay awake", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "KA_SLEEP", actions: [stay], intentIdentifiers: [], options: [])
        ])

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)

        // .common: a default-mode timer stops while Ephedrine's menu is open, and
        // a menu left open would freeze every decision, the battery limit included.
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
        let bt = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.scanBrowsers() }
        RunLoop.main.add(bt, forMode: .common)
        scanBrowsers()
        logLine("Ephedrine started")
        networkWatch.onChange = { [weak self] ok in self?.networkChanged(ok) }
        networkWatch.start()
        refreshHotspot()   // an unreadable password shows its warning now, not at the next outage
        refreshDisplaySleepIfStale()
        setupWindow.onClose = { [weak self] in self?.settings.setupDone = true }
        if settings.setupDone { fetchUsage() } else { openSetup() }
        evaluate()
    }

    func applicationWillTerminate(_ note: Notification) {
        awake.apply(system: false, display: false)
        resumeClaude("quitting")   // resumeApps leaves Claude's processes alone
        if awayMode || lidPaused || !pausedProcesses.isEmpty { resumeApps(); restoreBrightness() }   // never leave apps (or Docker) frozen
        clearAwayState()
        restoreLidExtras(endingHold: true)   // and disarm the watchdog's unmute: a waiting device isn't its business
        releaseLowPower("quitting")          // before the lid: with it shut, the Mac can sleep the moment sleep is allowed
        releaseLidOnQuit()
        logLine("Ephedrine quit")
        flushLog()
    }
    @objc func didWake() {
        systemSleeping = false; lastFullWake = Date()
        armed = false; cancelPendingSleep(); logLine("system woke")
    }
    @objc func willSleep() { systemSleeping = true; lastWillSleep = Date(); logLine("system going to sleep") }

    // MARK: core loop

    func effectiveGraceSeconds() -> Double {
        if settings.graceUseSystem {
            return displaySleepMins > 0 ? Double(displaySleepMins) * 60 : settings.gracePeriod
        }
        return settings.gracePeriod
    }

    func autoSleepAllowed() -> Bool {
        switch settings.powerMode {
        case .always:      return true
        case .batteryOnly: return !onACPower()
        case .acOnly:      return onACPower()
        }
    }

    /// Seconds of grace left before the sleep sequence starts.
    func graceRemaining() -> Int {
        (settings.finishMode == .alwaysSleep)
            ? Int(effectiveGraceSeconds() - Date().timeIntervalSince(idleSince))
            : Int(effectiveGraceSeconds() - hidIdleSeconds())
    }

    /// Drives the idle countdown → pre-sleep warning → sleep sequence.
    /// Returns the menu-bar title to show, or nil when auto-sleep is off.
    func autoSleepTitle() -> String? {
        guard autoSleepAllowed() && settings.finishMode != .stayNormal else {
            cancelPendingSleep(); return nil
        }
        let left = graceRemaining()
        if left > 0 {
            cancelPendingSleep()
            return fmtCountdown(left)
        }
        if pendingSleepAt == nil {
            pendingSleepAt = Date().addingTimeInterval(preSleepWarning)
            notifyPreSleep()
        }
        if Date() >= pendingSleepAt! { doSleep(); return "" }
        return "\(max(0, Int(pendingSleepAt!.timeIntervalSinceNow)))s"
    }

    func refreshDisplaySleepIfStale() {
        guard !displaySleepFetching else { return }
        if let t = displaySleepFetchedAt, Date().timeIntervalSince(t) < 60 { return }
        displaySleepFetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let v = systemDisplaySleepMinutes()
            DispatchQueue.main.async {
                self?.displaySleepMins = v
                self?.displaySleepFetchedAt = Date()
                self?.displaySleepFetching = false
            }
        }
    }

    func evaluate() {
        refreshDisplaySleepIfStale()

        let full = systemFullyAwake(fallback: !systemSleeping)
        if full && !fullyAwake { lastFullWake = Date() }
        fullyAwake = full

        if let until = keepAwakeUntil, Date() >= until {
            keepAwakeUntil = nil; logLine("timed keep-awake expired")
            stayOverNotify()
        }

        // 2026-10-13: "I'm leaving" held the Mac awake on battery from 80% at
        // 1am until it died; only lid mode had a battery limit.
        let reading = batteryPercent()
        let charge = batteryMisses.step(onBattery: !onACPower(), hasBattery: hasInternalBattery(), percent: reading)
        if batteryStop.step(onBattery: !onACPower(), percent: charge,
                            floor: awakeBatteryFloor(settings.batteryFloor)) {
            let pct = charge ?? 0
            let wasHolding = awake.systemOn || awayMode || lidActive
            manualKeepAwake = false; keepAwakeUntil = nil; lidState.session = nil
            if awakeBatteryFloor(settings.batteryFloor) >= lidOnlyPluggedIn {
                logLine("on battery: keeping the Mac awake only on the charger")
                if wasHolding { batteryNotify("On battery", "Ephedrine only keeps the Mac awake on the charger, so it can sleep now.") }
            } else if reading == nil {
                logLine("battery level unreadable twice in a row, counting it as at the limit: no longer keeping the Mac awake until it's plugged in")
                if wasHolding { batteryNotify("Battery level unknown", "Ephedrine can't read the battery, so it stopped keeping the Mac awake. Plug it in and it carries on.") }
            } else {
                logLine("battery at \(pct)%, no longer keeping the Mac awake until it's plugged in")
                if wasHolding { batteryNotify("Battery at \(pct)%", "Ephedrine stopped keeping the Mac awake, so it can sleep. Plug it in and it carries on.") }
            }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let wasHot = heatStop.stopped
        if heatStop.step(thermal) {
            let wasHolding = awake.systemOn || awayMode || lidActive
            manualKeepAwake = false; keepAwakeUntil = nil; lidState.session = nil
            // It can hover at the edge of critical, so log and notify at most every 30 min.
            heatEpisodeLogged = Date().timeIntervalSince(heatLoggedAt) > 1800
            if heatEpisodeLogged {
                heatLoggedAt = Date()
                logLine("too hot (critical), no longer keeping the Mac awake")
            }
            if wasHolding && Date().timeIntervalSince(heatNotedAt) > 1800 {
                heatNotedAt = Date()
                heatNotify("Your Mac is very hot", "Ephedrine stopped keeping it awake so it can cool down and sleep.")
            }
        } else if wasHot && !heatStop.stopped && heatEpisodeLogged {
            logLine("cooled down (\(thermalStateText(thermal).lowercased())), keeping the Mac awake again when needed")
        }
        let mustStop = batteryStop.stopped || heatStop.stopped   // keep nothing awake: battery at its limit, or critical heat

        let busy = activeSessionCount() > 0
        let manualActive = !mustStop && (manualKeepAwake || keepAwakeUntil != nil)
        var extraActive = false
        if settings.enabled && !busy && !manualActive && !settings.detectors.isEmpty {
            // Detectors spawn `ps`, so they run off-main; evaluate uses the
            // result of the previous scan (≤1 tick stale; the lease-based
            // logic has minutes of slack). Not rescanned in a nap: a command
            // seen for one nap flipped "work finished" and the countdown.
            extraActive = detectorCap.allows(active: extraActiveCached, onBattery: !onACPower(), now: Date())
            if extraActiveCached && !extraActive && !detectorCapLogged {
                detectorCapLogged = true
                logLine("on battery: \(extraActiveLabel ?? "a background task") kept the Mac awake for an hour, letting it sleep")
            }
            if extraActive || !extraActiveCached { detectorCapLogged = false }
            if !detectorScanInFlight && fullyAwake {
                detectorScanInFlight = true
                let keys = settings.detectors
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let ps = PSCache()   // one ps spawn per format, shared by all detectors
                    let hit = self?.detectors.first { keys.contains($0.key) && $0.check(ps) }?.label
                    DispatchQueue.main.async {
                        self?.extraActiveCached = hit != nil
                        self?.extraActiveLabel = hit
                        self?.detectorScanInFlight = false
                    }
                }
            }
        } else {
            extraActiveCached = false
            extraActiveLabel = nil
            _ = detectorCap.allows(active: false, onBattery: false, now: Date())   // a fresh hour next time
        }
        extraActiveHolding = extraActive
        let claudeWorkingNow = settings.keepAwakeClaudeWorking && claudeWorkingCached
        let limitWaitNow = settings.autoResumeLimit && limitWaitPending
        let lidShutAlone = lidClosedNow() && !externalDisplayActive()
        let idle = hidIdleSeconds()
        // Lid mode, unlike keep-awake, holds a usage-limit wait whenever the lid
        // could close on it (limitWaitHoldsLid).
        let limitWaitLid = settings.autoResumeLimit && limitWaitHoldsLid(
            resumeAts: limitResumeAts, now: Date(), onBattery: !onACPower(), lidShut: lidShutAlone, userIdle: idle)
        let blocked = busy || extraActive || claudeWorkingNow || limitWaitNow
        let claudeNeeds = busy || claudeWorkingNow || limitWaitLid || (autoContinue && retryPending)
        // Before lid mode: at the floor with the lid shut, Claude is paused before the Mac sleeps.
        stepBatteryPause(lidShutAlone: lidShutAlone, idle: idle, claudeBusy: busy || claudeWorkingNow, percent: charge)
        updateLidMode(claudeBusy: settings.enabled && claudeNeeds, battery: charge)
        // An output that wasn't connected when the hold ended is unmuted once
        // it's back; a launch with the lid shut leaves the keyboard light to here too.
        // Never during the hold, and only while the Mac can be in use.
        if !lidHoldActive && Date().timeIntervalSince(lastExtrasRetry) >= 30
            && (mutedOutputsPending() || fm.fileExists(atPath: keyboardBacklightPath))
            && (!lidClosedNow() || externalDisplayActive()) {
            lastExtrasRetry = Date()
            restoreLidExtras()
        }

        if blocked && !wasBlocked { armed = false; cancelPendingSleep() }
        if !blocked && wasBlocked { armed = true; idleSince = Date(); cancelPendingSleep(); logLine("work finished, sleep countdown armed") }
        wasBlocked = blocked

        // The master switch gates the automatic behavior only; an explicit
        // "Stay awake" / "I'm leaving" always does what it says. "I'm leaving"
        // holds the Mac only while Claude needs it (AwaySleep below).
        let keepAwake = !mustStop && (((settings.enabled || awayMode) && blocked) || manualActive)
        if keepAwake {
            // Screen may sleep for pure background reasons: detector activity or a
            // session-limit wait (which can be hours), but not while Claude is
            // actively generating or during a manual override. "I'm leaving"
            // has already blacked it out, so let it sleep and save the power.
            // With the lid shut the screen is dark anyway, but holding the display
            // awake kept it powered (2026-10-12: on for 9 minutes after the lid shut).
            let displayOff = awayMode || lidShutAlone || (settings.allowDisplaySleep && !busy && !manualActive && !claudeWorkingNow
                && (extraActive || limitWaitNow))
            if awake.apply(system: true, display: !displayOff) {
                logLine("keep-awake ON (\(displayOff ? "system-only" : "display+system"))")
            }
        } else {
            if awake.apply(system: false, display: false) { logLine("keep-awake OFF") }
        }
        updateLowPower(holding: keepAwake, percent: charge)
        hotspotTick(holding: keepAwake || lidShutHold(closed: lidClosedNow()))

        // "I'm leaving": sleep once Claude (not a detector) has been done for a
        // minute. It used to hold the Mac awake until you came back, which on
        // 2026-10-09 and 2026-10-13 meant all night on battery.
        let awayNeeded = !mustStop && (claudeNeeds || manualActive || lidState.session != nil || checkIn.isOpen)
        awayNeededCached = awayNeeded
        if awaySleep.step(away: awayMode, needed: awayNeeded, fullyAwake: fullyAwake, now: Date()) {
            logLine("I'm leaving: nothing has needed the Mac for a minute, sleeping")
            doSleep()
        }

        var title = ""
        if manualActive, !busy, let until = keepAwakeUntil {
            title = fmtRemaining(Int(until.timeIntervalSinceNow))
        }

        // A one-off lid-closed session is an explicit "don't sleep", like a manual override.
        // Not in a nap: the countdown and its warning there are pointless.
        // The battery pause has its own heads-up and sleep: one notification, not two.
        if settings.enabled && armed && !blocked && !manualActive && !awayMode && fullyAwake && lidState.session == nil
            && batteryPause.headsUpAt == nil && !batteryPause.paused {
            if let t = autoSleepTitle() { title = t }
        } else {
            // Includes a manual override starting mid-warning: a stale
            // pendingSleepAt would otherwise sleep with no warning once it ends.
            cancelPendingSleep()
        }

        refreshIcon(active: keepAwake, title: title)

        // Usage reads the keychain, so not before the setup screen has explained that.
        if settings.setupDone && (lastUsageFetch == nil || Date().timeIntervalSince(lastUsageFetch!) > usageRefresh) { fetchUsage() }
        if settings.checkForUpdates && fullyAwake
            && (lastUpdateCheck == nil || Date().timeIntervalSince(lastUpdateCheck!) > updateCheckEvery) { checkForUpdates() }

        tickCount += 1
        if terminalScanOn && tickCount % 3 == 0 && !scanning {   // ~every 9s
            scanning = true
            let flags = ScanFlags(mode: settings.autoContinueMode, resumeLimit: settings.autoResumeLimit,
                                  watchWorking: settings.keepAwakeClaudeWorking,
                                  canType: fullyAwake && Date().timeIntervalSince(lastFullWake) > postWakeQuiet,
                                  cmuxCLI: runningCmuxCLI(),
                                  afterOurSleep: Date().timeIntervalSince(claudeResumedAt) < 600)
            continueQueue.async { [weak self] in
                self?.scanTerminalForErrors(flags)
                DispatchQueue.main.async { self?.scanning = false }
            }
        }
    }

    /// Runs on continueQueue. Detects stopped API errors in Terminal tabs and
    /// cmux panes and types "continue" with the selected retry policy.
    /// Terminal is read and handled first, exactly as before cmux support;
    /// cmux is read after, so a slow cmux can't make a Terminal read stale.
    func scanTerminalForErrors(_ flags: ScanFlags) {
        let (termTabs, termErr) = terminalTabsSnapshot()

        if termTabs.count != lastTabCount {
            let why = termTabs.isEmpty ? " (\(termErr.isEmpty ? "no Terminal windows?" : termErr))" : ""
            logLine("terminal scan: \(termTabs.count) tab(s)\(why)")
            lastTabCount = termTabs.count
        }
        let n = termTabs.count
        DispatchQueue.main.async { [weak self] in self?.terminalTabsSeen = n; self?.terminalScanError = termErr }

        // 0 Terminal tabs means the Terminal read failed, which says nothing about its tabs.
        let termRead: (String) -> Bool = { _ in !termTabs.isEmpty }
        // Asleep (lid closed), in a dark wake, or just woke: type nothing, and
        // leave retry/limit state untouched so it resumes once properly awake.
        if flags.canType { handleTabs(termTabs, flags: flags, now: Date(), sourceRead: termRead, cmux: false) }

        let (cmuxTabs, cmuxRead) = scanCmux(flags)
        if flags.canType { handleTabs(cmuxTabs, flags: flags, now: Date(), sourceRead: cmuxRead, cmux: true) }

        let tabs = termTabs + cmuxTabs
        if flags.watchWorking {
            // A cmux pane counts only once its live tail agrees, and is asked only when Terminal doesn't settle it.
            let working = termTabs.contains { claudeWorkingVisible($0.text) }
                || cmuxWorkingConfirmed(cmuxTabs.filter { claudeWorkingVisible($0.text) }, cli: flags.cmuxCLI)
            if working != lastWorkingSeen && !tabs.isEmpty {   // 0 tabs = failed read
                lastWorkingSeen = working
                if working {
                    logLine("terminal: Claude working")
                } else {   // diagnostics: what the screen showed when "working" stopped matching
                    let seen = tabs.filter { claudeUIVisible($0.text) }
                        .map { "\($0.key): " + statusLinesAbovePrompt($0.text).joined(separator: " | ") }
                    logLine("terminal: Claude not working. On screen: " + seen.joined(separator: "; "))
                }
            }
            DispatchQueue.main.async { [weak self] in self?.claudeWorkingCached = working }
        }
        guard flags.canType else { return }

        // forget API-error tabs that have been error-free for 90s (recovered);
        // a failed read says nothing about recovery
        let now = Date()
        for (key, st) in continueStates
            where (key.hasPrefix(cmuxKeyPrefix) ? cmuxRead(key) : termRead(key)) && now.timeIntervalSince(st.lastErrorAt) > 90 {
            continueStates.removeValue(forKey: key)
            logLine("auto-continue reset (\(key) recovered)")
        }
        endCmuxEpisodes()
        // A retry still to come counts as Claude working (keeps lid-closed mode on).
        let retrying = continueRetrying(attempts: continueStates.values.map(\.attempts), mode: flags.mode)
        DispatchQueue.main.async { [weak self] in self?.retryPending = retrying }

        // Stay awake only for a scheduled wait, never just because limit text
        // is on screen. Stale text would otherwise hold the Mac awake for days.
        let resumeAts = limitEpisodes.values.compactMap(\.resumeAt)
        DispatchQueue.main.async { [weak self] in self?.limitResumeAts = resumeAts }
    }

    /// A network path update (main thread). After an outage of `outageNudgeSeconds`
    /// or more, types "continue" into the tmux panes the owner marked, if the Mac
    /// is fully awake and past the post-wake quiet.
    func networkChanged(_ ok: Bool) {
        let downSince = outage.downSince
        let wasDown = downSince != nil
        let gap = outage.step(satisfied: ok, now: Date())
        if !ok { if !wasDown { logLine("network down") }; return }
        guard let gap else { return }
        logLine("network back after \(Int(gap.rounded()))s")
        guard shouldNudge(gap: gap, threshold: settings.outageNudgeSeconds, targets: settings.tmuxTargets,
                          awake: fullyAwake, downSince: downSince, lastSleep: lastWillSleep) else {
            if let why = nudgeSkipReason(gap: gap, threshold: settings.outageNudgeSeconds, targets: settings.tmuxTargets,
                                         awake: fullyAwake, downSince: downSince, lastSleep: lastWillSleep) {
                logLine("tmux nudge: not typing, \(why)")
            }
            return
        }
        nudgeTmux(targets: settings.tmuxTargets, pressEnter: settings.tmuxPressEnter, canTypeNow: canTypeNow)
    }

    /// Right before typing, not the scan's start-time copy (continueQueue).
    func canTypeNow() -> Bool { wakeGate.canType(quiet: postWakeQuiet) }

    /// Runs on continueQueue. One source's tabs (Terminal's, or cmux's):
    /// retry API errors, handle usage limits, and resume due limit waits for
    /// that source's keys.
    func handleTabs(_ tabs: [ScanTab], flags: ScanFlags, now: Date, sourceRead: (String) -> Bool, cmux: Bool) {
        for tab in tabs {
            // Claude Code retrying by itself: the error episode is still going
            // (keeps the attempt count, and so the give-up limit, across its cycles).
            if var st = continueStates[tab.key], claudeRetryingVisible(tab.text) {
                st.lastErrorAt = now
                continueStates[tab.key] = st
                continue
            }
            // ── usage-limit auto-resume ──
            if flags.resumeLimit && usageLimitVisible(tab.text) {
                handleUsageLimit(tab, now: now)
                continue
            }
            // ── API-error auto-continue ──
            guard flags.mode != .off else { continue }
            let status = claudeErrorStatus(tab.text, sleepWasOurs: flags.afterOurSleep)
            switch status {
            case .skipped(let why) where errorSkipLogged[tab.key] != why:
                errorSkipLogged[tab.key] = why
                logLine("auto-continue: not answering the error on \(tab.key): \(why)")
            case .none: errorSkipLogged[tab.key] = nil
            default: break
            }
            guard status == .unanswered else { continue }
            if continueStates[tab.key] == nil {
                logLine("auto-continue: error detected on \(tab.key), first try in \(Int(flags.mode.delay(0)))s")
            }
            var st = continueStates[tab.key]
                ?? AutoContinueState(attempts: 0, nextTryAt: now.addingTimeInterval(flags.mode.delay(0)), lastErrorAt: now)
            st.lastErrorAt = now
            if now >= st.nextTryAt && st.attempts < flags.mode.maxAttempts && cmuxScan.stuck.contains(tab.key) {
                st.attempts = flags.mode.maxAttempts   // typing changed nothing there: done with this error (logged then)
            } else if now >= st.nextTryAt && st.attempts < flags.mode.maxAttempts {
                let result = sendToTab("continue", tab.source, trigger: flags.afterOurSleep ? .apiErrorAfterOurSleep : .apiError,
                                       canTypeNow: canTypeNow)
                // Not awake: nothing typed or counted, it tries again next scan. A skip ends the episode (continueAfterTry).
                let step = continueAfterTry(result.asTry, attempts: st.attempts, nextTryAt: st.nextTryAt, mode: flags.mode,
                                            cmux: tab.key.hasPrefix(cmuxKeyPrefix), now: now)
                st.attempts = step.attempts
                st.nextTryAt = step.nextTryAt
                if step.stuck { cmuxScan.stuck.insert(tab.key) }
                switch result {
                case .typed:
                    logLine("auto-continue #\(st.attempts) → \(tab.key)")
                    noteCmuxTyped(tab.key, screen: tab.text)
                case .skipped(let why):
                    logLine("auto-continue → \(tab.key): nothing was typed (\(why)), so no more tries until this error is over")
                case .notAwake:
                    break
                }
                if step.gaveUp {
                    let n = UNMutableNotificationContent()
                    n.title = "Ephedrine"
                    n.body = "Auto-continue gave up after \(flags.mode.maxAttempts) tries "
                        + "(\(tab.key.hasPrefix(cmuxKeyPrefix) ? "a cmux pane" : tab.key))."
                    UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: "ka_giveup_\(tab.key)", content: n, trigger: nil))
                }
            }
            continueStates[tab.key] = st
        }

        if flags.resumeLimit { resumeDueLimits(tabs, now: now, sourceRead: sourceRead, cmux: cmux) }
    }

    /// Runs on continueQueue. A usage-limit wall is on this tab: answer Claude
    /// Code's menu with a "wait" option, then schedule staying awake until the
    /// reset (only if it's within limitWaitCap).
    func handleUsageLimit(_ tab: ScanTab, now: Date) {
        let key = tab.key
        var ep = limitEpisodes[key] ?? LimitEpisode()
        defer { limitEpisodes[key] = ep }

        if !ep.menuHandled && menuVisible(tab.text) {
            ep.menuHandled = true   // one try per episode, never keep typing into a menu
            if let choice = limitMenuChoice(tab.text) {
                if cmuxScan.stuck.contains(key) {
                    logLine("usage limit on \(key): not picking option \(choice.number), typing there changed nothing before")
                } else {
                    switch sendToTab(choice.number, tab.source, trigger: .limitMenu(choice), canTypeNow: canTypeNow) {
                    case .notAwake:
                        ep.menuHandled = false   // nothing typed; try again once properly awake
                    case .skipped(let why):
                        logLine("usage limit on \(key): option \(choice.number) not picked, nothing was typed: \(why)")
                    case .typed:
                        noteCmuxTyped(key, screen: tab.text)
                        if case .claudeAutoContinue = choice { ep.claudeResumes = true }
                        logLine("usage limit on \(key): picked option \(choice.number), "
                                + (ep.claudeResumes ? "Claude Code continues by itself at reset" : "wait for reset"))
                    }
                }
            } else {
                let labels = menuOptions(tab.text).map { "\($0.number). \($0.label)" }.joined(separator: " | ")
                logLine("usage limit on \(key): no wait option in menu, left it alone [\(labels)]")
            }
        }
        if claudeAutoResumeVisible(tab.text) { ep.claudeResumes = true }

        guard ep.resumeAt == nil, !ep.noted else { return }
        // Something besides the limit text itself must say this is Claude Code,
        // so a pasted doc or log in a plain shell can't schedule a keystroke.
        guard ep.menuHandled || ep.claudeResumes || claudeUIVisible(tab.text) else { return }
        guard let reset = parseResetTime(tab.text, now: now) else {
            ep.noted = true
            logLine("usage limit on \(key): no reset time on screen, not waiting"); return
        }
        guard reset.timeIntervalSince(now) <= limitWaitCap else {
            ep.noted = true
            logLine("usage limit on \(key): resets \(clockStr(reset)), too far off to keep the Mac awake for"); return
        }
        ep.resumeAt = reset.addingTimeInterval(60)
        logLine("usage limit on \(key): resets \(clockStr(reset)), "
                + (onACPower() ? "staying awake; " : "on battery, so awake only for the last hour; ")
                + (ep.claudeResumes ? "Claude Code will continue by itself" : "will type continue at \(clockStr(ep.resumeAt))"))
    }

    /// Runs on continueQueue. For one source's keys (`cmux` or Terminal's):
    /// types "continue" for waits whose reset has passed, and forgets episodes
    /// whose limit is no longer on screen.
    func resumeDueLimits(_ tabs: [ScanTab], now: Date, sourceRead: (String) -> Bool, cmux: Bool) {
        let byKey = Dictionary(tabs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let atPlainPrompt: (String) -> Bool = {
            claudeUIVisible($0) && !menuVisible($0) && !claudeWorkingVisible($0) && !claudeAutoResumeVisible($0)
        }
        for key in Array(limitEpisodes.keys) where key.hasPrefix(cmuxKeyPrefix) == cmux {
            guard var ep = limitEpisodes[key] else { continue }
            let tab = byKey[key]
            let showing = tab.map { usageLimitVisible($0.text) } ?? false
            if !showing && sourceRead(key) { limitEpisodes.removeValue(forKey: key); continue }   // a failed read says nothing; keep
            guard let at = ep.resumeAt, now >= at, !ep.resumed, let tab else { continue }
            let text = tab.text
            ep.resumed = true
            if now > at + limitWaitGrace {
                logLine("usage limit on \(key): reset passed while the Mac was asleep, not typing")
            } else if ep.claudeResumes {
                logLine("usage limit on \(key): reset passed, Claude Code continues by itself")
            } else if atPlainPrompt(text) {
                if cmuxScan.stuck.contains(key) {
                    logLine("usage limit on \(key): reset passed, not typing: typing there changed nothing before")
                } else {
                    switch sendToTab("continue", tab.source, trigger: .limitReset, canTypeNow: canTypeNow) {
                    case .notAwake:
                        ep.resumed = false   // nothing typed; try again once properly awake
                    case .skipped(let why):
                        logLine("usage limit on \(key): reset passed, but nothing was typed: \(why)")
                    case .typed:
                        noteCmuxTyped(key, screen: text)
                        logLine("usage limit on \(key): reset passed → typed continue")
                    }
                }
            } else {
                logLine("usage limit on \(key): reset passed, but the screen isn't at a plain prompt, so not typing")
            }
            limitEpisodes[key] = ep
        }
    }

    func doSleep() {
        armed = false
        cancelPendingSleep()
        awake.apply(system: false, display: false)
        releaseLidForSleep()
        logLine("Sleeping the Mac")
        if let err = requestSystemSleep() { logLine("sleep request failed: \(err)") }
    }

    func cancelPendingSleep() {
        if pendingSleepAt != nil { logLine("pending sleep cancelled"); pendingSleepAt = nil }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ka_presleep"])
    }

    func notifyPreSleep() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus != .authorized {
                DispatchQueue.main.async {
                    guard let self = self, !self.warnedNoNotifications else { return }
                    self.warnedNoNotifications = true
                    logLine("no pre-sleep warning: notifications are off (the Mac still sleeps on time)")
                }
            }
        }
        let c = UNMutableNotificationContent()
        c.title = "Ephedrine"
        c.body = "Sleeping in \(Int(preSleepWarning))s. Click “Stay awake” to cancel."
        c.categoryIdentifier = "KA_SLEEP"
        center.add(UNNotificationRequest(identifier: "ka_presleep", content: c, trigger: nil))
        logLine("pre-sleep notification shown")
    }

    // UNUserNotificationCenterDelegate
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive resp: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if resp.actionIdentifier == "STAY_AWAKE" {
            cancelPendingSleep()
            armed = false
            keepAwakeUntil = Date().addingTimeInterval(30 * 60)   // snooze 30 min
            logLine("user chose Stay awake, snoozing 30 min")
            evaluate()
        }
        done()
    }

    // MARK: busy detection

    /// Sessions with a live marker. hook.sh writes `<sid>` plus one `<sid>~<tool>`
    /// per running tool call, so count distinct session ids.
    func activeSessionCount() -> Int {
        guard let items = try? fm.contentsOfDirectory(atPath: stateDir) else { return 0 }
        let nowEpoch = Date().timeIntervalSince1970
        var live = Set<Substring>()
        for f in items where !f.hasPrefix(".") {
            let path = "\(stateDir)/\(f)"
            let contents = try? String(contentsOfFile: path, encoding: .utf8)
            let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let e = markerExpiry(contents: contents, mtime: mtime, leaseFallback: leaseFallback),
               nowEpoch < e { live.insert(f.split(separator: "~", maxSplits: 1)[0]) }
            else { try? fm.removeItem(atPath: path) }   // also reaps a tool marker whose PostToolUse never came
        }
        return live.count
    }

    // MARK: Away mode ("I'm leaving")

    func enterAway() {
        awayMode = true; awayReturn = AwayReturn(enteredAt: Date())
        suspendApps()
        // Display off, not brightness 0: nothing to restore, so it can't come
        // back black (2026-10-14), and it saves more power.
        sleepDisplayNow()
        persistAwayState()   // crash-recovery: next launch un-freezes the apps
        awayTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.awayCheck() }
        RunLoop.main.add(t, forMode: .common)   // keeps running while a menu is open
        awayTimer = t
        awaySleep = AwaySleep()
        lastAwayCheck = Date()
        logLine("away mode ON: paused \(pausedAppCount) apps\(pausedList), turned the screen off")
        awayNotify("Away mode on", "Paused \(pausedAppCount) apps and turned the screen off. The Mac sleeps once Claude is done. Move the mouse or press a key when you're back.")
        evaluate()
    }

    func exitAway(_ why: String) {
        awayTimer?.invalidate(); awayTimer = nil
        resumeApps()
        restoreBrightness()   // only if an older version dimmed it (see recoverFromInterruptedAway)
        clearAwayState()
        awayMode = false; awayReturn = nil
        logLine("away mode OFF (\(why)): resumed apps")
        awayNotify("Welcome back", "Resumed your apps.")
        evaluate()
    }

    /// Runs every 1s while away: restore as soon as you move the mouse or type,
    /// ignoring the first few seconds (the click that started it), or as soon
    /// as the Mac wakes up with the lid open.
    func awayCheck() {
        guard awayMode, let r = awayReturn else { return }
        let now = Date()
        defer { lastAwayCheck = now }
        if awayEndsOnWake(sinceLastCheck: now.timeIntervalSince(lastAwayCheck),
                          fullyAwake: systemFullyAwake(fallback: !systemSleeping), lidClosed: lidClosedNow()) {
            lastAwayReturnByInput = now
            exitAway("woke up with the lid open")
            return
        }
        let idle = hidIdleSeconds()
        if r.isBack(now: Date(), idleSeconds: idle) {
            lastAwayReturnByInput = Date()
            exitAway(String(format: "input %.1fs ago", idle))
        }
    }

    /// Apps "I'm leaving" never pauses. Terminals and editors can host Claude
    /// Code, and pausing the host app stalls its terminal and hangs Claude. Add
    /// more without rebuilding:
    ///   defaults write io.github.3xyy.ephedrine awayKeepRunning -array-add <bundle id>
    /// Every JetBrains IDE and Zoom's and Webex's helpers are kept by prefix
    /// (builtInKeepRunningPrefixes). Always pause wins over all of these.
    static let awayKeepRunning: Set<String> = [
        "com.apple.finder", "io.github.3xyy.ephedrine",
        // terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.cmuxterm.app", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby",
        // editors with built-in terminals
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity", "com.google.antigravity-ide",
        "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.vscodium", "com.google.android.studio",
        // Claude app, and other apps agents run in
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",   // ChatGPT, Codex
        "com.conductor.app", "com.t3tools.t3code", "com.t3tools.t3code.reasoning",
        // Xcode, Simulator, iPhone Mirroring
        "com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.apple.ScreenContinuity",
        // browsers
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly", "com.brave.Browser.dev",
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.apple.Safari",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "app.zen-browser.zen", "ai.perplexity.comet",
        // never freeze an active call/meeting
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.skype.skype",
        "com.cisco.washost", "com.webex.meetingmanager", "com.webex.pluginagent",   // Webex helpers
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        // or a recording, dictation or meeting notes
        "com.electron.wispr-flow", "com.granola.app", "com.otterai.desktop", "com.obsproject.obs-studio", "com.loom.desktop",
        // VPNs: frozen, they can cut the network Claude and Remote Control need
        "com.cloudflare.1dot1dot1dot1.macos", "com.wireguard.macos", "com.tailscale.ipn.macos",
        "io.tailscale.ipn.macsys", "com.nordvpn.macos", "com.expressvpn.ExpressVPN", "net.mullvad.vpn",
        // services Claude's tools use: SSH agents in password managers, databases, containers, local models
        "com.1password.1password", "com.bitwarden.desktop", "com.postgresapp.Postgres2", "dev.kdrag0n.MacVirt",   // OrbStack
        "com.docker.docker", "com.electron.dockerdesktop", "ai.elementlabs.lmstudio", "com.electron.ollama",
    ]

    /// Stop every app shouldPause picks, with its helper processes (Electron
    /// apps do most of their work in child processes).
    func suspendApps() {
        if !pausedProcesses.isEmpty { resumeApps() }   // never lose track of processes still stopped
        pausedNames.removeAll()
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                           name: $0.localizedName ?? "", regular: $0.activationPolicy == .regular)
        }
        let procs = processSnapshot()
        if procs.isEmpty { logLine("couldn't read the process list, paused nothing"); return }
        // Claude Code under an app no list names (Rio, Wave, Emacs…) keeps that app running.
        let ps = runTool("/bin/ps", ["-axo", "pid=,args="])
        if ps.isEmpty { logLine("couldn't run ps, so an app Claude Code runs under may get paused") }
        let plan = pausePlan(apps: apps, procs: procs, keepRunning: Self.awayKeepRunning.union(settings.awayKeepRunning),
                             alwaysPause: Set(settings.alwaysPause), selfPID: getpid(),
                             claudePIDs: claudePids(psLines: ps.split(separator: "\n").map(String.init)))
        for name in plan.keptForClaude { logLine("kept \(name) running: Claude Code runs under it") }
        let stopped = Set(stopRecorded(plan.processes.map { PausedProcess(pid: $0.pid, start: $0.start) }).map(\.pid))
        pausedNames = plan.apps.filter { stopped.contains($0.pid) }.map(\.displayName)
    }

    /// SIGSTOP `entries` (each parent before its children) the safe way, for
    /// suspendApps and the Docker rule alike. They join pausedProcesses and are
    /// written to paused-pids (the watchdog started) before the first stop, so
    /// a crash partway through still leaves every stopped pid recorded; no
    /// record, no stop. Then only those still the same process in a fresh
    /// snapshot are stopped (a pid that exited since may belong to something
    /// else now), children first. Entries not stopped are taken out again.
    /// Returns the stopped ones.
    func stopRecorded(_ entries: [PausedProcess], logPrefix: String = "") -> [PausedProcess] {
        guard !entries.isEmpty else { return [] }
        func takeOut(_ gone: [PausedProcess]) {
            guard !gone.isEmpty else { return }
            pausedProcesses.removeAll { gone.contains($0) }
            persistAwayState()
        }
        pausedProcesses += entries
        guard persistAwayState() else { takeOut(entries); logLine(logPrefix + "couldn't record what to pause, paused nothing"); return [] }
        let now = processSnapshot()
        if now.isEmpty { takeOut(entries); logLine(logPrefix + "couldn't read the process list, paused nothing"); return [] }
        let live = entries.filter { stillSame($0, in: now) }
        var failed = Set<pid_t>()
        for p in live.reversed() {   // children first, parents last
            if kill(p.pid, SIGSTOP) != 0 { failed.insert(p.pid) }
        }
        let stopped = live.filter { !failed.contains($0.pid) }   // the rest: gone already, or not ours
        takeOut(entries.filter { !stopped.contains($0) })
        return stopped
    }

    /// SIGCONT only what the Docker rule stopped, roots first, skipping pids
    /// reused since; the apps the lid paused stay paused.
    func resumeDocker(_ why: String) {
        let entries = dockerPausedProcesses
        let procs = processSnapshot()
        if procs.isEmpty { logLine("couldn't read the process list, resuming every paused Docker pid") }
        let live = toResume(entries, in: procs)
        for p in live { kill(p.pid, SIGCONT) }
        pausedProcesses.removeAll { entries.contains($0) }
        dockerPausedProcesses.removeAll()
        if pausedProcesses.isEmpty { clearAwayState() } else { persistAwayState() }
        logLine("\(why), resumed Docker (\(live.count) processes)")
    }
    /// Names of what suspendApps last paused (for the log).
    var pausedList: String { pausedNames.isEmpty ? "" : " (" + pausedNames.joined(separator: ", ") + ")" }
    /// Paused apps, not processes: what the menu, the log and notifications count.
    var pausedAppCount: Int { pausedNames.count }

    /// SIGCONT what suspendApps stopped, apps before their helpers, skipping
    /// any that exited (its pid may belong to something else now).
    func resumeApps() {
        // The battery pause's Claude processes stay stopped: resumeClaude ends that.
        let mine = pausedProcesses.filter { !claudePausedProcesses.contains($0) }
        let procs = mine.isEmpty ? [] : processSnapshot()
        if procs.isEmpty && !mine.isEmpty { logLine("couldn't read the process list, resuming every paused pid") }
        let live = toResume(mine, in: procs)
        for p in live { kill(p.pid, SIGCONT) }
        let skipped = mine.count - live.count
        logLine("resumed \(pausedAppCount) apps" + (dockerPaused ? " and Docker" : "")
                + " (\(live.count) processes" + (skipped > 0 ? ", skipped \(skipped) that exited" : "") + ")")
        pausedProcesses = claudePausedProcesses
        pausedNames.removeAll()
        dockerPausedProcesses.removeAll()
    }

    // ── Away crash-recovery: if we die while apps are SIGSTOPped / screen is
    // dimmed, the state file lets the next launch undo it. Each process is
    // recorded with its start time, so a pid reused since then is left alone.

    /// False if paused-pids couldn't be written: then the watchdog can't
    /// un-pause anything after a crash, so suspendApps stops nothing.
    @discardableResult
    func persistAwayState() -> Bool {
        let state = AwayState(processes: pausedProcesses, pids: suspendedPids, brightness: Double(savedBrightness))
        if let d = try? JSONEncoder().encode(state) {
            try? d.write(to: URL(fileURLWithPath: awayStatePath), options: .atomic)
        }
        var ok = true
        do {
            try suspendedPids.map(String.init).joined(separator: " ").write(toFile: pausedPidsPath, atomically: true, encoding: .utf8)
        } catch {
            logLine("couldn't write \(pausedPidsPath): \(error.localizedDescription)")
            ok = false
        }
        updateWatchdog()   // un-pauses them if Ephedrine dies, not only in lid mode
        return ok
    }
    func clearAwayState() {
        // Callers clear after resumeApps; a battery pause may still have Claude stopped.
        if !pausedProcesses.isEmpty { persistAwayState(); return }
        try? fm.removeItem(atPath: awayStatePath); try? fm.removeItem(atPath: pausedPidsPath)
        updateWatchdog()
    }
    func recoverFromInterruptedAway() {
        guard let d = fm.contents(atPath: awayStatePath),
              let state = try? JSONDecoder().decode(AwayState.self, from: d) else { return }
        let pids = state.pidsToResume(in: processSnapshot())   // a file from an older version: all its pids
        for pid in pids { kill(pid, SIGCONT) }
        if let b = state.brightness, b >= 0 {
            savedBrightness = Float(b)
            restoreBrightness()
        }
        clearAwayState()
        if !pids.isEmpty { logLine("recovered from an interrupted away mode, resumed \(pids.count) processes") }
    }

    typealias BrightSet = @convention(c) (UInt32, Float) -> Int32
    let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    func restoreBrightness() {
        guard savedBrightness >= 0, let h = dlopen(displayServicesPath, RTLD_LAZY),
              let sp = dlsym(h, "DisplayServicesSetBrightness") else { savedBrightness = -1; return }
        _ = unsafeBitCast(sp, to: BrightSet.self)(CGMainDisplayID(), savedBrightness)
        savedBrightness = -1
    }

    func batteryNotify(_ t: String, _ b: String, id: String = "ka_battery") {
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: Battery pause (BatteryPause)

    /// At the battery limit: say so while the owner is at the Mac, and once
    /// they're away pause Claude Code and sleep the Mac. Runs before lid mode
    /// each tick, so with the lid shut Claude is stopped before the Mac sleeps.
    func stepBatteryPause(lidShutAlone: Bool, idle: Double, claudeBusy: Bool, percent: Int?) {
        let pct = percent.map { "\($0)%" } ?? "its limit"
        let ev = batteryPause.step(BatteryPauseInputs(
            // "Only on the charger" stops on battery at any level: no reserve to keep, so no pause.
            enabled: settings.batteryPauseClaude && awakeBatteryFloor(settings.batteryFloor) < lidOnlyPluggedIn,
            stopped: batteryStop.stopped, onBattery: !onACPower(),
            lidShutAlone: lidShutAlone, fullyAwake: fullyAwake, idle: idle, awayAfter: effectiveGraceSeconds(),
            claudeBusy: claudeBusy, now: Date()))
        switch ev {
        case .warnHere?:
            logLine("battery at \(pct) with you at the Mac: Claude keeps working, and is paused once you step away")
            batteryNotify("Battery at \(pct)", "Claude keeps working while you're here. When you step away, Ephedrine pauses it and puts the Mac to sleep, so the rest of the battery is there when you're back.")
        case .headsUp?:
            logLine("battery at \(pct) and you're away: pausing Claude and sleeping in \(Int(BatteryPause.headsUpDelay))s unless you're back")
            batteryNotify("Pausing Claude to save battery", "Battery at \(pct). Claude pauses and the Mac sleeps in \(Int(BatteryPause.headsUpDelay)) seconds. Move the mouse or press a key to keep going.", id: "ka_batterypause")
        case .cancelled?:
            logLine("battery pause cancelled: you're back")
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ka_batterypause"])
        case .pauseAndSleep?:
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ka_batterypause"])
            pauseClaude(pct)
            doSleep()
        case .resume(let why)?:
            switch why {
            case .pluggedIn: resumeClaude("plugged in")
            case .back:      resumeClaude("you're back")
            case .turnedOff: resumeClaude("battery pause turned off")
            }
        case nil: break
        }
    }

    /// SIGSTOP every Claude Code process tree and the shells sessions run in
    /// (claudePausePlan), recorded first so a crash or relaunch still resumes them.
    func pauseClaude(_ pct: String) {
        guard claudePausedProcesses.isEmpty else { return }
        let procs = processSnapshot()
        if procs.isEmpty { logLine("battery at \(pct): couldn't read the process list, so Claude wasn't paused"); return }
        func lines(_ field: String) -> [Int32: String] {
            var out: [Int32: String] = [:]
            for line in runTool("/bin/ps", ["-axww", "-o", "pid=,\(field)="]).split(separator: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pid = Int32(parts[0]) { out[pid] = String(parts[1]) }
            }
            return out
        }
        let comm = lines("comm"), args = lines("args")
        var info: [Int32: ProcText] = [:]
        for (pid, c) in comm { info[pid] = ProcText(comm: c, args: args[pid] ?? "") }
        let plan = claudePausePlan(procs: procs, info: info, selfPID: getpid())
        let sessions = plan.filter { info[$0.pid].map(isClaudeCode) ?? false }.count
        claudePausedProcesses = stopRecorded(plan.map { PausedProcess(pid: $0.pid, start: $0.start) }, logPrefix: "battery pause: ")
        logLine(plan.isEmpty ? "battery at \(pct) and you're away: no Claude Code running, sleeping"
                : "battery at \(pct) and you're away: paused Claude Code (\(sessions) processes of its own, \(claudePausedProcesses.count) in all), sleeping")
    }

    /// SIGCONT what pauseClaude stopped, Claude's trees before their shells,
    /// skipping pids reused since. For 10 minutes after, auto-continue answers
    /// the "went to sleep" errors the pause caused.
    func resumeClaude(_ why: String) {
        let entries = claudePausedProcesses
        guard !entries.isEmpty else { return }
        let procs = processSnapshot()
        if procs.isEmpty { logLine("couldn't read the process list, resuming every paused Claude pid") }
        let live = toResume(entries, in: procs)
        for p in live { kill(p.pid, SIGCONT) }
        pausedProcesses.removeAll { entries.contains($0) }
        claudePausedProcesses.removeAll()
        if pausedProcesses.isEmpty { clearAwayState() } else { persistAwayState() }
        claudeResumedAt = Date()
        logLine("\(why), resumed Claude Code (\(live.count) processes)")
    }

    func heatNotify(_ t: String, _ b: String) {
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka_heat", content: c, trigger: nil))
    }

    func stayOverNotify() {
        let c = UNMutableNotificationContent()
        c.title = "Stay awake is over"
        c.body = "Ephedrine is back to keeping the Mac awake only while Claude works."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka_stay_over", content: c, trigger: nil))
    }

    func awayNotify(_ t: String, _ b: String) {
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka_away", content: c, trigger: nil))
    }

    // MARK: Claude usage

    /// Reads the Homebrew formula; a newer version shows at the top of the menu.
    func checkForUpdates() {
        lastUpdateCheck = Date()
        guard let url = URL(string: updateCheckURL) else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("Ephedrine/\(appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  let latest = parseFormulaVersion(String(decoding: data, as: UTF8.self)) else { return }   // offline: try next time
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.settings.checkForUpdates else { return }
                let newer = isNewerVersion(latest.version, than: appVersion)
                if newer && self.latestRelease != latest { logLine("update available: \(latest.version) (running \(appVersion))") }
                self.latestRelease = newer ? latest : nil
            }
        }.resume()
    }

    @objc func openLatestRelease() {
        if let s = latestRelease?.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    func fetchUsage() {
        guard !usageFetching else { return }
        usageFetching = true
        lastUsageFetch = Date()
        updateUsageView()
        func finish(_ limits: [UsageLimit]?) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.usageFetching = false
                if let limits = limits, !limits.isEmpty {
                    self.usageLimits = limits
                    self.usageError = false
                    self.maybeAlertUsage()
                } else {
                    self.usageError = true   // keep showing the last good numbers, if any
                }
                self.updateUsageView()
            }
        }
        DispatchQueue.global(qos: .utility).async {
            let creds = runTool("/usr/bin/security",
                                ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            guard let data = creds.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return finish(nil) }
            let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
            guard let token = oauth["accessToken"] as? String, !token.isEmpty,
                  let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return finish(nil) }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            URLSession.shared.dataTask(with: req) { d, resp, _ in
                let httpOK = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                guard httpOK, let d = d,
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return finish(nil) }
                finish(parseUsageLimits(j))
            }.resume()
        }
    }

    func maybeAlertUsage() {
        for l in usageAlerts.check(usageLimits, threshold: settings.usageAlert) {
            let c = UNMutableNotificationContent()
            c.title = "Claude usage"
            c.body = String(format: "%@ is at %.0f%%. Resets %@.", l.label, l.percent, clockStr(l.resetsAt))
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "ka_usage_\(l.key)", content: c, trigger: nil))
            logLine("usage alert: \(l.label) \(Int(l.percent))%")
        }
    }

    func updateUsageView() {
        guard let uv = usageView else { return }
        let rows = usageLimits.map {
            UsageView.Row(label: $0.label, percent: $0.percent,
                          detail: String(format: "%.0f%%", $0.percent)
                              + ($0.resetsAt.map { " · resets \(clockStr($0))" } ?? ""),
                          level: usageLevel(percent: $0.percent, severity: $0.severity))
        }
        let status: String
        if usageFetching { status = "refreshing…" }
        else if usageError { status = rows.isEmpty ? "" : "couldn't refresh · click to retry" }
        else { status = "click to refresh" }
        uv.update(rows: rows, status: status,
                  message: rows.isEmpty ? (usageError ? "Unavailable. Open Claude Code, or allow keychain access"
                                                      : lastUsageFetch == nil ? "Click to show (reads Claude Code's sign-in)"
                                                      : "Loading…") : nil)
    }

    // MARK: menu bar icon

    /// Which glyph stands for the current state (menu bar and status card share it):
    /// `symbol` is nil for the awake mug.
    func iconChoice(active: Bool) -> (symbol: String?, lidSession: Bool) {
        // Laptop for a lid session the user started, or `pmset disablesleep` set
        // by hand (both easy to forget); Claude-driven lid mode ends by itself,
        // so it shows the normal awake mug.
        let lidSession = lidActive && (lidState.session != nil || !fm.fileExists(atPath: lidMarkerPath))
        if !awayMode && !lidSession && (active || lidActive) { return (nil, lidSession) }
        let name = awayMode ? "figure.walk"
            : lidSession ? "laptopcomputer"
            : (!settings.enabled ? "moon" : "moon.zzz")
        return (name, lidSession)
    }

    func refreshIcon(active: Bool, title: String) {
        guard let btn = statusItem.button else { return }
        iconActive = active
        let style = settings.menuBarIconStyle
        let choice = iconChoice(active: active)
        if let name = choice.symbol {
            btn.image = menuBarSymbolIcon(name, tint: menuBarStateTint(style: style, away: awayMode, lidSession: choice.lidSession))
        } else {
            if awakeIcons[style] == nil { awakeIcons[style] = menuBarAwakeIcon(style: style) }
            btn.image = awakeIcons[style]
        }
        btn.title = title.isEmpty ? "" : " " + title
        btn.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }

    // MARK: menu

    func statusText() -> String {
        if awayMode { return "Away: \(pausedAppCount) apps paused, screen off" }
        if lidPaused { return "Lid shut: \(pausedAppCount) apps paused" }
        if heatStop.stopped { return "Very hot, letting the Mac sleep until it cools down" }
        if batteryStop.stopped {
            return awakeBatteryFloor(settings.batteryFloor) >= lidOnlyPluggedIn
                ? "On battery: Ephedrine keeps the Mac awake only on the charger"
                : batteryPercent().map { "Battery at \($0)%, letting the Mac sleep until it's plugged in" }
                    ?? "Battery level unknown, letting the Mac sleep until it's plugged in"
        }
        if manualKeepAwake { return "Awake until you turn it off" }
        if let until = keepAwakeUntil { return "Awake for \(fmtCountdown(Int(until.timeIntervalSinceNow))) more" }
        if !settings.enabled { return "Off, macOS sleeps as usual" }
        let n = activeSessionCount()
        if n > 0 { return "Awake, Claude is working" + (n > 1 ? " (\(n) sessions)" : "") }
        if settings.keepAwakeClaudeWorking && claudeWorkingCached { return "Awake, Claude is busy in a terminal" }
        if settings.autoResumeLimit && limitWaitPending { return "Awake until a usage limit resets" }
        if settings.autoResumeLimit, let at = limitResumeAts.filter({ $0 > Date() }).min(), !onACPower() {
            return "Usage limit resets \(clockStr(at)); on battery the Mac can sleep instead of waiting"
        }
        if extraActiveHolding, let l = extraActiveLabel { return "Awake: " + l.prefix(1).lowercased() + l.dropFirst() }
        if extraActiveHolding { return "Awake, a background task is running" }
        if armed && settings.finishMode != .stayNormal && autoSleepAllowed() {
            if let at = pendingSleepAt { return "Sleeping in \(max(0, Int(at.timeIntervalSinceNow)))s…" }
            return "Idle, sleeping in \(fmtCountdown(graceRemaining()))"
        }
        return "Idle"
    }

    /// What happens next, for the menu and the Now pane (nil when the status line says it all).
    func nextText() -> String? {
        if batteryStop.stopped || heatStop.stopped { return nil }
        if awayMode { return awayNeededCached ? "Sleeps a minute after Claude is done" : "Sleeping within a minute" }
        if manualKeepAwake || keepAwakeUntil != nil || !settings.enabled || !wasBlocked { return nil }
        guard autoSleepAllowed(), settings.finishMode != .stayNormal else { return "Then macOS sleeps as usual" }
        let g = Int(effectiveGraceSeconds())
        let wait = g < 60 ? "\(g) seconds" : "\(g / 60) min"
        return settings.finishMode == .alwaysSleep ? "Then sleeps \(wait) after it's done" : "Then sleeps once you've been away \(wait)"
    }

    /// The battery limit, shown while on battery and something is being kept awake.
    func batteryText() -> String? {
        guard !onACPower(), !batteryStop.stopped, let pct = batteryPercent(),
              awake.systemOn || awayMode || lidActive else { return nil }
        return "On battery (\(pct)%): stops keeping it awake at \(awakeBatteryFloor(settings.batteryFloor))%"
    }

    /// Low Power Mode is ours and actually on: on the charger, the battery profile we set isn't the one in use.
    var lowPowerOursAndOn: Bool { fm.fileExists(atPath: lowPowerMarkerPath) && ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// What Ephedrine is holding back; later tasks fill in the rest.
    var heldState: (paused: Int, dockerPaused: Bool, muted: Bool, lowPower: Bool, lastGap: TimeInterval?) {
        // "muted" while the hold has the default output muted, not while a gone device's entry waits.
        (pausedAppCount, dockerPaused, muteWatchdogArmed(), lowPowerOursAndOn, outage.lastGap)
    }

    /// Plain warning lines for the status card (no "⚠"; the card draws the triangle).
    func menuWarnings() -> [String] {
        var out: [String] = []
        #if LID_SIMULATION
        out.append("Lid simulation build")
        #endif
        if lidActive && !fm.fileExists(atPath: lidMarkerPath) { out.append("Sleep is disabled by pmset, not by Ephedrine") }
        if lowPowerOffFailures >= 2 && fm.fileExists(atPath: lowPowerMarkerPath) {
            out.append("Low Power Mode is stuck on. Re-run lid setup, or turn it off in System Settings, Battery.")
        }
        if !hotspotName.isEmpty && hotspotPassword == .unreadable { out.append("Hotspot password needs re-entering in Settings") }
        out += browserWarnings()
        return out
    }

    /// Actionable items right under the status card.
    func addAlertItems(to menu: NSMenu) {
        if lowPowerSetupNeeded {
            menu.addItem(item("Re-run lid setup to allow Low Power Mode", #selector(setupLid),
                              tip: "Adds Low Power Mode to what Ephedrine may switch. Asks for your password once.", symbol: "arrow.clockwise"))
        }
        addBrowserItems(to: menu)
    }

    /// Everything the status card shows. Watts and Wi-Fi are read here, when the menu opens, never on a timer.
    func menuStatus() -> MenuStatus {
        let chips = StatusLines.chips(watts: instantWatts(), batteryPercent: batteryPercent(),
                                      charging: isCharging(), wifi: wifiStatusName())
        var notes: [String] = []
        if batteryText() != nil { notes.append(StatusLines.batteryNote(floor: awakeBatteryFloor(settings.batteryFloor))) }
        let h = heldState
        if let held = StatusLines.held(paused: h.paused, dockerPaused: h.dockerPaused, muted: h.muted,
                                       lowPower: h.lowPower, lastGap: h.lastGap) { notes.append(held) }
        let snap = featureSnapshot()
        return MenuStatus(headline: statusText(), detail: nextText(), chips: chips, notes: notes, warnings: menuWarnings(),
                          features: FeatureRows.rows(snap), hint: FeatureRows.hint(snap))
    }

    /// Everything the card's feature rows say, read once when the menu opens.
    private func featureSnapshot() -> FeatureSnapshot {
        let now = Date()
        let marker = lidActive && fm.fileExists(atPath: lidMarkerPath)
        let closed = lidClosedNow()
        let cause = lowPowerOursAndOn   // the same test as the held line
            ? (try? String(contentsOfFile: lowPowerMarkerPath, encoding: .utf8)).flatMap { LowPowerCause(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            : nil
        let cmuxState = cmuxRowState
        let ssid = hotspotName
        return FeatureSnapshot(
            lidSetup: lidSetupOK, lidHolding: marker, lidClosed: closed && externalDisplayActive(),
            claudeWorking: activeSessionCount() > 0 || (settings.keepAwakeClaudeWorking && claudeWorkingCached),
            claudeCanHoldLid: claudeCanHoldLid, foreignNoSleep: lidActive && !marker,   // someone else's disablesleep
            lowPowerNeedsRerun: lowPowerSetupNeeded, lowPowerOn: cause,
            lowPowerOnLidShut: settings.lowPowerOnLidShut, lowPowerFloor: settings.lowPowerFloor,
            muteOnShut: settings.lidMute, keyboardOffOnShut: settings.lidKeyboardOff,
            pauseAppsOnShut: settings.lidPauseApps, dockerRule: settings.lidDockerRule,
            keyboardLightWorks: KeyboardBacklight.shared.refusal == nil,
            cmux: cmuxState, hotspotSSID: ssid, hotspotPassword: hotspotPassword,
            holding: awake.systemOn || lidShutHold(closed: closed),
            networkUp: outage.downSince == nil,
            downFor: outage.downSince.map { now.timeIntervalSince($0) }, lastGap: outage.lastGap,
            tmuxTargets: settings.tmuxTargets.count, keepAwakeOn: settings.enabled)
    }

    /// The card's glyph and tile color: the menu bar's own choice of icon.
    private func statusCardGlyph() -> (NSImage, NSColor) {
        if heatStop.stopped {
            return (cardSymbol("thermometer.high", menuWarningColor), menuWarningColor)
        }
        if batteryStop.stopped {
            return (cardSymbol("battery.25percent", menuWarningColor), menuWarningColor)
        }
        let tint: NSColor = (iconActive || awayMode || lidActive) ? claudeOrange : .secondaryLabelColor
        guard let name = iconChoice(active: iconActive).symbol else {
            let size = NSSize(width: 20, height: 20)
            return (NSImage(size: size, flipped: true) { r in drawCupGlyph(in: r, cup: claudeOrange, spark: claudeOrange); return true }, tint)
        }
        return (cardSymbol(name, tint), tint)
    }

    private func cardSymbol(_ name: String, _ color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        durationPanel.close()
        if settings.setupDone && (lastUsageFetch == nil || Date().timeIntervalSince(lastUsageFetch!) > 60) { fetchUsage() }
        refreshDisplaySleepIfStale()
        menu.removeAllItems()
        addStatusAndUsage(to: menu)
        menu.addItem(.separator())
        menu.addItem(awayMode ? item("I'm back, restore my apps", #selector(toggleAway), symbol: "arrow.uturn.backward")
                              : item("I'm leaving", #selector(toggleAway), tip: "Pause apps, screen off, sleep when Claude's done", symbol: "figure.walk"))
        menu.addItem(stayAwakeMenuItem())
        menu.addItem(.separator())
        let sw = SwitchRowView(title: "Keep awake while Claude works", isOn: settings.enabled,
                               toolTip: settings.enabled ? nil : "Off, so macOS sleeps as usual") { [weak self] on in self?.settings.enabled = on }
        let swItem = NSMenuItem()
        swItem.view = sw
        menu.addItem(swItem)
        let s = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        s.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(s)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ephedrine", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    /// Menu item with an action on self.
    func item(_ title: String, _ action: Selector?, on: Bool = false,
                      subtitle: String? = nil, tip: String? = nil, symbol: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        it.toolTip = tip
        it.subtitle = subtitle
        if let symbol = symbol { it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return it
    }

    private func stayAwakeMenuItem() -> NSMenuItem {
        let sub = NSMenu()
        for (title, mins) in [("For 30 minutes", 30), ("For 1 hour", 60), ("For 2 hours", 120)] {
            let it = item(title, #selector(stayAwakeChosen(_:)))
            it.tag = mins
            sub.addItem(it)
        }
        sub.addItem(item("Custom…", #selector(stayAwakeCustomChosen)))
        let forever = item("Until I turn it off", #selector(stayAwakeChosen(_:)), on: manualKeepAwake)
        forever.tag = 0
        sub.addItem(forever)
        if keepAwakeUntil != nil {
            sub.addItem(.separator())
            for (title, mins) in [("Add 30 minutes", 30), ("Add 1 hour", 60)] {
                let it = item(title, #selector(addStayAwakeChosen(_:)))
                it.tag = mins
                sub.addItem(it)
            }
            sub.addItem(item("Add time…", #selector(addStayAwakeCustomChosen)))
        }
        if manualKeepAwake || keepAwakeUntil != nil {
            sub.addItem(.separator())
            let off = item("Turn off", #selector(stayAwakeChosen(_:)))
            off.tag = -1
            sub.addItem(off)
        }
        if lidSetupOK {
            sub.addItem(.separator())
            let note = NSMenuItem(title: "The lid can be shut too", action: nil, keyEquivalent: "")
            note.isEnabled = false
            sub.addItem(note)
        }
        let holder = NSMenuItem(title: "Stay awake", action: nil, keyEquivalent: "")
        holder.submenu = sub
        holder.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        if manualKeepAwake { holder.subtitle = "Until you turn it off" }
        else if let u = keepAwakeUntil { holder.subtitle = "\(fmtDuration(Int(u.timeIntervalSinceNow))) left" }
        return holder
    }

    private func addStatusAndUsage(to menu: NSMenu) {
        if let latest = latestRelease {
            let u = item("Update available: Ephedrine \(latest.version)", #selector(openLatestRelease),
                         subtitle: "See what's new and how to upgrade")
            u.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            menu.addItem(u)
            menu.addItem(.separator())
        }
        let (glyph, tint) = statusCardGlyph()
        let cardItem = NSMenuItem()
        cardItem.view = StatusCardView(status: menuStatus(), glyph: glyph, tint: tint)
        menu.addItem(cardItem)
        addAlertItems(to: menu)
        menu.addItem(.separator())

        // Claude usage: a custom view with a bar per limit; clicking refreshes it in place
        let uv = UsageView()
        usageView = uv
        updateUsageView()
        uv.onClick = { [weak self] in self?.fetchUsage() }
        let uItem = NSMenuItem()
        uItem.view = uv
        menu.addItem(uItem)
    }

    // MARK: actions

    @objc func toggleAway() {
        if awayMode { exitAway("clicked I'm back"); return }
        if AwayReturn.ignoresLeaving(lastReturnByInput: lastAwayReturnByInput, now: Date()) {
            logLine("ignored I'm leaving: clicked just as input brought you back")
            return
        }
        enterAway()
    }

    @objc func toggleEnabled() { settings.enabled.toggle() }
    /// Stay awake also keeps it awake with the lid shut once lid setup is done
    /// (one control instead of separate lid-closed sessions).
    func stayAwakeIndefinitely() {
        manualKeepAwake = true; keepAwakeUntil = nil
        if lidSetupOK { lidState.session = .indefinite; lidState.tripped = nil }
        logLine("stay awake until turned off" + (lidSetupOK ? ", lid can be shut" : "")); evaluate()
    }
    func stayAwake(minutes: Int) { stayAwake(seconds: TimeInterval(minutes * 60)) }
    func stayAwake(seconds: TimeInterval) {
        manualKeepAwake = false
        let until = Date().addingTimeInterval(seconds)
        keepAwakeUntil = until
        if lidSetupOK { lidState.session = .until(until); lidState.tripped = nil }
        logLine("keep awake for \(fmtDuration(Int(seconds)))" + (lidSetupOK ? ", lid can be shut" : "")); evaluate()
    }
    func addStayAwake(seconds: TimeInterval) {
        // The timer ran out while the Add panel was open: start a fresh one of that length.
        guard let current = keepAwakeUntil else {
            if !manualKeepAwake { stayAwake(seconds: seconds) }
            return
        }
        let until = extendedUntil(current, by: seconds, now: Date())
        keepAwakeUntil = until
        if lidSetupOK { lidState.session = .until(until) }
        logLine("keep awake extended to \(clockStr(until))"); evaluate()
    }
    /// Opens the duration panel under the status item. Called from the menu
    /// (which has closed by the time its action runs) and from Settings.
    func showDurationPanel(_ mode: DurationPanelController.Mode, onSubmit: @escaping (TimeInterval) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let btn = self.statusItem.button else { return }
            self.durationPanel.show(below: btn, mode: mode, onSubmit: onSubmit)
        }
    }
    func startStayAwakeCustom() { showDurationPanel(.start) { [weak self] in self?.stayAwake(seconds: $0) } }
    @objc func stayAwakeCustomChosen() { startStayAwakeCustom() }
    @objc func addStayAwakeCustomChosen() { showDurationPanel(.add) { [weak self] in self?.addStayAwake(seconds: $0) } }
    @objc func addStayAwakeChosen(_ sender: NSMenuItem) { addStayAwake(seconds: TimeInterval(sender.tag * 60)) }
    func stopStayAwake() {
        manualKeepAwake = false; keepAwakeUntil = nil; lidState.session = nil
        logLine("stay awake turned off"); evaluate()
    }
    @objc func stayAwakeChosen(_ sender: NSMenuItem) {
        switch sender.tag {
        case -1: stopStayAwake()
        case 0:  stayAwakeIndefinitely()
        default: stayAwake(minutes: sender.tag)
        }
    }
    @objc func resetIdle() {
        clearMarkers(); wasBlocked = false; armed = false; cancelPendingSleep()
        awake.apply(system: false, display: false)
        logLine("manual reset, markers cleared"); evaluate()
    }
    func clearMarkers() {
        guard let items = try? fm.contentsOfDirectory(atPath: stateDir) else { return }
        for f in items where !f.hasPrefix(".") { try? fm.removeItem(atPath: "\(stateDir)/\(f)") }
    }

    /// Every settings change (menu or window) lands here, then re-evaluates.
    func settingChanged(_ key: String) {
        switch key {
        case "enabled":
            if !settings.enabled { awake.apply(system: false, display: false); armed = false; cancelPendingSleep() }
        case "autoContinueMode":
            let on = settings.autoContinueMode != .off
            if !on { retryPending = false }
            continueQueue.async { [weak self] in
                self?.continueStates.removeAll()
                if on { _ = terminalTabsSnapshot() }   // the "control Terminal" prompt, now if Terminal is open (else on a scan once it is)
            }
            logLine("auto-continue set to \(settings.autoContinueMode.rawValue)")
        case "autoResumeLimit":
            let on = settings.autoResumeLimit
            continueQueue.async { [weak self] in
                self?.limitEpisodes.removeAll()
                if on { _ = terminalTabsSnapshot() }
            }
            logLine("session-limit auto-resume \(on ? "on" : "off")")
        case "keepAwakeClaudeWorking":
            let on = settings.keepAwakeClaudeWorking
            if !on { claudeWorkingCached = false }
            continueQueue.async { if on { _ = terminalTabsSnapshot() } }
            logLine("keep-awake-while-claude-works \(on ? "on" : "off")")
        case "browserThrottleWarning":
            if settings.browserThrottleWarning { scanBrowsers() } else { clearBrowserState() }
            logLine("browser throttle warning \(settings.browserThrottleWarning ? "on" : "off")")
        case "appNapOffForAgents":
            if settings.appNapOffForAgents { applyAppNapOverride() } else { restoreAppNapOverride() }
        case "lidRemoteCheckIn":
            updateCheckInActivity()
            logLine("Remote Control check-ins \(settings.lidRemoteCheckIn ? "on" : "off")")
        case "checkForUpdates":
            latestRelease = nil
            lastUpdateCheck = nil   // on: check on the next tick
            logLine("update check \(settings.checkForUpdates ? "on" : "off")")
        case "usageAlert":
            usageAlerts = UsageAlertTracker()
            fetchUsage()
            return
        default: break
        }
        evaluate()
    }
    @objc func openSettings() { settingsWindow.show(settings: settings, controller: self) }
    @objc func openSetup() { setupWindow.show(settings: settings, controller: self) }

    /// Never shown (accessory app, no menu bar of its own), but its key
    /// equivalents are what make ⌘W close the settings window, ⌘Q quit and the
    /// usual editing keys work while the window is active.
    func installMainMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            holder.submenu = m
            main.addItem(holder)
        }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        sub("Ephedrine", [settingsItem,
                          NSMenuItem(title: "Quit Ephedrine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        sub("File", [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        sub("Edit", [NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo,
                     NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                     NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                     NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                     NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")])
        NSApp.mainMenu = main
    }

    /// Launching the app again (Finder, Spotlight, `open`) while it runs opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(); return false
    }
    @objc func openLogs() {
        if !fm.fileExists(atPath: logPath) { try? "".write(toFile: logPath, atomically: true, encoding: .utf8) }
        runTool("/usr/bin/open", [logPath])
    }
    @objc func quit() { NSApp.terminate(nil) }   // applicationWillTerminate releases assertions

    // MARK: persistence

}

// ───────────────────────────── main ─────────────────────────────

// `ephedrine uninstall` calls this before deleting the app, so no dead login item is left behind.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}
// And this, so the App Nap setting it wrote for other apps doesn't outlive it (quitting leaves it on purpose).
if CommandLine.arguments.contains("--restore-app-nap") {
    restoreAppNapOverride()
    flushLog()
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
