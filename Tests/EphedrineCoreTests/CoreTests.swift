import Testing
import Foundation
@testable import EphedrineCore

// ── Parsing ──

@Test func parseISOMicroseconds() {
    // The exact shape Anthropic's usage endpoint returns (6 fractional digits).
    let d = parseISO("2026-06-30T01:20:00.943766+00:00")
    #expect(d != nil)
    #expect(abs(d!.timeIntervalSince1970 - 1782782400.943766) < 1.0)
}

@Test func parseISOVariants() {
    #expect(parseISO("2026-06-30T01:20:00Z") != nil)
    #expect(parseISO("2026-06-30T01:20:00+05:30") != nil)
    #expect(parseISO("2026-06-30T01:20:00.5Z") != nil)
    #expect(parseISO("not a date") == nil)
}

@Test func countdownFormatting() {
    #expect(fmtCountdown(0) == "0s")
    #expect(fmtCountdown(-5) == "0s")
    #expect(fmtCountdown(59) == "59s")
    #expect(fmtCountdown(60) == "1:00")
    #expect(fmtCountdown(125) == "2:05")
    #expect(fmtCountdown(3600) == "60:00")
}

@Test func markerExpiryParsing() {
    #expect(markerExpiry(contents: "1750000000\n", mtime: nil, leaseFallback: 300) == 1750000000)
    let m = Date(timeIntervalSince1970: 1000)
    #expect(markerExpiry(contents: "garbage", mtime: m, leaseFallback: 300) == 1300)
    #expect(markerExpiry(contents: nil, mtime: m, leaseFallback: 300) == 1300)
    #expect(markerExpiry(contents: nil, mtime: nil, leaseFallback: 300) == nil)
}

@Test func appleScriptQuoting() {
    #expect(appleScriptQuoted("continue") == "\"continue\"")
    #expect(appleScriptQuoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
}

// ── Auto-continue modes ──

@Test func backoffDelaysCapAt300() {
    let m = AutoContinueMode.backoff
    #expect(m.delay(0) == 30)
    #expect(m.delay(1) == 60)
    #expect(m.delay(2) == 120)
    #expect(m.delay(3) == 240)
    #expect(m.delay(4) == 300)
    #expect(m.delay(10) == 300)
    #expect(m.maxAttempts == 8)
}

@Test func fastAndPersistentModes() {
    #expect(AutoContinueMode.fast.delay(3) == 15)
    #expect(AutoContinueMode.fast.maxAttempts == 5)
    #expect(AutoContinueMode.persistent.delay(99) == 60)
    #expect(AutoContinueMode.persistent.maxAttempts == Int.max)
    #expect(AutoContinueMode.off.maxAttempts == 0)
}

// Final review C1: a cmux send that typed nothing is the episode's one try.
// Counted as a try, a skip that kept happening left a retry pending forever
// in persistent mode, which held a lid-shut Mac awake and kept "I'm leaving" up.
@Test func skippedSendEndsTheEpisode() {
    let t0 = Date(timeIntervalSince1970: 1000)
    let s = continueAfterTry(.skipped, attempts: 0, nextTryAt: t0, mode: .persistent, cmux: true, now: t0)
    #expect(s.attempts == Int.max)
    #expect(s.stuck)
    #expect(!s.gaveUp)
    #expect(!continueRetrying(attempts: [s.attempts], mode: .persistent))
    // Counted as one try, as before the fix, it was still retrying.
    #expect(continueRetrying(attempts: [1], mode: .persistent))
}
@Test func skipsNeverReportGivingUp() {
    let t0 = Date(timeIntervalSince1970: 1000)
    for before in 0..<5 {   // whichever try it is, even the last a fast mode allows
        let s = continueAfterTry(.skipped, attempts: before, nextTryAt: t0, mode: .fast, cmux: true, now: t0)
        #expect(!s.gaveUp)
        #expect(s.attempts == 5)
        #expect(!continueRetrying(attempts: [s.attempts], mode: .fast))
    }
    // Only a cmux pane is marked stuck.
    #expect(!continueAfterTry(.skipped, attempts: 0, nextTryAt: t0, mode: .fast, cmux: false, now: t0).stuck)
}
@Test func typedAndNotAwakeTriesKeepTheirCount() {
    let t0 = Date(timeIntervalSince1970: 1000)
    // Typed: one more try, the next after the mode's delay; the last allowed one gives up.
    let a = continueAfterTry(.typed, attempts: 0, nextTryAt: t0, mode: .fast, cmux: true, now: t0)
    #expect(a == ContinueTryStep(attempts: 1, nextTryAt: t0 + 15))
    #expect(continueRetrying(attempts: [a.attempts], mode: .fast))
    let last = continueAfterTry(.typed, attempts: 4, nextTryAt: t0, mode: .fast, cmux: true, now: t0)
    #expect(last.attempts == 5 && last.gaveUp && !last.stuck)
    #expect(!continueRetrying(attempts: [last.attempts], mode: .fast))
    let p = continueAfterTry(.typed, attempts: 41, nextTryAt: t0, mode: .persistent, cmux: false, now: t0)
    #expect(p == ContinueTryStep(attempts: 42, nextTryAt: t0 + 60))   // persistent never gives up
    #expect(continueRetrying(attempts: [p.attempts], mode: .persistent))
    // Not awake: nothing typed or counted, it tries again next scan.
    #expect(continueAfterTry(.notAwake, attempts: 2, nextTryAt: t0, mode: .backoff, cmux: true, now: t0 + 99)
            == ContinueTryStep(attempts: 2, nextTryAt: t0))
    // Off never retries.
    #expect(!continueRetrying(attempts: [0], mode: .off))
}

// ── Terminal text classifiers ──

let claudeErrorScreen = """
● Working on the fix…

API Error: unable to connect to API (ECONNREFUSED)

╭──────────────────────────────────────────╮
│ >                                        │
╰──────────────────────────────────────────╯
  ? for shortcuts
"""

@Test func claudeErrorDetectedOnRealErrorScreen() {
    #expect(claudeErrorVisible(claudeErrorScreen))
}

@Test func claudeErrorIgnoredWhileWorking() {
    let working = claudeErrorScreen + "\n✻ Compacting… (esc to interrupt)"
    #expect(!claudeErrorVisible(working))
}

@Test func claudeErrorIgnoredInPlainShell() {
    // npm failure in a normal shell: matches "connection refused" but there
    // is no Claude UI on screen, so it must NOT trigger auto-continue.
    let npm = """
    npm ERR! network connection refused https://registry.npmjs.org/
    npm ERR! A complete log of this run can be found in ~/.npm/_logs/…
    user@mac myproject %
    """
    #expect(!claudeErrorVisible(npm))
}

// What the screen looked like when 4 "continue"s were typed during lid-closed dark wakes.
let sleptScreen = """
⏺ API Error: Your computer went to sleep mid-response. The response above may be incomplete.

✻ Crunched for 1h 50m 41s · done 10:11 AM · 1 shell still running

────────────────────────────────────────────
❯
────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
"""

@Test func sleepErrorIsNotAnOutage() {
    #expect(!claudeErrorVisible(sleptScreen))
    let before = sleptScreen.replacingOccurrences(of: "went to sleep mid-response. The response above may be incomplete.",
                                                  with: "went to sleep before a response was produced. Try again.")
    #expect(!claudeErrorVisible(before))
}

let connectionLostScreen = """
⏺ API Error: Connection lost mid-response. The response above may be incomplete.

✻ Crunched for 3m 12s

────────────────────────────────────────────
❯
────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
"""

@Test func errorAnsweredOnlyOnce() {
    #expect(claudeErrorVisible(connectionLostScreen))
    // After our "continue" is submitted, the same error must not trigger again…
    let answered = connectionLostScreen.replacingOccurrences(
        of: "✻ Crunched for 3m 12s\n", with: "✻ Crunched for 3m 12s\n\n❯ continue\n")
    #expect(!claudeErrorVisible(answered))
    // …but a NEW error below that "continue" does.
    let again = answered.replacingOccurrences(
        of: "❯ continue\n", with: "❯ continue\n\n⏺ API Error: 529 overloaded\n")
    #expect(claudeErrorVisible(again))
}

@Test func errorIgnoredWhileUserIsTyping() {
    // Text in the input box: typing "continue" would append to it.
    let typing = connectionLostScreen.replacingOccurrences(of: "\n❯", with: "\n❯ half-written question")
    #expect(typing != connectionLostScreen)
    #expect(!claudeErrorVisible(typing))
}

@Test func spinnerMeansWorking() {
    // Claude Code 2.1.x spinner: random verb + ellipsis, no "esc to interrupt".
    #expect(claudeWorkingVisible("✻ Crunching… (12s · ↓ 1.2k tokens)"))
    #expect(claudeWorkingVisible("✶ Beboppin'… (3m 4s · ↑ 900 tokens · thinking)"))
    #expect(claudeWorkingVisible("· Clauding…"))
    #expect(!claudeWorkingVisible("✻ Crunched for 1h 50m 41s · done 10:11 AM"))
    #expect(!claudeWorkingVisible("● Working on the fix…"))
    #expect(!claudeWorkingVisible(sleptScreen))
    // An error screen with the spinner still going is Claude retrying, so hands off.
    #expect(!claudeErrorVisible(connectionLostScreen.replacingOccurrences(
        of: "✻ Crunched for 3m 12s", with: "✻ Crunching… (3m 12s · ↓ 4k tokens)")))
}

@Test func claudeWorkingDetection() {
    #expect(claudeWorkingVisible("✻ Thinking… (esc to interrupt)"))
    #expect(claudeWorkingVisible("Waiting for the dynamic workflow to finish…"))
    #expect(claudeWorkingVisible("Task is running in the background"))
    #expect(!claudeWorkingVisible("user@mac ~ %"))
}

@Test func usageLimitDetection() {
    // Current Claude Code wording (2.1.x): "You've hit your <name> · resets …"
    for name in ["session limit", "weekly limit", "Opus limit", "Fable limit"] {
        #expect(usageLimitVisible("You've hit your \(name) · resets 3am (America/Los_Angeles)"))
    }
    #expect(usageLimitVisible("You've reached your usage limit. Your limit resets 3:20am (America/Los_Angeles)."))
    #expect(usageLimitVisible("Usage limit reached · continuing automatically at 3am · esc to cancel\nresets 3am"))
    #expect(!usageLimitVisible("user@mac ~ % echo done"))
    #expect(!usageLimitVisible("You've hit your session limit"))   // no reset → not the wall
}

let limitMenuStopFirst = """
You've hit your session limit · resets 3am (America/Los_Angeles)

❯ 1. Stop and wait for limit to reset
  2. Upgrade your plan
"""

@Test func limitMenuPicksWaitNotUpgrade() {
    #expect(limitMenuChoice(limitMenuStopFirst) == .waitForReset("1"))
}

@Test func limitMenuPicksByLabelWhenPaidOptionsComeFirst() {
    // Claude Code sometimes lists the paid options first, so never pick by position.
    let menu = """
    You've hit your session limit · resets 3am (America/Los_Angeles)

    ❯ 1. Switch to usage credits
      2. Upgrade your plan
      3. Stop and wait for limit to reset
    """
    #expect(limitMenuChoice(menu) == .waitForReset("3"))
}

@Test func limitMenuPrefersClaudeAutoContinue() {
    let menu = """
    You've hit your session limit · resets 3am (America/Los_Angeles)

    ❯ 1. Stop and wait for limit to reset
      2. Wait here, then continue automatically when the limit resets
    """
    #expect(limitMenuChoice(menu) == .claudeAutoContinue("2"))
    // …but never the opt-out, which also says "continue automatically"
    let optOut = """
    ❯ 1. Don\u{2019}t continue automatically
      2. Upgrade your plan
    """
    #expect(limitMenuChoice(optOut) == nil)
}

@Test func limitMenuWithoutWaitOptionPicksNothing() {
    let menu = """
    You've hit your session limit · resets 3am (America/Los_Angeles)

    ❯ 1. Add funds to continue with usage credits
      2. Upgrade your plan
    """
    #expect(limitMenuChoice(menu) == nil)
    #expect(menuVisible(menu))
}

@Test func numberedProseIsNotAMenu() {
    let prose = """
    Here's the plan:
      1. Stop and wait for limit to reset
      2. Then continue
    """
    #expect(!menuVisible(prose))
    #expect(limitMenuChoice(prose) == nil)
}

@Test func claudeAutoResumeDetection() {
    #expect(claudeAutoResumeVisible("Usage limit reached · continuing automatically at 3am · esc to cancel"))
    #expect(!claudeAutoResumeVisible(limitMenuStopFirst))
}

@Test func claudeUIVisibleInPermissionModes() {
    // With a permission mode on, the footer replaces "? for shortcuts".
    #expect(claudeUIVisible("────────\n❯ \n────────\n  ⏵⏵ auto mode on (shift+tab to cycle)"))
    #expect(claudeUIVisible("  ⏸ plan mode on (shift+tab to cycle)"))
    #expect(!claudeUIVisible("user@mac ~ %"))
}

@Test func autoContinueNeverTypesIntoAMenu() {
    // An API error above an open permission prompt: "continue⏎" would pick option 1.
    let screen = """
    API Error: 529 overloaded
    Do you want to run this command?
    ❯ 1. Yes
      2. No
      ? for shortcuts
    """
    #expect(!claudeErrorVisible(screen))
}

// ── parseResetTime ──

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: TimeZone) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

@Test func resetTimeSameDay() {
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    let now = date(2026, 7, 23, 10, 0, tz: tz)
    #expect(parseResetTime("resets 3:20pm (America/Los_Angeles)", now: now)
            == date(2026, 7, 23, 15, 20, tz: tz))
}

@Test func resetTimeRollsToTomorrow() {
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    let now = date(2026, 7, 23, 16, 0, tz: tz)
    #expect(parseResetTime("resets 3:20pm (America/Los_Angeles)", now: now)
            == date(2026, 7, 24, 15, 20, tz: tz))
}

@Test func resetTimeWithoutMinutes() {
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    let now = date(2026, 7, 23, 1, 0, tz: tz)
    #expect(parseResetTime("Your limit resets 3am (America/Los_Angeles)", now: now)
            == date(2026, 7, 23, 3, 0, tz: tz))
}

@Test func resetTimeTwelveOClock() {
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    let now = date(2026, 7, 23, 1, 0, tz: tz)
    #expect(parseResetTime("resets 12:30pm (America/Los_Angeles)", now: now)
            == date(2026, 7, 23, 12, 30, tz: tz))
    // 12:30am is already past at 1:00am → tomorrow
    #expect(parseResetTime("resets 12:30am (America/Los_Angeles)", now: now)
            == date(2026, 7, 24, 0, 30, tz: tz))
}

@Test func resetTimeThreePartTimezone() {
    let tz = TimeZone(identifier: "America/Argentina/Buenos_Aires")!
    let now = date(2026, 7, 23, 1, 0, tz: tz)
    #expect(parseResetTime("resets 3:20am (America/Argentina/Buenos_Aires)", now: now)
            == date(2026, 7, 23, 3, 20, tz: tz))
}

@Test func resetTimeUTC() {
    let tz = TimeZone(identifier: "UTC")!
    let now = date(2026, 7, 23, 1, 0, tz: tz)
    #expect(parseResetTime("resets at 9:00am (UTC)", now: now)
            == date(2026, 7, 23, 9, 0, tz: tz))
}

@Test func resetTimeNoMatch() {
    #expect(parseResetTime("nothing to see here") == nil)
}

@Test func resetTimeSkipsNonTimezoneParens() {
    // An earlier parenthesized token must not shadow the real timezone.
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    let now = date(2026, 7, 23, 1, 0, tz: tz)
    #expect(parseResetTime("(esc) … resets 3:20am (America/Los_Angeles)", now: now)
            == date(2026, 7, 23, 3, 20, tz: tz))
}

@Test func resetTimeUsesLastMatchInTail() {
    // An older limit message earlier on screen must not win over the latest one.
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    let now = date(2026, 7, 23, 1, 0, tz: tz)
    let screen = "resets 2am (America/Los_Angeles)\n…\nYou've hit your session limit · resets 4am (America/Los_Angeles)"
    #expect(parseResetTime(screen, now: now) == date(2026, 7, 23, 4, 0, tz: tz))
}

@Test func resetTimeFromClaudeAutoResume() {
    let now = Date()
    let r = parseResetTime("Usage limit reached · continuing automatically at 3am · esc to cancel", now: now)
    #expect(r != nil && r! > now && r!.timeIntervalSince(now) <= 86400)
}

@Test func resetTimeFarDatesDontParse() {
    // Weekly resets are shown as a date. Those are multi-day waits; don't parse them.
    #expect(parseResetTime("You've hit your weekly limit · resets Oct 5, 12am (America/Los_Angeles)") == nil)
}

// ── Usage API ──

// Captured from GET /api/oauth/usage (2026-09-29), trimmed.
let usageJSON = """
{
 "five_hour": {"utilization": 38.0, "resets_at": "2026-09-29T08:10:00.121597+00:00"},
 "seven_day": {"utilization": 21.0, "resets_at": "2026-10-05T00:00:00.121623+00:00"},
 "seven_day_opus": null,
 "limits": [
  {"kind": "session", "group": "session", "percent": 38, "severity": "normal",
   "resets_at": "2026-09-29T08:10:00.121597+00:00", "scope": null, "is_active": true},
  {"kind": "weekly_all", "group": "weekly", "percent": 21, "severity": "normal",
   "resets_at": "2026-10-05T00:00:00.121623+00:00", "scope": null, "is_active": false},
  {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
   "resets_at": "2026-10-05T00:00:00+00:00",
   "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
 ]
}
"""

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
}

@Test func usageParsesLimitsArrayIncludingFable() {
    let l = parseUsageLimits(json(usageJSON))
    #expect(l.map(\.label) == ["Session (5h)", "Weekly · all models", "Fable only"])
    #expect(l.map(\.percent) == [38, 21, 0])
    #expect(l[2].key == "weekly_scoped:Fable")
    #expect(l[0].resetsAt == parseISO("2026-09-29T08:10:00Z"))   // rounded to the minute
}

@Test func usageFallsBackToLegacyKeys() {
    let l = parseUsageLimits(json("""
    {"five_hour": {"utilization": 55.5, "resets_at": "2026-09-29T08:09:59.636007+00:00"},
     "seven_day": {"utilization": 10, "resets_at": null}}
    """))
    #expect(l.map(\.label) == ["Session (5h)", "Weekly · all models"])
    #expect(l[0].percent == 55.5)
    #expect(l[0].resetsAt == parseISO("2026-09-29T08:10:00Z"))
    #expect(l[1].resetsAt == nil)
}

@Test func usageLevels() {
    #expect(usageLevel(percent: 10) == .normal)
    #expect(usageLevel(percent: 75) == .warning)
    #expect(usageLevel(percent: 95) == .critical)
    #expect(usageLevel(percent: 10, severity: "warning") == .warning)
    #expect(usageLevel(percent: 10, severity: "critical") == .critical)
    #expect(usageLevel(percent: 10, severity: "normal") == .normal)
}

@Test func usageAlertFiresOnceDespiteResetJitter() {
    // resets_at jitters by <1s between fetches; that must not look like a new window.
    var t = UsageAlertTracker()
    let a = parseUsageLimits(json("""
    {"limits": [{"kind": "session", "percent": 85, "resets_at": "2026-09-29T08:10:00.121597+00:00"}]}
    """))
    let b = parseUsageLimits(json("""
    {"limits": [{"kind": "session", "percent": 86, "resets_at": "2026-09-29T08:09:59.636007+00:00"}]}
    """))
    #expect(t.check(a, threshold: 80).count == 1)
    #expect(t.check(b, threshold: 80).isEmpty)
    #expect(t.check(a, threshold: 0).isEmpty)
}

@Test func usageAlertRefiresOnNewWindowOrRecrossing() {
    var t = UsageAlertTracker()
    let w1 = [UsageLimit(key: "s", label: "S", percent: 90, resetsAt: Date(timeIntervalSince1970: 1000))]
    let w2 = [UsageLimit(key: "s", label: "S", percent: 90, resetsAt: Date(timeIntervalSince1970: 20000))]
    let low = [UsageLimit(key: "s", label: "S", percent: 5, resetsAt: Date(timeIntervalSince1970: 20000))]
    #expect(t.check(w1, threshold: 80).count == 1)
    #expect(t.check(w2, threshold: 80).count == 1)   // new window, still above
    #expect(t.check(low, threshold: 80).isEmpty)
    #expect(t.check(w2, threshold: 80).count == 1)   // crossed again
}

// ── Process-list classifiers ──

@Test func idleShellNotRunning() {
    let lines = [
        "ttys000  501  501 -zsh",
        "??         1    0 /sbin/launchd",
    ]
    #expect(!interactiveShellRunningCommand(psLines: lines))
}

@Test func foregroundCommandDetected() {
    let lines = [
        "ttys000  501  501 -zsh",
        "ttys001  600  600 python3 train.py --epochs 100",
    ]
    #expect(interactiveShellRunningCommand(psLines: lines))
}

@Test func backgroundCommandIgnored() {
    // pgid != tpgid → backgrounded, not the foreground job
    let lines = [
        "ttys001  600  700 python3 train.py",
        "ttys001  700  700 -zsh",
    ]
    #expect(!interactiveShellRunningCommand(psLines: lines))
}

@Test func claudeTtyExcluded() {
    // The tty hosting Claude (and all its subprocesses) must not count.
    let lines = [
        "ttys002  800  800 claude",
        "ttys002  810  810 node /some/mcp-server.js",
    ]
    #expect(!interactiveShellRunningCommand(psLines: lines))
}

@Test func commMatching() {
    #expect(processCommMatches(commLines: ["/usr/bin/ssh"], names: ["ssh"]))
    #expect(!processCommMatches(commLines: ["/usr/bin/ssh-agent"], names: ["ssh"]))
}

@Test func monitorWatchNeedsLeadingExecutable() {
    #expect(monitorRunning(commLines: [], commandLines: ["watch -n1 ls"]))
    #expect(monitorRunning(commLines: [], commandLines: ["sudo watch df -h"]))
    #expect(monitorRunning(commLines: [], commandLines: ["/opt/homebrew/bin/watch date"]))
    // substring " watch " must no longer false-positive:
    #expect(!monitorRunning(commLines: [], commandLines: ["vim notes-to watch later.txt"]))
    #expect(monitorRunning(commLines: [], commandLines: ["tail -f /var/log/system.log"]))
    #expect(monitorRunning(commLines: ["/usr/bin/top"], commandLines: []))
}

// ── Lid-closed mode ──

private func lidIn(whileClaude: Bool = false, busy: Bool = false, closed: Bool = false,
                   battery: Int? = 80, onBattery: Bool = true, floor: Int = 20,
                   hot: Bool = false, at t: TimeInterval = 1000, cap: TimeInterval = 0) -> LidInputs {
    LidInputs(whileClaude: whileClaude, claudeBusy: busy, lidClosed: closed, onBattery: onBattery,
              batteryPercent: battery, batteryFloor: floor, hot: hot, closedCap: cap,
              now: Date(timeIntervalSince1970: t))
}

@Test func lidOffWithNothingWantingIt() {
    var s = LidState()
    #expect(!stepLid(&s, lidIn()).disableSleep)
    #expect(!stepLid(&s, lidIn(busy: true)).disableSleep)   // Claude busy but the setting is off
}

@Test func lidFollowsClaudeWithLinger() {
    var s = LidState()
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000)).disableSleep)
    // Claude stopped: stays on through the linger, then off
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: false, closed: true, at: 1000 + lidClaudeLinger - 1)).disableSleep)
    #expect(!stepLid(&s, lidIn(whileClaude: true, busy: false, closed: true, at: 1000 + lidClaudeLinger + 1)).disableSleep)
}

@Test func lidUntilOpenEndsOnClosedToOpen() {
    var s = LidState(session: .untilLidOpens)
    #expect(stepLid(&s, lidIn(closed: false)).disableSleep)     // started with the lid open
    #expect(stepLid(&s, lidIn(closed: true)).disableSleep)      // closed: stays awake
    let o = stepLid(&s, lidIn(closed: false))                    // opened: done
    #expect(!o.disableSleep)
    #expect(o.sessionEnded == .lidOpened)
    #expect(s.session == nil)
}

@Test func lidTimedSessionEnds() {
    var s = LidState(session: .until(Date(timeIntervalSince1970: 2000)))
    #expect(stepLid(&s, lidIn(closed: true, at: 1999)).disableSleep)
    let o = stepLid(&s, lidIn(closed: true, at: 2000))
    #expect(!o.disableSleep)
    #expect(o.sessionEnded == .timeUp)
}

@Test func lidIndefiniteIgnoresLidOpening() {
    var s = LidState(session: .indefinite)
    _ = stepLid(&s, lidIn(closed: true))
    #expect(stepLid(&s, lidIn(closed: false)).disableSleep)
}

@Test func lidLowBatteryTripsOnceAndLatchesWhileClosed() {
    var s = LidState()
    _ = stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, battery: 50))
    let o = stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, battery: 20))
    #expect(!o.disableSleep)
    #expect(o.newlyTripped == .lowBattery)
    // still low: no second notification
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, battery: 19)).newlyTripped == nil)
    // plugged in while the lid is still shut: stays off (don't re-arm in a bag)
    #expect(!stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, battery: 19, onBattery: false)).disableSleep)
    // lid opened with the guard clear: back on
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: false, battery: 19, onBattery: false)).disableSleep)
}

@Test func lidGuardEndsOneOffSession() {
    var s = LidState(session: .indefinite)
    let o = stepLid(&s, lidIn(closed: true, hot: true))
    #expect(!o.disableSleep)
    #expect(o.newlyTripped == .hot)
    #expect(o.sessionEnded == .hot)
    #expect(s.session == nil)
}

@Test func lidGuardIgnoredWhenNothingWantsIt() {
    var s = LidState()
    #expect(stepLid(&s, lidIn(closed: true, battery: 5)).newlyTripped == nil)
    #expect(s.tripped == nil)
}

@Test func lidBatteryGuardOffOrOnAC() {
    var s = LidState(session: .indefinite)
    #expect(stepLid(&s, lidIn(battery: 15, floor: 0)).disableSleep)                 // an old "No limit" is 10%
    #expect(stepLid(&s, lidIn(battery: 5, onBattery: false)).disableSleep)          // on the adapter
    #expect(stepLid(&s, lidIn(battery: nil)).disableSleep)                           // no battery (desktop)
}

@Test func lidNeverRunsTheBatteryFlat() {
    // "No limit" used to keep lid mode on all the way down; the battery limit
    // is at least 10% now, whatever was saved.
    #expect(lidGuard(lidIn(battery: 10, floor: 0)) == .lowBattery)
    #expect(lidGuard(lidIn(battery: 5, floor: 0)) == .lowBattery)
    #expect(lidGuard(lidIn(battery: 11, floor: 0)) == nil)
    var s = LidState(session: .indefinite)
    #expect(!stepLid(&s, lidIn(battery: 5, floor: 0)).disableSleep)
}

@Test func lidOnlyWhenPluggedIn() {
    var s = LidState()
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, battery: 95,
                              onBattery: false, floor: lidOnlyPluggedIn)).disableSleep)
    let o = stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, battery: 95, floor: lidOnlyPluggedIn))
    #expect(!o.disableSleep)
    #expect(o.newlyTripped == .unplugged)
}

@Test func lidPluggedInOnlyEndsOneOffSessionOnBattery() {
    var s = LidState(session: .indefinite)
    let o = stepLid(&s, lidIn(battery: 95, floor: lidOnlyPluggedIn))
    #expect(!o.disableSleep)
    #expect(o.sessionEnded == .unplugged)
}

@Test func lidHeatLimits() {
    #expect(!lidTooHot(.nominal, limit: .warm))
    #expect(lidTooHot(.fair, limit: .warm))
    #expect(!lidTooHot(.fair, limit: .hot))
    #expect(lidTooHot(.serious, limit: .hot))     // the old fixed rule
    #expect(!lidTooHot(.serious, limit: .veryHot))
    #expect(lidTooHot(.critical, limit: .veryHot))
}

@Test func lidClosedCapStopsClaudeDrivenMode() {
    var s = LidState()
    let cap: TimeInterval = 3600
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000, cap: cap)).disableSleep)
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000 + cap - 1, cap: cap)).disableSleep)
    let o = stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000 + cap, cap: cap))
    #expect(!o.disableSleep)
    #expect(o.capReached)
    // reported once per close
    #expect(!stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000 + cap + 3, cap: cap)).capReached)
    // opening the lid resets the clock
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: false, at: 1000 + cap + 6, cap: cap)).disableSleep)
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000 + cap + 9, cap: cap)).disableSleep)
}

@Test func lidClosedCapLeavesSessionsAlone() {
    var s = LidState(session: .indefinite)
    _ = stepLid(&s, lidIn(closed: true, at: 1000, cap: 3600))
    let o = stepLid(&s, lidIn(closed: true, at: 1000 + 7200, cap: 3600))
    #expect(o.disableSleep)
    #expect(!o.capReached)
}

@Test func lidNoCapByDefault() {
    var s = LidState()
    _ = stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000))
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 1000 + 86400)).disableSleep)
}

// 2026-10-07: switching disablesleep off with the lid already shut doesn't make
// macOS clamshell-sleep, and the one sleep request was ignored. The Mac sat
// awake with the lid shut for up to 55 minutes.
private func stuck(_ w: inout LidSleepWatch, at t: TimeInterval, closed: Bool = true, disabled: Bool = false,
                   awake: Bool = true, external: Bool = false, wanted: Bool = false, starting: Bool = false) -> Bool {
    w.step(lidClosed: closed, sleepDisabled: disabled, fullyAwake: awake, externalDisplay: external,
           lidWanted: wanted, sleepStarting: starting, now: Date(timeIntervalSince1970: t))
}

// 2026-10-08: macOS posted willSleep at once but slept 30s later (paused apps
// can't answer the sleep notice), and the watch asked again in between.
@Test func sleepWatchWaitsOutASleepAlreadyUnderway() {
    var w = LidSleepWatch()
    for t in stride(from: 1000.0, through: 1030, by: 3) { #expect(!stuck(&w, at: t, starting: true)) }
    #expect(!stuck(&w, at: 1033))                                  // settle starts over after it
    #expect(stuck(&w, at: 1033 + LidSleepWatch.settle))
}

@Test func sleepWatchRetriesWhenStillAwakeWithLidShut() {
    var w = LidSleepWatch()
    #expect(!stuck(&w, at: 1000))
    #expect(!stuck(&w, at: 1000 + LidSleepWatch.settle - 1))
    #expect(stuck(&w, at: 1000 + LidSleepWatch.settle))
    // throttled
    #expect(!stuck(&w, at: 1000 + LidSleepWatch.settle + 3))
    #expect(stuck(&w, at: 1000 + LidSleepWatch.settle + LidSleepWatch.retryEvery))
}

@Test func sleepWatchQuietWhenAwakeOnPurpose() {
    var w = LidSleepWatch()
    for t in stride(from: 1000.0, through: 1200, by: 3) {
        #expect(!stuck(&w, at: t, closed: false))        // lid open
        #expect(!stuck(&w, at: t, disabled: true))       // lid-closed mode holding it
        #expect(!stuck(&w, at: t, awake: false))         // dark wake: macOS handles it
        #expect(!stuck(&w, at: t, external: true))       // clamshell desk setup
        #expect(!stuck(&w, at: t, wanted: true))         // lid mode about to switch on
    }
}

@Test func sleepWatchRestartsSettleAfterARealSleep() {
    var w = LidSleepWatch()
    _ = stuck(&w, at: 1000)
    #expect(stuck(&w, at: 1000 + LidSleepWatch.settle))
    _ = stuck(&w, at: 2000, awake: false)                // slept (dark wake now)
    #expect(!stuck(&w, at: 5000))                         // fully awake again: settle first
    #expect(stuck(&w, at: 5000 + LidSleepWatch.settle))
}

@Test func durationFormatting() {
    #expect(fmtDuration(30) == "30s")
    #expect(fmtDuration(60) == "1m")
    #expect(fmtDuration(61) == "2m")
    #expect(fmtDuration(3600) == "1h 00m")
    #expect(fmtDuration(8 * 3600 - 10) == "8h 00m")
    #expect(fmtDuration(7 * 3600 + 5 * 60) == "7h 05m")
}

@Test func wholeHoursAhead() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 3600 * 10 + 1234)   // 10:20:34 UTC
    let hrs = nextWholeHours(after: now, count: 3, calendar: cal)
    let want: [TimeInterval] = [39600, 43200, 46800]   // 11:00, 12:00, 13:00
    #expect(hrs.map(\.timeIntervalSince1970) == want)
}

@Test func shellQuoting() {
    #expect(shellQuoted("/Users/me/a b") == "'/Users/me/a b'")
    #expect(shellQuoted("it's") == "'it'\\''s'")
}

// Claude Code's own API retry phase (~3 min) between the error lines it prints.
// Seen 2026-10-05: auto-continue counted each 3-min cycle as "recovered" and typed
// "continue" 20+ times, always as attempt #1.
@Test func claudeRetryLineDetected() {
    let retrying = """
    ⏺ API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)

    ✻ Sautéed for 3m 3s · done 2:41 PM

    ❯ continue

    ✻ Can't reach the API server — check your internet or DNS (ENOTFOUND) · Retrying in 14s · attempt 9/10
    """
    #expect(claudeRetryingVisible(retrying))
    #expect(!claudeRetryingVisible("⏺ API Error: Can't reach the API server (ENOTFOUND)\n\n❯ "))
    #expect(!claudeRetryingVisible("✻ Baking… (2m · ↓ 1k tokens)"))
}

@Test func statusLinesAbovePromptForDiagnostics() {
    let screen = """
    ⏺ Agent(Implement Plan B Task 9)
      ⎿  Running…

    ✻ Baking… (52m 10s · ↓ 3.2k tokens)

    ────────────────────────────────────────
    ❯ 
    ────────────────────────────────────────
      ⏵⏵ auto mode on
    """
    #expect(statusLinesAbovePrompt(screen, count: 2) == ["⎿  Running…", "✻ Baking… (52m 10s · ↓ 3.2k tokens)"])
    #expect(statusLinesAbovePrompt("plain shell output\n$ ") == [])
}

// ── Battery floor for everything ──

@Test func awakeFloorIsTheBatterySetting() {
    #expect(awakeBatteryFloor(20) == 20)
    #expect(awakeBatteryFloor(30) == 30)
    #expect(awakeBatteryFloor(10) == 10)
    #expect(awakeBatteryFloor(0) == 10)                                  // an old "No limit": never runs it flat
    #expect(awakeBatteryFloor(lidOnlyPluggedIn) == lidOnlyPluggedIn)     // only on the charger: never on battery
    var b = BatteryStop()
    let stopped = b.step(onBattery: true, percent: 95, floor: awakeBatteryFloor(lidOnlyPluggedIn))
    #expect(stopped)
}

@Test func batteryStopLatchesUntilPluggedIn() {
    // 2026-10-13: "I'm leaving" held the Mac awake on battery from 80% at 1am
    // to 3% at 8am; only lid mode stopped at 20%.
    var b = BatteryStop()
    func step(_ onBattery: Bool, _ pct: Int?) -> Bool { b.step(onBattery: onBattery, percent: pct, floor: 20) }
    #expect(!step(true, 21))
    #expect(!b.stopped)
    #expect(step(true, 20))                     // newly stopped, report once
    #expect(b.stopped)
    #expect(!step(true, 19))
    #expect(!step(true, 22))                    // a bounce back up doesn't restart it
    #expect(b.stopped)
    #expect(!step(false, 22))                   // plugged in
    #expect(!b.stopped)
    #expect(!step(true, nil))                   // no battery reading: never stop
    #expect(!b.stopped)
}

@Test func limitWaitOnBatteryOnlyWhenTheResetIsClose() {
    // 2026-10-13: a 4h40m wait for a usage limit held the Mac awake on battery
    // from 80% to the battery limit. On battery, only waits up to an hour count.
    let now = Date(timeIntervalSince1970: 1_000_000)
    let soon = now + 40 * 60, late = now + 3 * 3600
    #expect(limitWaitHolds(resumeAts: [soon], now: now, onBattery: true))
    #expect(!limitWaitHolds(resumeAts: [late], now: now, onBattery: true))
    #expect(limitWaitHolds(resumeAts: [late], now: now, onBattery: false))           // on the charger: the whole wait
    #expect(limitWaitHolds(resumeAts: [late], now: late - 30 * 60, onBattery: true))  // an hour out, it holds again
    #expect(limitWaitHolds(resumeAts: [soon], now: soon + limitWaitGrace - 1, onBattery: true))   // lets the resume land
    #expect(!limitWaitHolds(resumeAts: [soon], now: soon + limitWaitGrace, onBattery: false))
    #expect(limitWaitHolds(resumeAts: [late, soon], now: now, onBattery: true))       // any close one
    #expect(!limitWaitHolds(resumeAts: [], now: now, onBattery: false))
}

@Test func detectorsGetAnHourOnBattery() {
    // 2026-10-09: a detector held the Mac awake for 12.6 hours.
    var cap = DetectorBatteryCap()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func allows(_ t: TimeInterval, active: Bool = true, onBattery: Bool = true) -> Bool {
        cap.allows(active: active, onBattery: onBattery, now: t0 + t)
    }
    #expect(allows(0, onBattery: false))
    #expect(allows(5 * 3600, onBattery: false))                 // on the charger: no limit
    #expect(allows(5 * 3600 + 1))                                // unplugged: the hour starts
    #expect(allows(5 * 3600 + DetectorBatteryCap.limit))
    #expect(!allows(5 * 3600 + 1 + DetectorBatteryCap.limit))   // an hour on battery: let it sleep
    #expect(!allows(6 * 3600 + 100, active: false))              // activity stopped
    #expect(allows(6 * 3600 + 200))                              // new activity: a fresh hour
    #expect(allows(6 * 3600 + 300, onBattery: false))
    #expect(allows(6 * 3600 + 301))                              // plugged in and out: a fresh hour
    #expect(allows(6 * 3600 + 301 + DetectorBatteryCap.limit - 1))
}

// ── Remote Control check-ins ──

private func ci(enabled: Bool = true, closed: Bool = true, awake: Bool = false, sleepStarting: Bool = false,
                external: Bool = false, guarded: Bool = false, onBattery: Bool = false, at t: TimeInterval) -> CheckInInputs {
    CheckInInputs(enabled: enabled, lidClosed: closed, fullyAwake: awake, sleepStarting: sleepStarting,
                  externalDisplay: external, guarded: guarded, onBattery: onBattery, now: Date(timeIntervalSince1970: t))
}

/// A check-in whose lid closed at t=0 (the clock starts on the first closed step).
private func napping() -> RemoteCheckIn {
    var c = RemoteCheckIn()
    _ = c.step(ci(awake: true, at: 0))   // lid shuts while awake: no check-in
    return c
}

@Test func checkInRunsOnANapAndSleepsAgain() {
    var c = napping()
    #expect(c.step(ci(at: 600)) == .started)                  // 10 min later macOS naps
    #expect(c.isOpen)
    #expect(c.step(ci(at: 601)) == nil)                        // still dark, waiting
    #expect(c.step(ci(awake: true, at: 604)) == .fullyAwake(after: 4))
    #expect(c.step(ci(awake: true, at: 604 + RemoteCheckIn.window - 1)) == nil)
    #expect(c.step(ci(awake: true, at: 604 + RemoteCheckIn.window)) == .ended(.windowOver))
    #expect(!c.isOpen)
}

@Test func checkInGivesUpWithoutAFullWake() {
    // 2026-10-05: sleep switched off inside a nap held the Mac there with no
    // Wi-Fi for 74 minutes. A check-in must let go if the full wake never comes.
    var c = napping()
    #expect(c.step(ci(at: 600)) == .started)
    #expect(c.step(ci(at: 600 + RemoteCheckIn.fullWakeTimeout - 1)) == nil)
    #expect(c.step(ci(at: 600 + RemoteCheckIn.fullWakeTimeout)) == .ended(.noFullWake))
    #expect(!c.isOpen)
}

@Test func checkInOnlyFromANap() {
    var c = napping()
    #expect(c.step(ci(awake: true, at: 600)) == nil)           // fully awake with the lid shut: not a nap
    #expect(c.step(ci(sleepStarting: true, at: 601)) == nil)   // going to sleep, not waking from it
    #expect(c.step(ci(external: true, at: 602)) == nil)        // desk setup
    #expect(c.step(ci(guarded: true, at: 603)) == nil)         // battery or heat says sleep
    #expect(c.step(ci(enabled: false, at: 604)) == nil)
    #expect(c.step(ci(closed: false, at: 605)) == nil)
    #expect(!c.isOpen)
}

@Test func checkInWaitsAfterTheLidCloses() {
    var c = RemoteCheckIn()
    #expect(c.step(ci(at: 0)) == nil)                          // capabilities drop as it falls asleep
    #expect(c.step(ci(at: RemoteCheckIn.afterClose - 1)) == nil)
    #expect(c.step(ci(at: RemoteCheckIn.afterClose)) == .started)
}

@Test func checkInsAreSpacedOut() {
    var c = napping()
    #expect(c.step(ci(at: 600)) == .started)
    #expect(c.step(ci(at: 600 + RemoteCheckIn.fullWakeTimeout)) == .ended(.noFullWake))
    #expect(c.step(ci(at: 600 + RemoteCheckIn.spacing - 1)) == nil)
    #expect(c.step(ci(at: 600 + RemoteCheckIn.spacing)) == .started)
}

@Test func checkInsAreRarerOnBattery() {
    // Two minutes awake in every five drained the battery; on battery wait 15.
    var c = RemoteCheckIn()
    _ = c.step(ci(awake: true, onBattery: true, at: 0))
    #expect(c.step(ci(onBattery: true, at: 600)) == .started)
    #expect(c.step(ci(onBattery: true, at: 600 + RemoteCheckIn.fullWakeTimeout)) == .ended(.noFullWake))
    #expect(c.step(ci(onBattery: true, at: 600 + RemoteCheckIn.spacing)) == nil)
    #expect(c.step(ci(onBattery: true, at: 600 + RemoteCheckIn.spacingOnBattery - 1)) == nil)
    #expect(c.step(ci(onBattery: true, at: 600 + RemoteCheckIn.spacingOnBattery)) == .started)
}

@Test func checkInEndsWhenTheLidOpensOrItsTurnedOff() {
    var c = napping()
    #expect(c.step(ci(at: 600)) == .started)
    #expect(c.step(ci(closed: false, awake: true, at: 610)) == .ended(.lidOpened))
    var d = napping()
    #expect(d.step(ci(at: 600)) == .started)
    #expect(d.step(ci(enabled: false, at: 610)) == .ended(.turnedOff))
    var e = napping()
    #expect(e.step(ci(at: 600)) == .started)
    #expect(e.step(ci(guarded: true, at: 610)) == .ended(.guarded))
    var f = napping()
    #expect(f.step(ci(at: 600)) == .started)
    f.cancel()
    #expect(!f.isOpen)
}

@Test func checkInHoldsLidModeOnlyWhileOpen() {
    var s = LidState()
    var i = lidIn(closed: true, at: 1000)
    #expect(!stepLid(&s, i).disableSleep)
    i.checkIn = true
    #expect(stepLid(&s, i).disableSleep)
    var hot = lidIn(closed: true, hot: true, at: 1003)
    hot.checkIn = true
    #expect(!stepLid(&s, hot).disableSleep)                    // the heat guard still wins
}

@Test func checkInRestartsTheLidShutCap() {
    // Lid shut overnight with a 4h cap: work that a check-in picks up at 3am
    // must not be stopped at once for the hours the Mac spent asleep.
    var s = LidState()
    _ = stepLid(&s, lidIn(whileClaude: true, closed: true, at: 0, cap: 4 * 3600))
    s.restartClosedClock(now: Date(timeIntervalSince1970: 5 * 3600))
    #expect(stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 5 * 3600 + 10, cap: 4 * 3600)).disableSleep)
    #expect(!stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, at: 9 * 3600 + 10, cap: 4 * 3600)).disableSleep)
}

@Test func checkInRespectsATrippedGuardUntilTheLidOpens() {
    // Battery hit the floor mid-task, then the Mac was plugged in with the lid
    // still shut: lid mode stays off until the lid opens, so no check-ins either.
    var s = LidState()
    _ = stepLid(&s, lidIn(whileClaude: true, busy: true, closed: true, battery: 15, at: 0))
    let pluggedIn = lidIn(whileClaude: true, closed: true, battery: 15, onBattery: false, at: 600)
    #expect(lidGuard(pluggedIn) == nil)
    #expect(lidGuardActive(s, pluggedIn))
    _ = stepLid(&s, lidIn(closed: false, onBattery: false, at: 700))   // lid opens
    #expect(!lidGuardActive(s, lidIn(closed: true, onBattery: false, at: 800)))
}

@Test func lidGuardMatchesStepLid() {
    #expect(lidGuard(lidIn(hot: true)) == .hot)
    #expect(lidGuard(lidIn(floor: lidOnlyPluggedIn)) == .unplugged)
    #expect(lidGuard(lidIn(battery: 15, floor: 20)) == .lowBattery)
    #expect(lidGuard(lidIn(battery: 15, onBattery: false, floor: 20)) == nil)
    #expect(lidGuard(lidIn()) == nil)
}

// ── Why an on-screen error wasn't answered (diagnostics) ──

private let claudeFooter = "\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n  ? for shortcuts"

@Test func errorStatusUnanswered() {
    #expect(claudeErrorStatus("⏺ API Error: Can't reach the API server (ENOTFOUND)" + claudeFooter) == .unanswered)
}

@Test func errorStatusReasons() {
    #expect(claudeErrorStatus("all good" + claudeFooter) == .none)
    let answered = "⏺ API Error: Can't reach the API server\n\n❯ continue\n\n✻ Baked for 3m" + claudeFooter
    guard case .skipped(let why) = claudeErrorStatus(answered) else { Issue.record("expected skipped"); return }
    #expect(why.contains("continue"))
    let later = "⏺ API Error: boom\n\n⏺ All done — here's the summary.\n" + claudeFooter
    guard case .skipped(let why2) = claudeErrorStatus(later) else { Issue.record("expected skipped"); return }
    #expect(why2.contains("said more"))
    guard case .skipped = claudeErrorStatus("⏺ API Error: boom\n$ ") else { Issue.record("no UI → skipped"); return }
}

@Test func statusLinesSkipRuleWithText() {
    let screen = "✻ Baking… (2m)\n                         ✔ Update installed\n──────────────────── session ──\n❯ \n────────────────────"
    #expect(statusLinesAbovePrompt(screen) == ["✻ Baking… (2m)", "✔ Update installed"])
}

// ── AppSettings ──

private func freshDefaults() -> UserDefaults {
    let name = "ephedrine-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func settingsDefaultsOnEmptySuite() {
    let s = AppSettings(defaults: freshDefaults())
    #expect(s.enabled && s.finishMode == .sleepIfIdle && s.gracePeriod == 120 && s.graceUseSystem)
    #expect(s.powerMode == .always && s.detectors.isEmpty && s.usageAlert == 80 && !s.allowDisplaySleep)
    #expect(s.autoContinueMode == .off && !s.autoResumeLimit && !s.keepAwakeClaudeWorking)
    #expect(s.lidWhileClaude && s.batteryFloor == 20 && s.lidPauseApps && s.awayKeepRunning.isEmpty)
}

// Review focus 1: values saved by the pre-window app (raw keys) must load.
@Test func settingsReadExistingKeys() {
    let d = freshDefaults()
    d.set(false, forKey: "enabled"); d.set("alwaysSleep", forKey: "finishMode")
    d.set(30.0, forKey: "gracePeriod"); d.set(false, forKey: "graceUseSystem")
    d.set("acOnly", forKey: "powerMode"); d.set(["ssh", "terminal"], forKey: "detectors")
    d.set(90, forKey: "usageAlert"); d.set(true, forKey: "allowDisplaySleep")
    d.set("persistent", forKey: "autoContinueMode"); d.set(true, forKey: "autoResumeLimit")
    d.set(true, forKey: "keepAwakeClaudeWorking"); d.set(false, forKey: "lidWhileClaude")
    d.set(10, forKey: "lidBatteryFloor"); d.set(false, forKey: "lidPauseApps")
    d.set(["com.spotify.client"], forKey: "awayKeepRunning")
    let s = AppSettings(defaults: d)
    #expect(!s.enabled && s.finishMode == .alwaysSleep && s.gracePeriod == 30 && !s.graceUseSystem)
    #expect(s.powerMode == .acOnly && s.detectors == ["ssh", "terminal"] && s.usageAlert == 90 && s.allowDisplaySleep)
    #expect(s.autoContinueMode == .persistent && s.autoResumeLimit && s.keepAwakeClaudeWorking)
    #expect(!s.lidWhileClaude && s.batteryFloor == 10 && !s.lidPauseApps)
    #expect(s.awayKeepRunning == ["com.spotify.client"])
}

@Test func settingsNoBatteryLimitMigratesTo10() {
    let d = freshDefaults()
    d.set(0, forKey: "lidBatteryFloor")
    #expect(AppSettings(defaults: d).batteryFloor == 10)
    #expect(d.integer(forKey: "lidBatteryFloor") == 10)
}

@Test func settingsLegacyAutoContinueMigrates() {
    let d = freshDefaults()
    d.set(true, forKey: "autoContinue")
    #expect(AppSettings(defaults: d).autoContinueMode == .backoff)
}

@Test func settingsPersistAndReportKey() {
    let d = freshDefaults()
    let a = AppSettings(defaults: d)
    var changed: [String] = []
    a.onChange = { changed.append($0) }
    a.finishMode = .stayNormal
    a.detectors.insert("monitor")
    a.batteryFloor = 30
    #expect(changed == ["finishMode", "detectors", "lidBatteryFloor"])
    let b = AppSettings(defaults: d)
    #expect(b.finishMode == .stayNormal && b.detectors == ["monitor"] && b.batteryFloor == 30)
}

// Review focus 5
@Test func keepRunningAddDedupes() {
    let s = AppSettings(defaults: freshDefaults())
    s.addKeepRunning("com.spotify.client")
    s.addKeepRunning("com.spotify.client")
    #expect(s.awayKeepRunning == ["com.spotify.client"])
}

@Test func alwaysPauseDefaultsPersistsAndDedupes() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(s.alwaysPause.isEmpty)
    var changed: [String] = []
    s.onChange = { changed.append($0) }
    s.addAlwaysPause("com.tinyspeck.slackmacgap")
    s.addAlwaysPause("com.tinyspeck.slackmacgap")
    s.addAlwaysPause("")
    #expect(s.alwaysPause == ["com.tinyspeck.slackmacgap"] && changed == ["alwaysPause"])
    #expect(AppSettings(defaults: d).alwaysPause == ["com.tinyspeck.slackmacgap"])
    d.set(["a.b", "a.b", "c.d"], forKey: "alwaysPause")
    #expect(AppSettings(defaults: d).alwaysPause == ["a.b", "c.d"])
}

@Test func lowPowerSettingsDefaultAndPersist() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(s.lowPowerOnLidShut && s.lowPowerFloor == 40)
    var changed: [String] = []
    s.onChange = { changed.append($0) }
    s.lowPowerOnLidShut = false
    s.lowPowerFloor = 0
    #expect(changed == ["lowPowerOnLidShut", "lowPowerFloor"])
    let b = AppSettings(defaults: d)
    #expect(!b.lowPowerOnLidShut && b.lowPowerFloor == 0)
}

@Test func nextOccurrenceRollsToTomorrow() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 23 * 3600)              // 1970-01-01 23:00 UTC
    let sevenAM = Date(timeIntervalSince1970: 7 * 3600)            // any day, 07:00
    #expect(nextOccurrence(ofTimeIn: sevenAM, after: now, calendar: cal).timeIntervalSince1970 == 86400 + 7 * 3600)
    let elevenThirtyPM = Date(timeIntervalSince1970: 23 * 3600 + 1800)
    #expect(nextOccurrence(ofTimeIn: elevenThirtyPM, after: now, calendar: cal).timeIntervalSince1970 == 23 * 3600 + 1800)
    #expect(nextOccurrence(ofTimeIn: now, after: now, calendar: cal).timeIntervalSince1970 == 86400 + 23 * 3600)   // "now" means tomorrow
}

// Quitting while a slow "on" is still running must still end "off".
// 2026-10-06: a quit mid-flip left pmset disablesleep on with nothing owning it.
@Test func serialSwitchQuitAfterSlowOnEndsOff() {
    let lock = NSLock()
    var applied: [Bool] = []
    let sw = SerialSwitch(label: "test.switch") { on in
        if on { Thread.sleep(forTimeInterval: 0.2) }   // sudo pmset is slow
        lock.lock(); applied.append(on); lock.unlock()
        return true
    }
    sw.setAsync(true) { _ in }
    #expect(sw.setSync(false))
    lock.lock(); defer { lock.unlock() }
    #expect(applied == [true, false])
}

// Diagnostics: the layout below an on-screen error, as shapes only (no text).
@Test func lineShapesSummarizeLayout() {
    let lines = ["", "✻ Worked for 3m · done 3:39 PM", "⏺ Some reply", "  ⎿  tool output", "──────── x", "❯ continue", "❯ ", "  ⏵⏵ auto mode on", "※ recap: did stuff"]
    #expect(lineShapes(lines) == "_✻⏺⎿─P❯x※")
}

// 2026-10-05 3:39 PM: the turn ended on an API error but no "continue" was typed;
// later the log showed the error 31 to 35 lines up. Distance from the bottom isn't
// the test; whether anything was said or typed after the error is.
@Test func errorFarAboveTallFooterIsStillUnanswered() {
    let panel = String(repeating: "  ◯ Review Plan B Task 7 · 12m\n", count: 25)
    let screen = "⏺ API Error: Can't reach the API server (ENOTFOUND)\n\n✻ Worked for 2m 54s · done 3:39 PM\n\n" + panel + claudeFooter
    #expect(claudeErrorStatus(screen) == .unanswered)
}

// Seen live 2026-10-06: the scan matched "API Error" in Claude's own prose in
// another tab. Only a real error message, at the left edge ("⏺ API Error: …",
// or older "API Error: …"), counts; prose or a pasted error in a prompt don't.
@Test func errorInProseOrPastedPromptIsIgnored() {
    let prose = "⏺ Here's what happened: the turn ended on an API error at 3:39,\n  and API Error: lines like that one are what we watch for.\n" + claudeFooter
    #expect(claudeErrorStatus(prose) == .none)
    let pasted = "❯ closing says\n  ⏺ API Error: Can't reach the API server (ENOTFOUND)\n" + claudeFooter
    #expect(claudeErrorStatus(pasted) == .none)
    #expect(claudeErrorStatus("API Error: unable to connect to API (ECONNREFUSED)" + claudeFooter) == .unanswered)
}

@Test func lidLockOnCloseSetting() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(s.lidLockOnClose)                       // on unless turned off
    var changed: [String] = []
    s.onChange = { changed.append($0) }
    s.lidLockOnClose = false
    #expect(changed == ["lidLockOnClose"])
    #expect(!AppSettings(defaults: d).lidLockOnClose)
}

@Test func lidHeatAndCapSettings() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(s.lidHeatLimit == .hot && s.lidClosedCapHours == 0)   // same as before these existed
    var changed: [String] = []
    s.onChange = { changed.append($0) }
    s.lidHeatLimit = .warm
    s.lidClosedCapHours = 4
    #expect(changed == ["lidHeatLimit", "lidClosedCapHours"])
    let b = AppSettings(defaults: d)
    #expect(b.lidHeatLimit == .warm && b.lidClosedCapHours == 4)
}

@Test func remoteCheckInSetting() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(!s.lidRemoteCheckIn)                                // it wakes a sleeping Mac, so opt-in
    var changed: [String] = []
    s.onChange = { changed.append($0) }
    s.lidRemoteCheckIn = true
    #expect(changed == ["lidRemoteCheckIn"])
    #expect(AppSettings(defaults: d).lidRemoteCheckIn)
}

// Old README said `defaults write … awayKeepRunning -array-add`, which can leave
// duplicates; the Away list (ForEach by id) needs them gone on load.
@Test func keepRunningDuplicatesDroppedOnLoad() {
    let d = freshDefaults()
    d.set(["com.spotify.client", "com.apple.Music", "com.spotify.client"], forKey: "awayKeepRunning")
    #expect(AppSettings(defaults: d).awayKeepRunning == ["com.spotify.client", "com.apple.Music"])
}

// About → Terminal control: 0 tabs used to always say "allow in Automation",
// even when Terminal simply had no windows.
@Test func terminalControlStatusWording() {
    #expect(terminalControlStatus(tabs: -1, error: "") == "Not checked yet")
    #expect(terminalControlStatus(tabs: 3, error: "") == "OK (3 tabs)")
    #expect(terminalControlStatus(tabs: 1, error: "") == "OK (1 tab)")
    #expect(terminalControlStatus(tabs: 0, error: "") == "OK, no Terminal windows open")
    #expect(terminalControlStatus(tabs: 0, error: "execution error: Terminal got an error: Application isn't running. (-600)") == "OK, Terminal isn't open")
    #expect(terminalControlStatus(tabs: 0, error: "execution error: Not authorized to send Apple events to Terminal. (-1743)").hasPrefix("Not allowed"))
}

// 2026-10-18: Terminal kept reopening after the owner quit it. The scan every
// 9s sent it an Apple event, and an Apple event launches an app that isn't running.
@Test func terminalNotReadWhenNotRunning() {
    var read = false
    let r = readTerminalIfRunning(false) { () -> (tabs: [Int], err: String) in read = true; return ([1], "") }
    #expect(!read)
    #expect(r.tabs.isEmpty)
    #expect(terminalControlStatus(tabs: 0, error: r.err) == "OK, Terminal isn't open")
    #expect(readTerminalIfRunning(true) { () -> (tabs: [Int], err: String) in ([1, 2], "") }.tabs == [1, 2])
}

// ── "I'm leaving" ──

@Test func awayReturnsWhenCursorNeverStops() {
    // 2026-10-09: the screen stayed black for ~40s while the cursor kept
    // moving, because the old rule only listened after 4s of stillness.
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let away = AwayReturn(enteredAt: t0)
    let backAt = (1...20).first { s in away.isBack(now: t0 + Double(s), idleSeconds: 0.2) }
    #expect(backAt == 4)   // first 1s tick whose last input is after the 3s grace
}

@Test func awayIgnoresInputDuringGrace() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let away = AwayReturn(enteredAt: t0)
    #expect(!away.isBack(now: t0 + 2, idleSeconds: 0.1))    // the click that started it
    #expect(!away.isBack(now: t0 + 10, idleSeconds: 7.5))   // last input was at 2.5s, inside the grace
    #expect(!away.isBack(now: t0 + 600, idleSeconds: 597))  // still gone
    #expect(away.isBack(now: t0 + 600, idleSeconds: 0.5))   // came back
}

@Test func awayIgnoresTimeSpentAsleep() {
    // 2026-10-13: the keyboard/mouse idle counter stops while the Mac sleeps.
    // After a 4 minute sleep, "input 25448.5s ago" read as newer than the
    // click 7 hours earlier, and away mode ended with nobody there.
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let away = AwayReturn(enteredAt: t0)
    #expect(!away.isBack(now: t0 + 25_693.5, idleSeconds: 25_448.5))
    #expect(!away.isBack(now: t0 + 3600, idleSeconds: 60))
    #expect(away.isBack(now: t0 + 3600, idleSeconds: 0.4))
}

/// Ticks AwaySleep every 3s from `from` through `to`, like the app's main
/// loop, and returns the times it said "sleep now".
private func awaySleeps(_ a: inout AwaySleep, from: TimeInterval, to: TimeInterval,
                        needed: (TimeInterval) -> Bool = { _ in false },
                        awake: (TimeInterval) -> Bool = { _ in true }) -> [TimeInterval] {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    return stride(from: from, through: to, by: 3).filter { t in
        a.step(away: true, needed: needed(t), fullyAwake: awake(t), now: t0 + t)
    }
}

@Test func leavingSleepsOnceNothingNeedsTheMac() {
    // "I'm leaving" used to hold the Mac awake until you came back, all night
    // on 2026-10-09 and 2026-10-13. Now it sleeps a minute after Claude is done.
    var a = AwaySleep()
    // Claude works until 30s, then the quiet minute runs from the first idle tick (33s).
    #expect(awaySleeps(&a, from: 0, to: 120, needed: { $0 < 33 }) == [33 + AwaySleep.quiet])
    var b = AwaySleep()
    #expect(awaySleeps(&b, from: 0, to: 300) == [60, 123, 186, 249])   // each sleep starts the minute over
}

@Test func leavingWaitsOutGapsAndNaps() {
    var a = AwaySleep()
    // Claude picks up again between turns at 48s: the minute starts over at 51s.
    #expect(awaySleeps(&a, from: 0, to: 120, needed: { $0 == 48 }) == [51 + AwaySleep.quiet])
    var b = AwaySleep()
    #expect(awaySleeps(&b, from: 0, to: 600, awake: { _ in false }).isEmpty)   // in a nap: nothing
    var c = AwaySleep()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let notAway1 = c.step(away: false, needed: false, fullyAwake: true, now: t0)
    let notAway2 = c.step(away: false, needed: false, fullyAwake: true, now: t0 + 600)
    #expect(!notAway1 && !notAway2)
}

@Test func leavingDoesNotCountTimeAsleep() {
    // 2026-10-14 03:52Z: "I'm leaving" slept the Mac, a tick right after the
    // sleep request started a new quiet minute, and 100s later the wake itself
    // read as a quiet minute: it slept again the instant you came back.
    var a = AwaySleep()
    #expect(awaySleeps(&a, from: 0, to: 63) == [60])              // sleep, plus one tick while falling asleep
    #expect(awaySleeps(&a, from: 163, to: 220).isEmpty)           // woke 100s later: the minute starts over
    #expect(awaySleeps(&a, from: 223, to: 223) == [223])          // a full minute after waking
}

@Test func wakingWithTheLidOpenEndsLeaving() {
    #expect(awayEndsOnWake(sinceLastCheck: 100, fullyAwake: true, lidClosed: false))   // you opened it or pressed a key
    #expect(!awayEndsOnWake(sinceLastCheck: 1, fullyAwake: true, lidClosed: false))    // no sleep in between
    #expect(!awayEndsOnWake(sinceLastCheck: 100, fullyAwake: false, lidClosed: false)) // a nap
    #expect(!awayEndsOnWake(sinceLastCheck: 100, fullyAwake: true, lidClosed: true))   // a check-in with the lid shut
}

@Test func leavingRightAfterComingBackIsIgnored() {
    // The screen comes back under a click aimed at "I'm back", which by then
    // reads "I'm leaving"; that click must not start away mode again.
    let back = Date(timeIntervalSince1970: 1_000_000)
    #expect(AwayReturn.ignoresLeaving(lastReturnByInput: back, now: back + 0.5))
    #expect(AwayReturn.ignoresLeaving(lastReturnByInput: back, now: back + 1.9))
    #expect(!AwayReturn.ignoresLeaving(lastReturnByInput: back, now: back + 2.1))
    #expect(!AwayReturn.ignoresLeaving(lastReturnByInput: nil, now: back))
}

// ── Update check ──

@Test func newerVersionComparesNumbers() {
    #expect(isNewerVersion("v1.1.1", than: "1.1.0"))
    #expect(isNewerVersion("v1.10.0", than: "1.9.9"))          // numbers, not text
    #expect(isNewerVersion("1.2", than: "1.1.9"))
    #expect(isNewerVersion("v2.0.0-beta.1", than: "1.9.0"))
    #expect(!isNewerVersion("v1.1.0", than: "1.1.0"))
    #expect(!isNewerVersion("1.1.0", than: "1.1"))             // missing parts count as 0
    #expect(!isNewerVersion("1.1", than: "1.1.0"))
    #expect(!isNewerVersion("v1.0.9", than: "1.1.0"))
    #expect(!isNewerVersion("garbage", than: "1.0.0"))
    #expect(!isNewerVersion("v1.2.0", than: "unknown"))        // can't tell, so don't nag
}

@Test func latestVersionFromTheFormula() {
    // GitHub's API answered "rate limit exceeded" on a shared VPN address
    // (2026-10-14), so the check reads the Homebrew formula instead: exactly
    // what `brew upgrade` would install.
    let formula = """
    class Ephedrine < Formula
      url "https://github.com/3xyy/ephedrine/archive/refs/tags/v1.2.0.tar.gz"
      sha256 "3bdda200aa629edca59e906ad0598230e0f8d50154d0d089ac81964f9086042b"
      head "https://github.com/3xyy/ephedrine.git", branch: "main"
    """
    let r = parseFormulaVersion(formula)
    #expect(r?.version == "1.2.0")
    #expect(r?.url == "https://github.com/3xyy/ephedrine/releases/tag/v1.2.0")
    #expect(parseFormulaVersion(#"url "https://github.com/someone/else/archive/refs/tags/v9.0.0.tar.gz""#) == nil)
    #expect(parseFormulaVersion(#"head "https://github.com/3xyy/ephedrine.git""#) == nil)
    #expect(parseFormulaVersion("429: Too Many Requests") == nil)
    #expect(parseFormulaVersion("<html>error</html>") == nil)
}

@Test func updateCheckSetting() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(s.checkForUpdates)
    var changed: [String] = []
    s.onChange = { changed.append($0) }
    s.checkForUpdates = false
    #expect(changed == ["checkForUpdates"])
    #expect(!AppSettings(defaults: d).checkForUpdates)
}

// ── First-run setup screen ──

@Test func automationPermissionStates() {
    #expect(automationPermission(0) == .granted)
    #expect(automationPermission(-1743) == .denied)          // errAEEventNotPermitted
    #expect(automationPermission(-1744) == .notAsked)        // errAEEventWouldRequireUserConsent
    #expect(automationPermission(-600) == .appNotRunning)    // procNotFound: Terminal isn't open
    #expect(automationPermission(-1) == .unknown)
}

@Test func hooksInstalledDetection() {
    #expect(!claudeHooksInstalled(settingsJSON: nil))
    #expect(!claudeHooksInstalled(settingsJSON: #"{"model": "opus"}"#))
    let ours = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/Users/me/.claude/ephedrine/hook.sh idle"}]}]}}"#
    #expect(claudeHooksInstalled(settingsJSON: ours))
    // someone else's hook that merely mentions the name doesn't count
    #expect(!claudeHooksInstalled(settingsJSON: #"{"hooks": {"Stop": [{"hooks": [{"command": "echo ephedrine"}]}]}}"#))
}

@Test func setupDoneSetting() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(!s.setupDone)
    s.setupDone = true
    #expect(AppSettings(defaults: d).setupDone)
}

@Test func menuBarIconStyleSetting() {
    let d = freshDefaults()
    let s = AppSettings(defaults: d)
    #expect(s.menuBarIconStyle == .mono)            // matches the other menu bar icons by default
    var changed: [String] = []
    s.onChange = { changed.append($0) }
    s.menuBarIconStyle = .state
    #expect(changed == ["menuBarIconStyle"])
    #expect(AppSettings(defaults: d).menuBarIconStyle == .state)
    #expect(MenuBarIconStyle.allCases.map(\.label) == ["Match the menu bar", "Orange spark", "Color by state"])
}
