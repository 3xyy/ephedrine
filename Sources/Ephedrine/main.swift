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
let limitWaitCap: TimeInterval = 6 * 3600   // only wait out usage limits resetting within this (session limits are ≤5h)
let limitWaitGrace: TimeInterval = 5 * 60   // stay awake this long past a reset so the resume can land

// ───────────────────────────── Controller ─────────────────────────────

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let awake = AwakeAssertions()
    var tick: Timer?

    // persisted preferences (saved to UserDefaults as they change)
    let settings = AppSettings(defaults: .standard)
    var autoContinue: Bool { settings.autoContinueMode != .off }

    var manualKeepAwake = false
    var claudeWorkingCached = false
    var limitWaitPending = false                    // stay awake until a usage limit resets
    var retryPending = false                        // an auto-continue retry is scheduled

    // lid-closed mode (LidMode.swift)
    var lidSetupOK = false                          // sudoers rule installed
    var lidState = LidState()
    var lidActive = false                           // pmset disablesleep is on (by anyone)
    var lidApplying = false
    var lidRetryAfter = Date.distantPast
    var lidGuardNotedAt = Date.distantPast
    var lidPaused = false
    var lidLockedThisClose = false
    var lidFlipGeneration = 0                       // newest lid on/off request (stale completions are ignored)
    var terminalScanError = ""                      // main-thread copy of the last scan's osascript error
    var lidLastClosed = false
    var lidSleepWatch = LidSleepWatch()
    let lidWatchdog = LidWatchdog()
    var sigtermSource: DispatchSourceSignal?

    // continueQueue-confined state (only touched on continueQueue)
    var continueStates: [String: AutoContinueState] = [:]
    var limitEpisodes: [String: LimitEpisode] = [:]
    var lastTabCount = -1
    var lastWorkingSeen = false
    var terminalTabsSeen = -1                 // main-thread copy of the last scan's tab count (-1 = not yet)
    var errorSkipLogged: [String: String] = [:]   // tty → last logged reason (continueQueue only)

    var scanning = false
    var tickCount = 0
    // Sleep tracking. Code also runs during lid-closed "DarkWake" maintenance
    // wakes, which must never type or enable lid-closed mode. willSleep/didWake
    // are only a fallback: didWake has been seen firing inside a DarkWake, so
    // `fullyAwake` (kernel capabilities, read each tick) is what gates both.
    var systemSleeping = false
    var lastFullWake = Date.distantPast
    var lastWillSleep = Date.distantPast   // a sleep can take ~30s to land after willSleep
    var fullyAwake = true                  // from the kernel's capabilities each tick (see systemFullyAwake)
    let postWakeQuiet: TimeInterval = 60   // let the network come back before typing
    let continueQueue = DispatchQueue(label: "ephedrine.autocontinue")

    /// Settings snapshot handed to the background terminal scan, so the scan
    /// never reads main-thread-mutated properties across threads.
    struct ScanFlags {
        let mode: AutoContinueMode
        let resumeLimit: Bool
        let watchWorking: Bool
        let canType: Bool   // false while asleep / in a dark wake / just after waking
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
    var detectorScanInFlight = false
    var armed = false
    var awayMode = false
    var awayArmed = false
    var suspendedPids: [pid_t] = []
    var pausedNames: [String] = []
    var savedBrightness: Float = -1
    var awayTimer: Timer?
    var idleSince = Date()
    var keepAwakeUntil: Date?          // timed "keep awake for N"
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
    var awakeIcons: [MenuBarIconStyle: NSImage] = [:]   // made once per style; refreshIcon runs every tick

    let graceChoices: [(secs: Int, long: String)] = [
        (15, "15 seconds"), (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes")
    ]

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        settings.onChange = { [weak self] key in self?.settingChanged(key) }
        installMainMenu()
        recoverFromInterruptedAway()
        // `pkill`/`kill` (build.sh, logout scripts) → a normal quit, so
        // applicationWillTerminate un-pauses apps and releases lid-closed mode.
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { NSApp.terminate(nil) }
        sigtermSource?.resume()
        lidSetupOK = lidSetupInstalled()

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

        tick = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        logLine("Ephedrine started")
        refreshDisplaySleepIfStale()
        setupWindow.onClose = { [weak self] in self?.settings.setupDone = true }
        if settings.setupDone { fetchUsage() } else { openSetup() }
        evaluate()
    }

    func applicationWillTerminate(_ note: Notification) {
        awake.apply(system: false, display: false)
        if awayMode || lidPaused { resumeApps(); restoreBrightness() }   // never leave apps frozen
        clearAwayState()
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
        }

        let busy = activeSessionCount() > 0
        let manualActive = manualKeepAwake || keepAwakeUntil != nil || awayMode
        var extraActive = false
        if settings.enabled && !busy && !manualActive && !settings.detectors.isEmpty {
            // Detectors spawn `ps`, so they run off-main; evaluate uses the
            // result of the previous scan (≤1 tick stale; the lease-based
            // logic has minutes of slack).
            extraActive = extraActiveCached
            if !detectorScanInFlight {
                detectorScanInFlight = true
                let keys = settings.detectors
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let ps = PSCache()   // one ps spawn per format, shared by all detectors
                    let active = self?.detectors.contains { keys.contains($0.key) && $0.check(ps) } ?? false
                    DispatchQueue.main.async {
                        self?.extraActiveCached = active
                        self?.detectorScanInFlight = false
                    }
                }
            }
        } else {
            extraActiveCached = false
        }
        let claudeWorkingNow = settings.keepAwakeClaudeWorking && claudeWorkingCached
        let limitWaitNow = settings.autoResumeLimit && limitWaitPending
        let blocked = busy || extraActive || claudeWorkingNow || limitWaitNow
        updateLidMode(claudeBusy: settings.enabled && (busy || claudeWorkingNow || limitWaitNow || (autoContinue && retryPending)))

        if blocked && !wasBlocked { armed = false; cancelPendingSleep() }
        if !blocked && wasBlocked { armed = true; idleSince = Date(); cancelPendingSleep(); logLine("work finished, sleep countdown armed") }
        wasBlocked = blocked

        // The master switch gates the automatic behavior only; an explicit
        // "Stay awake" / "I'm leaving" always does what it says.
        let keepAwake = (settings.enabled && blocked) || manualActive
        if keepAwake {
            // Screen may sleep for pure background reasons: detector activity or a
            // session-limit wait (which can be hours), but not while Claude is
            // actively generating or during a manual override.
            let displayOff = settings.allowDisplaySleep && !busy && !manualActive && !claudeWorkingNow
                && (extraActive || limitWaitNow)
            if awake.apply(system: true, display: !displayOff) {
                logLine("keep-awake ON (\(displayOff ? "system-only" : "display+system"))")
            }
        } else {
            if awake.apply(system: false, display: false) { logLine("keep-awake OFF") }
        }

        var title = ""
        if manualActive, !busy, let until = keepAwakeUntil {
            title = fmtCountdown(Int(until.timeIntervalSinceNow))
        }

        // A one-off lid-closed session is an explicit "don't sleep", like a manual override.
        if settings.enabled && armed && !blocked && !manualActive && lidState.session == nil {
            if let t = autoSleepTitle() { title = t }
        } else {
            // Includes a manual override starting mid-warning: a stale
            // pendingSleepAt would otherwise sleep with no warning once it ends.
            cancelPendingSleep()
        }

        refreshIcon(active: keepAwake, title: title)

        // Usage reads the keychain, so not before the setup screen has explained that.
        if settings.setupDone && (lastUsageFetch == nil || Date().timeIntervalSince(lastUsageFetch!) > usageRefresh) { fetchUsage() }

        tickCount += 1
        if (autoContinue || settings.autoResumeLimit || settings.keepAwakeClaudeWorking) && tickCount % 3 == 0 && !scanning {   // ~every 9s
            scanning = true
            let flags = ScanFlags(mode: settings.autoContinueMode, resumeLimit: settings.autoResumeLimit,
                                  watchWorking: settings.keepAwakeClaudeWorking,
                                  canType: fullyAwake && Date().timeIntervalSince(lastFullWake) > postWakeQuiet)
            continueQueue.async { [weak self] in
                self?.scanTerminalForErrors(flags)
                DispatchQueue.main.async { self?.scanning = false }
            }
        }
    }

    /// Runs on continueQueue. Detects stopped API errors in Terminal tabs and
    /// types "continue" with the selected retry policy.
    func scanTerminalForErrors(_ flags: ScanFlags) {
        let now = Date()
        let (tabs, termErr) = terminalTabsSnapshot()

        if tabs.count != lastTabCount {
            let why = tabs.isEmpty ? " (\(termErr.isEmpty ? "no Terminal windows?" : termErr))" : ""
            logLine("terminal scan: \(tabs.count) tab(s)\(why)")
            lastTabCount = tabs.count
        }
        let n = tabs.count
        DispatchQueue.main.async { [weak self] in self?.terminalTabsSeen = n; self?.terminalScanError = termErr }

        if flags.watchWorking {
            let working = tabs.contains { claudeWorkingVisible($0.text) }
            if working != lastWorkingSeen && !tabs.isEmpty {   // 0 tabs = failed read
                lastWorkingSeen = working
                if working {
                    logLine("terminal: Claude working")
                } else {   // diagnostics: what the screen showed when "working" stopped matching
                    let seen = tabs.filter { claudeUIVisible($0.text) }
                        .map { "\($0.tty): " + statusLinesAbovePrompt($0.text).joined(separator: " | ") }
                    logLine("terminal: Claude not working. On screen: " + seen.joined(separator: "; "))
                }
            }
            DispatchQueue.main.async { [weak self] in self?.claudeWorkingCached = working }
        }
        // Asleep (lid closed), in a dark wake, or just woke: type nothing, and
        // leave retry/limit state untouched so it resumes once properly awake.
        guard flags.canType else { return }

        for tab in tabs {
            // Claude Code retrying by itself: the error episode is still going
            // (keeps the attempt count, and so the give-up limit, across its cycles).
            if var st = continueStates[tab.tty], claudeRetryingVisible(tab.text) {
                st.lastErrorAt = now
                continueStates[tab.tty] = st
                continue
            }
            // ── usage-limit auto-resume ──
            if flags.resumeLimit && usageLimitVisible(tab.text) {
                handleUsageLimit(tab, now: now)
                continue
            }
            // ── API-error auto-continue ──
            guard flags.mode != .off else { continue }
            let status = claudeErrorStatus(tab.text)
            switch status {
            case .skipped(let why) where errorSkipLogged[tab.tty] != why:
                errorSkipLogged[tab.tty] = why
                logLine("auto-continue: not answering the error on \(tab.tty): \(why)")
            case .none: errorSkipLogged[tab.tty] = nil
            default: break
            }
            guard status == .unanswered else { continue }
            if continueStates[tab.tty] == nil {
                logLine("auto-continue: error detected on \(tab.tty), first try in \(Int(flags.mode.delay(0)))s")
            }
            var st = continueStates[tab.tty]
                ?? AutoContinueState(attempts: 0, nextTryAt: now.addingTimeInterval(flags.mode.delay(0)), lastErrorAt: now)
            st.lastErrorAt = now
            if now >= st.nextTryAt && st.attempts < flags.mode.maxAttempts {
                sendContinue(tty: tab.tty)
                st.attempts += 1
                st.nextTryAt = now.addingTimeInterval(flags.mode.delay(st.attempts))
                logLine("auto-continue #\(st.attempts) → \(tab.tty)")
                if flags.mode.maxAttempts != Int.max && st.attempts >= flags.mode.maxAttempts {
                    let n = UNMutableNotificationContent()
                    n.title = "Ephedrine"
                    n.body = "Auto-continue gave up after \(flags.mode.maxAttempts) tries (\(tab.tty))."
                    UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: "ka_giveup_\(tab.tty)", content: n, trigger: nil))
                }
            }
            continueStates[tab.tty] = st
        }

        if flags.resumeLimit { resumeDueLimits(tabs, now: now) }

        // forget API-error tabs that have been error-free for 90s (recovered);
        // 0 tabs = the Terminal read failed, which says nothing about recovery
        for (tty, st) in continueStates where !tabs.isEmpty && now.timeIntervalSince(st.lastErrorAt) > 90 {
            continueStates.removeValue(forKey: tty)
            logLine("auto-continue reset (\(tty) recovered)")
        }
        // A retry still to come counts as Claude working (keeps lid-closed mode on).
        let retrying = flags.mode != .off && continueStates.values.contains { $0.attempts < flags.mode.maxAttempts }
        DispatchQueue.main.async { [weak self] in self?.retryPending = retrying }

        // Stay awake only for a scheduled wait, never just because limit text
        // is on screen. Stale text would otherwise hold the Mac awake for days.
        let pending = limitEpisodes.values.contains { ep in ep.resumeAt.map { now < $0 + limitWaitGrace } ?? false }
        DispatchQueue.main.async { [weak self] in self?.limitWaitPending = pending }
    }

    /// Runs on continueQueue. A usage-limit wall is on this tab: answer Claude
    /// Code's menu with a "wait" option, then schedule staying awake until the
    /// reset (only if it's within limitWaitCap).
    func handleUsageLimit(_ tab: (tty: String, text: String), now: Date) {
        let tty = tab.tty
        var ep = limitEpisodes[tty] ?? LimitEpisode()
        defer { limitEpisodes[tty] = ep }

        if !ep.menuHandled && menuVisible(tab.text) {
            ep.menuHandled = true   // one try per episode, never keep typing into a menu
            if let choice = limitMenuChoice(tab.text) {
                sendToTerminal(choice.number, tty: tty)
                if case .claudeAutoContinue = choice { ep.claudeResumes = true }
                logLine("usage limit on \(tty): picked option \(choice.number), "
                        + (ep.claudeResumes ? "Claude Code continues by itself at reset" : "wait for reset"))
            } else {
                let labels = menuOptions(tab.text).map { "\($0.number). \($0.label)" }.joined(separator: " | ")
                logLine("usage limit on \(tty): no wait option in menu, left it alone [\(labels)]")
            }
        }
        if claudeAutoResumeVisible(tab.text) { ep.claudeResumes = true }

        guard ep.resumeAt == nil, !ep.noted else { return }
        // Something besides the limit text itself must say this is Claude Code,
        // so a pasted doc or log in a plain shell can't schedule a keystroke.
        guard ep.menuHandled || ep.claudeResumes || claudeUIVisible(tab.text) else { return }
        guard let reset = parseResetTime(tab.text, now: now) else {
            ep.noted = true
            logLine("usage limit on \(tty): no reset time on screen, not waiting"); return
        }
        guard reset.timeIntervalSince(now) <= limitWaitCap else {
            ep.noted = true
            logLine("usage limit on \(tty): resets \(clockStr(reset)), too far off to keep the Mac awake for"); return
        }
        ep.resumeAt = reset.addingTimeInterval(60)
        logLine("usage limit on \(tty): resets \(clockStr(reset)), staying awake; "
                + (ep.claudeResumes ? "Claude Code will continue by itself" : "will type continue at \(clockStr(ep.resumeAt))"))
    }

    /// Runs on continueQueue. Types "continue" for waits whose reset has
    /// passed, and forgets episodes whose limit is no longer on screen.
    func resumeDueLimits(_ tabs: [(tty: String, text: String)], now: Date) {
        let byTty = Dictionary(tabs.map { ($0.tty, $0.text) }, uniquingKeysWith: { a, _ in a })
        for tty in Array(limitEpisodes.keys) {
            guard var ep = limitEpisodes[tty] else { continue }
            let text = byTty[tty]
            let showing = text.map(usageLimitVisible) ?? false
            if !showing && !tabs.isEmpty { limitEpisodes.removeValue(forKey: tty); continue }   // 0 tabs = failed read; keep
            guard let at = ep.resumeAt, now >= at, !ep.resumed, let text = text else { continue }
            ep.resumed = true
            if now > at + limitWaitGrace {
                logLine("usage limit on \(tty): reset passed while the Mac was asleep, not typing")
            } else if ep.claudeResumes {
                logLine("usage limit on \(tty): reset passed, Claude Code continues by itself")
            } else if claudeUIVisible(text) && !menuVisible(text) && !claudeWorkingVisible(text)
                        && !claudeAutoResumeVisible(text) {
                sendContinue(tty: tty)
                logLine("usage limit on \(tty): reset passed → typed continue")
            } else {
                logLine("usage limit on \(tty): reset passed, but the screen isn't at a plain prompt, so not typing")
            }
            limitEpisodes[tty] = ep
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
        awayMode = true; awayArmed = false
        suspendApps()
        dimScreen()
        persistAwayState()   // crash-recovery: next launch un-freezes and restores brightness
        awayTimer?.invalidate()
        awayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.awayCheck() }
        logLine("away mode ON: paused \(suspendedPids.count) apps\(pausedList), dimmed the screen")
        awayNotify("Away mode on", "Paused \(suspendedPids.count) apps and dimmed the screen. Move the mouse or press a key when you're back.")
        evaluate()
    }

    func exitAway() {
        awayTimer?.invalidate(); awayTimer = nil
        resumeApps()
        restoreBrightness()
        clearAwayState()
        awayMode = false; awayArmed = false
        logLine("away mode OFF: resumed apps, restored brightness")
        awayNotify("Welcome back", "Resumed your apps and restored screen brightness.")
        evaluate()
    }

    /// Runs every 1s while away: arm after a brief absence, then restore the
    /// instant you move the mouse or type.
    func awayCheck() {
        guard awayMode else { return }
        let idle = hidIdleSeconds()
        if !awayArmed {
            if idle > 4 { awayArmed = true; logLine("away mode armed (you left)") }
        } else if idle < 2 {
            exitAway()
        }
    }

    /// Apps "I'm leaving" never pauses. Terminals and editors can host Claude
    /// Code, and pausing the host app stalls its terminal and hangs Claude. Add
    /// more without rebuilding:
    ///   defaults write io.github.3xyy.ephedrine awayKeepRunning -array-add <bundle id>
    static let awayKeepRunning: Set<String> = [
        "com.apple.finder", "io.github.3xyy.ephedrine",
        // terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        // editors with built-in terminals
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed",
        // Claude app
        "com.anthropic.claudefordesktop",
        // Xcode, Simulator, iPhone Mirroring
        "com.apple.dt.Xcode", "com.apple.iphonesimulator", "com.apple.ScreenContinuity",
        // browsers
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly", "com.brave.Browser.dev",
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.apple.Safari",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
        // never freeze an active call/meeting
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.skype.skype",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
    ]

    func suspendApps() {
        suspendedPids.removeAll()
        pausedNames.removeAll()
        let allow = Self.awayKeepRunning.union(settings.awayKeepRunning)
        let browserWords = ["chrome", "chromium", "brave", "safari", "edge", "arc", "firefox", "playwright"]
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier > 1, app.processIdentifier != getpid() else { continue }
            if allow.contains(app.bundleIdentifier ?? "") { continue }
            let name = (app.localizedName ?? "").lowercased()
            if browserWords.contains(where: { name.contains($0) }) { continue }
            kill(app.processIdentifier, SIGSTOP)
            suspendedPids.append(app.processIdentifier)
            pausedNames.append(app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)")
        }
    }
    /// Names of what suspendApps last paused (for the log).
    var pausedList: String { pausedNames.isEmpty ? "" : " (" + pausedNames.joined(separator: ", ") + ")" }

    func resumeApps() {
        for pid in suspendedPids { kill(pid, SIGCONT) }
        logLine("resumed \(suspendedPids.count) apps")
        suspendedPids.removeAll()
    }

    // ── Away crash-recovery: if we die while apps are SIGSTOPped / screen is
    // dimmed, the state file lets the next launch undo it. SIGCONT to a pid
    // that isn't stopped (or was reused) is harmless.

    func persistAwayState() {
        let obj: [String: Any] = ["pids": suspendedPids.map(Int.init), "brightness": Double(savedBrightness)]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: URL(fileURLWithPath: awayStatePath))
        }
        try? suspendedPids.map(String.init).joined(separator: " ").write(toFile: pausedPidsPath, atomically: true, encoding: .utf8)
    }
    func clearAwayState() { try? fm.removeItem(atPath: awayStatePath); try? fm.removeItem(atPath: pausedPidsPath) }
    func recoverFromInterruptedAway() {
        guard let d = fm.contents(atPath: awayStatePath),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        let pids = (obj["pids"] as? [Int]) ?? []
        for pid in pids { kill(pid_t(pid), SIGCONT) }
        if let b = obj["brightness"] as? Double, b >= 0 {
            savedBrightness = Float(b)
            restoreBrightness()
        }
        clearAwayState()
        if !pids.isEmpty { logLine("recovered from an interrupted away mode, resumed \(pids.count) apps") }
    }

    typealias BrightGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias BrightSet = @convention(c) (UInt32, Float) -> Int32
    let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    func dimScreen() {
        // Never dim unless the current brightness was read successfully:
        // otherwise restoreBrightness() has nothing to restore to and the
        // screen would stay black.
        guard let h = dlopen(displayServicesPath, RTLD_LAZY),
              let gp = dlsym(h, "DisplayServicesGetBrightness"),
              let sp = dlsym(h, "DisplayServicesSetBrightness") else { logLine("dim unavailable"); return }
        let disp = CGMainDisplayID()
        var cur: Float = 0.5
        guard unsafeBitCast(gp, to: BrightGet.self)(disp, &cur) == 0 else {
            logLine("didn't dim: couldn't read the current brightness"); return
        }
        savedBrightness = cur
        _ = unsafeBitCast(sp, to: BrightSet.self)(disp, 0.0)
    }

    func restoreBrightness() {
        guard savedBrightness >= 0, let h = dlopen(displayServicesPath, RTLD_LAZY),
              let sp = dlsym(h, "DisplayServicesSetBrightness") else { savedBrightness = -1; return }
        _ = unsafeBitCast(sp, to: BrightSet.self)(CGMainDisplayID(), savedBrightness)
        savedBrightness = -1
    }

    func awayNotify(_ t: String, _ b: String) {
        let c = UNMutableNotificationContent(); c.title = t; c.body = b
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka_away", content: c, trigger: nil))
    }

    // MARK: Claude usage

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

    func refreshIcon(active: Bool, title: String) {
        guard let btn = statusItem.button else { return }
        // Laptop for a lid session the user started, or `pmset disablesleep` set
        // by hand (both easy to forget); Claude-driven lid mode ends by itself,
        // so it shows the normal awake mug.
        let lidSession = lidActive && (lidState.session != nil || !fm.fileExists(atPath: lidMarkerPath))
        let style = settings.menuBarIconStyle
        if !awayMode && !lidSession && (active || lidActive) {
            if awakeIcons[style] == nil { awakeIcons[style] = menuBarAwakeIcon(style: style) }
            btn.image = awakeIcons[style]
        } else {
            let name = awayMode ? "figure.walk"
                : lidSession ? "laptopcomputer"
                : (!settings.enabled ? "moon" : "moon.zzz")
            btn.image = menuBarSymbolIcon(name, tint: menuBarStateTint(style: style, away: awayMode, lidSession: lidSession))
        }
        btn.title = title.isEmpty ? "" : " " + title
        btn.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }

    // MARK: menu

    func statusText() -> String {
        if awayMode { return "Away: \(suspendedPids.count) apps paused, screen dimmed" }
        if lidPaused { return "Lid shut: \(suspendedPids.count) apps paused" }
        if manualKeepAwake { return "Awake until you turn it off" }
        if let until = keepAwakeUntil { return "Awake for \(fmtCountdown(Int(until.timeIntervalSinceNow))) more" }
        if !settings.enabled { return "Off, macOS sleeps as usual" }
        let n = activeSessionCount()
        if n > 0 { return "Awake, Claude is working" + (n > 1 ? " (\(n) sessions)" : "") }
        if settings.keepAwakeClaudeWorking && claudeWorkingCached { return "Awake, Claude is busy in Terminal" }
        if settings.autoResumeLimit && limitWaitPending { return "Awake until a usage limit resets" }
        if extraActiveCached { return "Awake, a background task is running" }
        if armed && settings.finishMode != .stayNormal && autoSleepAllowed() {
            if let at = pendingSleepAt { return "Sleeping in \(max(0, Int(at.timeIntervalSinceNow)))s…" }
            return "Idle, sleeping in \(fmtCountdown(graceRemaining()))"
        }
        return "Idle"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if settings.setupDone && (lastUsageFetch == nil || Date().timeIntervalSince(lastUsageFetch!) > 60) { fetchUsage() }
        refreshDisplaySleepIfStale()
        menu.removeAllItems()
        addStatusAndUsage(to: menu)
        menu.addItem(item("Keep awake while Claude works", #selector(toggleEnabled), on: settings.enabled,
                          subtitle: settings.enabled ? nil : "Off, so macOS sleeps as usual"))
        let s = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        menu.addItem(s)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ephedrine", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Menu item with an action on self.
    func item(_ title: String, _ action: Selector?, on: Bool = false,
                      subtitle: String? = nil, tip: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        it.toolTip = tip
        it.subtitle = subtitle
        return it
    }

    private func addStatusAndUsage(to menu: NSMenu) {
        let header = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let lid = lidStatusText() {
            let l = NSMenuItem(title: lid, action: nil, keyEquivalent: "")
            l.isEnabled = false
            menu.addItem(l)
        }
        menu.addItem(.separator())

        // Claude usage: a custom view with a bar per limit; clicking refreshes it in place
        let uv = UsageView()
        usageView = uv
        updateUsageView()
        uv.onClick = { [weak self] in self?.fetchUsage() }
        let uItem = NSMenuItem()
        uItem.view = uv
        menu.addItem(uItem)

        menu.addItem(.separator())
    }

    // MARK: actions

    @objc func toggleAway() {
        if awayMode { exitAway() } else { enterAway() }
    }

    @objc func toggleEnabled() { settings.enabled.toggle() }
    func stayAwakeIndefinitely() { manualKeepAwake = true; keepAwakeUntil = nil; logLine("stay awake until turned off"); evaluate() }
    func stayAwake(minutes: Int) {
        manualKeepAwake = false
        keepAwakeUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        logLine("keep awake for \(minutes) min"); evaluate()
    }
    func stopStayAwake() { manualKeepAwake = false; keepAwakeUntil = nil; evaluate() }
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
                if on { _ = terminalTabsSnapshot() }   // trigger the "control Terminal" permission prompt now
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

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
