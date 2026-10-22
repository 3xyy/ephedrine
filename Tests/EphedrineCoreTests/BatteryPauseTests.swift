import Testing
import Foundation
@testable import EphedrineCore

// ── A usage-limit wait across the lid closing, on battery ──

private let at = { (t: TimeInterval) in Date(timeIntervalSince1970: t) }

@Test func aLimitWaitKeepsLidModeWhenTheOwnerIsThereOrTheLidIsShut() {
    // 2026-10-20: limit at 23:24, reset 1:30, lid closed at 00:29 with lid mode
    // off (61 min to go), so the Mac slept through the reset.
    let reset = at(0)
    let lidClosesAt = at(-61 * 60)
    #expect(!limitWaitHolds(resumeAts: [reset], now: lidClosesAt, onBattery: true))   // keep-awake: last hour only
    #expect(limitWaitHoldsLid(resumeAts: [reset], now: lidClosesAt, onBattery: true, lidShut: false, userIdle: 20))
    #expect(limitWaitHoldsLid(resumeAts: [reset], now: lidClosesAt, onBattery: true, lidShut: true, userIdle: 9000))
    // Walked away with the lid open: let macOS idle-sleep as before.
    #expect(!limitWaitHoldsLid(resumeAts: [reset], now: lidClosesAt, onBattery: true, lidShut: false,
                               userIdle: limitWaitPresence))
    // The last hour and the charger work as they did.
    #expect(limitWaitHoldsLid(resumeAts: [reset], now: at(-30 * 60), onBattery: true, lidShut: false, userIdle: 9000))
    #expect(limitWaitHoldsLid(resumeAts: [reset], now: lidClosesAt, onBattery: false, lidShut: false, userIdle: 9000))
    // Nothing scheduled, or the reset long past: nothing to hold.
    #expect(!limitWaitHoldsLid(resumeAts: [], now: lidClosesAt, onBattery: true, lidShut: true, userIdle: 0))
    #expect(!limitWaitHoldsLid(resumeAts: [reset], now: at(limitWaitGrace), onBattery: true, lidShut: true, userIdle: 0))
}

// ── Pausing Claude at the battery limit ──

private func bp(enabled: Bool = true, stopped: Bool = true, onBattery: Bool = true, lidShut: Bool = false,
                leaving: Bool = false, awake: Bool = true, idle: TimeInterval = 0, awayAfter: TimeInterval = 300,
                busy: Bool = true, t: TimeInterval) -> BatteryPauseInputs {
    BatteryPauseInputs(enabled: enabled, stopped: stopped, onBattery: onBattery, lidShutAlone: lidShut, leaving: leaving,
                       fullyAwake: awake, idle: idle, awayAfter: awayAfter, claudeBusy: busy, now: at(t))
}

@Test func aShortCountdownDoesNotMakeReadingCountAsAway() {
    // The countdown can be 15 seconds; reading Claude's reply that long isn't leaving.
    var p = BatteryPause()
    #expect(p.step(bp(idle: 30, awayAfter: 15, t: 0)) == .warnHere)
    #expect(p.step(bp(idle: BatteryPause.minAwayAfter, awayAfter: 15, t: 3)) == .headsUp)
}

@Test func imLeavingCountsAsAway() {
    // "I'm leaving" sleeps the Mac a minute after Claude stops needing it, so
    // at the limit Claude must be paused at once, not after the idle wait.
    var p = BatteryPause()
    #expect(p.step(bp(leaving: true, idle: 2, t: 0)) == .pauseAndSleep)
    // Back is when "I'm leaving" has ended, or the next tick would pause again.
    #expect(p.step(bp(leaving: true, idle: 1, t: 600)) == nil)
    #expect(p.step(bp(leaving: false, idle: 1, t: 601)) == .resume(.back))
}

@Test func atTheLimitWithTheLidShutClaudeIsPausedAndTheMacSleeps() {
    // 2026-10-21 13:08: battery at 30% with the lid shut, a subagent mid-response.
    var p = BatteryPause()
    #expect(p.step(bp(lidShut: true, idle: 9000, t: 0)) == .pauseAndSleep)
    #expect(p.paused)
    #expect(p.step(bp(lidShut: true, idle: 9000, t: 3)) == nil)
}

@Test func atTheLimitWithTheOwnerThereItOnlySaysSo() {
    var p = BatteryPause()
    #expect(p.step(bp(idle: 2, t: 0)) == .warnHere)
    #expect(p.step(bp(idle: 2, t: 3)) == nil)                         // once
    #expect(!p.paused)
    var idle = BatteryPause()
    #expect(idle.step(bp(idle: 2, busy: false, t: 0)) == nil)        // no Claude working, nothing to say
}

@Test func walkingAwayWithTheLidOpenGetsAHeadsUpThenThePause() {
    var p = BatteryPause()
    #expect(p.step(bp(idle: 299, t: 0)) == .warnHere)
    #expect(p.step(bp(idle: 300, t: 1)) == .headsUp)
    #expect(p.step(bp(idle: 300 + BatteryPause.headsUpDelay - 1, t: 1 + BatteryPause.headsUpDelay - 1)) == nil)
    #expect(p.step(bp(idle: 300 + BatteryPause.headsUpDelay, t: 1 + BatteryPause.headsUpDelay)) == .pauseAndSleep)
    #expect(p.paused)
}

@Test func touchingTheMacDuringTheHeadsUpCancelsIt() {
    var p = BatteryPause()
    #expect(p.step(bp(idle: 400, t: 0)) == .headsUp)
    #expect(p.step(bp(idle: 1, t: 5)) == .cancelled)
    #expect(p.step(bp(idle: 2, t: 6)) == .warnHere)
    #expect(!p.paused)
}

@Test func awayMeansAwakeWithTheLidOpen() {
    // A nap with the lid open isn't the owner leaving; the idle clock means nothing there.
    var p = BatteryPause()
    #expect(p.step(bp(awake: false, idle: 9000, t: 0)) == nil)
    // With the lid shut it pauses even in a nap: Claude would run in every one.
    #expect(p.step(bp(lidShut: true, awake: false, idle: 9000, t: 3)) == .pauseAndSleep)
}

@Test func pluggingInOrComingBackResumesClaude() {
    var p = BatteryPause()
    _ = p.step(bp(lidShut: true, t: 0))
    #expect(p.step(bp(stopped: false, onBattery: false, t: 600)) == .resume(.pluggedIn))
    #expect(!p.paused)

    var q = BatteryPause()
    _ = q.step(bp(lidShut: true, idle: 9000, t: 0))
    #expect(q.step(bp(lidShut: false, awake: false, idle: 1, t: 600)) == nil)          // a dark wake isn't you
    #expect(q.step(bp(lidShut: false, idle: 9000, t: 700)) == nil)                     // awake, nobody touched it
    #expect(q.step(bp(lidShut: false, idle: 1, t: 800)) == .resume(.back))

    var r = BatteryPause()
    _ = r.step(bp(idle: 400, t: 0)); _ = r.step(bp(idle: 410, t: 10))
    #expect(r.paused)
    #expect(r.step(bp(idle: 1, t: 10 + BatteryPause.backAfter - 1)) == nil)          // the moment it paused
    #expect(r.step(bp(idle: 1, t: 10 + BatteryPause.backAfter)) == .resume(.back))
}

@Test func turningTheSettingOffResumesAndStopsIt() {
    var p = BatteryPause()
    _ = p.step(bp(lidShut: true, t: 0))
    #expect(p.step(bp(enabled: false, lidShut: true, t: 5)) == .resume(.turnedOff))
    var off = BatteryPause()
    #expect(off.step(bp(enabled: false, lidShut: true, t: 0)) == nil)
    #expect(off.step(bp(enabled: false, idle: 2, t: 3)) == nil)
}

@Test func aboveTheLimitNothingHappens() {
    var p = BatteryPause()
    #expect(p.step(bp(stopped: false, lidShut: true, idle: 9000, t: 0)) == nil)
    #expect(p.step(bp(stopped: false, idle: 2, t: 3)) == nil)
}

// ── What gets paused ──

/// The real shapes on 2026-10-21: cmux panes run `login → -zsh → claude`, one
/// session started the daemon, the daemon's host runs a session with no shell,
/// and the Chrome extension's host, the desktop app and cmux's hook bridge
/// mention Claude too.
private let table: [(pid: Int32, ppid: Int32, comm: String, args: String)] = [
    (15072, 1,     "/usr/bin/login", "/usr/bin/login -flp uv /bin/bash --noprofile"),
    (15073, 15072, "-/bin/zsh", "-/bin/zsh"),          // how ps shows a cmux pane's login shell
    (15423, 15073, "/Users/uv/.local/bin/claude", "/Users/uv/.local/bin/claude --settings /Users/uv/.cmuxterm/claude-settings/8d4b.js"),
    (90209, 15423, "/Users/uv/.local/bin/claude", "/Users/uv/.local/bin/claude daemon run --origin tr"),
    (90289, 90209, "claude bg-pty-host", "claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/9f1f"),
    (34216, 15423, "/Applications/cmux.app/Contents/Resources/bin/cmux", "/Applications/cmux.app/Contents/Resources/bin/cmux hooks claude"),
    (40001, 15423, "/bin/zsh", "/bin/zsh -c xcodebuild test"),
    (40002, 40001, "/usr/bin/xcodebuild", "/usr/bin/xcodebuild test"),
    (40003, 15423, "/usr/bin/caffeinate", "caffeinate -i -t 300"),
    (63989, 1,     "/Users/uv/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", "/Users/uv/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude --bg-pty-host /tmp/cc"),
    (64016, 63989, "/Users/uv/.local/share/claude/versions/2.1.305", "/Users/uv/.local/share/claude/versions/2.1.305 --session-id 5f64"),
    (20777, 1,     "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"),
    (20854, 20777, "/Users/uv/.local/bin/claude", "/Users/uv/.local/bin/claude --chrome-native-host"),
    (50000, 1,     "/Applications/Claude.app/Contents/MacOS/Claude", "/Applications/Claude.app/Contents/MacOS/Claude"),
    (50100, 1,     "/Applications/cmux.app/Contents/MacOS/cmux", "/Applications/cmux.app/Contents/MacOS/cmux"),
    (60000, 1,     "/Users/uv/Applications/Ephedrine.app/Contents/MacOS/Ephedrine", "Ephedrine"),
    (60001, 60000, "/bin/sh", "/bin/sh -c while kill -0 60000"),
]

private var procs: [ProcEntry] { table.map { ProcEntry(pid: $0.pid, ppid: $0.ppid, start: Int64($0.pid) * 10) } }
private var info: [Int32: ProcText] { Dictionary(uniqueKeysWithValues: table.map { ($0.pid, ProcText(comm: $0.comm, args: $0.args)) }) }

@Test func claudeCodeIsTheCLIItsDaemonAndItsVersionedBinary() {
    #expect(isClaudeCode(ProcText(comm: "/Users/uv/.local/bin/claude", args: "/Users/uv/.local/bin/claude --session-id x")))
    #expect(isClaudeCode(ProcText(comm: "claude bg-pty-host", args: "claude bg-pty-host --bg-pty-host /tmp/x")))
    #expect(isClaudeCode(ProcText(comm: "/Users/uv/.local/share/claude/versions/2.1.305", args: "x --session-id y")))
    #expect(isClaudeCode(ProcText(comm: "/opt/homebrew/bin/node", args: "node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js")))
    #expect(!isClaudeCode(ProcText(comm: "/Users/uv/.local/bin/claude", args: "/Users/uv/.local/bin/claude --chrome-native-host")))
    #expect(!isClaudeCode(ProcText(comm: "/Applications/Claude.app/Contents/MacOS/Claude", args: "Claude")))
    #expect(!isClaudeCode(ProcText(comm: "/Applications/cmux.app/Contents/Resources/bin/cmux", args: "cmux hooks claude")))
}

@Test func thePausePlanTakesClaudeTreesThenTheirShells() {
    let plan = claudePausePlan(procs: procs, info: info, selfPID: 60000).map(\.pid)
    // Every Claude tree, with what it runs, but not caffeinate: its sleep
    // assertion would outlast the pause and keep the Mac awake.
    #expect(Set(plan) == [15423, 90209, 90289, 34216, 40001, 40002, 63989, 64016, 15073])
    // The shell a session runs in goes last: stopped first and resumed last, so
    // zsh never sees its job stop (it would take the terminal back).
    #expect(plan.last == 15073)
    #expect(plan.firstIndex(of: 15423)! < plan.firstIndex(of: 40002)!)       // parents before children
    // Never the desktop app, the browser's host, cmux, launchd or Ephedrine's own watchdog.
    #expect(Set(plan).isDisjoint(with: [50000, 20854, 20777, 50100, 15072, 1, 60000, 60001]))
}

@Test func ashellIsOnlyAddedAboveASession() {
    #expect(isJobControlShell("-zsh") && isJobControlShell("/bin/zsh") && isJobControlShell("/opt/homebrew/bin/fish"))
    #expect(!isJobControlShell("/usr/bin/login") && !isJobControlShell("/Applications/cmux.app/Contents/MacOS/cmux"))
    // The daemon-hosted session (no shell above it) brings no shell.
    let lone = claudePausePlan(procs: procs.filter { [63989, 64016].contains($0.pid) }, info: info, selfPID: 1)
    #expect(lone.map(\.pid) == [63989, 64016])
}

@Test func nothingToPauseWithoutClaude() {
    let noClaude = procs.filter { ![15423, 90209, 90289, 63989, 64016].contains($0.pid) && $0.ppid != 15423 }
    #expect(claudePausePlan(procs: noClaude, info: info, selfPID: 60000).isEmpty)
}

// ── After a sleep Ephedrine caused, a "went to sleep" error is answered ──

private let wentToSleepScreen = """
⏺ Reading the profiles code.

⏺ API Error: Your computer went to sleep mid-response. The response above may be incomplete.

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ auto mode on
"""

@Test func aWentToSleepErrorIsAnsweredOnlyWhenEphedrineSleptTheMac() {
    #expect(claudeErrorStatus(wentToSleepScreen) != .unanswered)                       // the owner's own sleep
    #expect(claudeErrorStatus(wentToSleepScreen, sleepWasOurs: true) == .unanswered)
    #expect(!cmuxLiveTailShows(.apiError, in: wentToSleepScreen))
    #expect(cmuxLiveTailShows(.apiErrorAfterOurSleep, in: wentToSleepScreen))
    #expect(CmuxLiveTrigger.apiErrorAfterOurSleep.purpose == .continuePrompt)
}

@Test func pausingClaudeAtTheLimitIsOnByDefault() {
    let name = "ephedrine-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    let s = AppSettings(defaults: d)
    #expect(s.batteryPauseClaude)
    s.batteryPauseClaude = false
    #expect(!AppSettings(defaults: d).batteryPauseClaude)
}
