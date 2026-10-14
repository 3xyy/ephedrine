import Foundation

// ───────────────────────────── Lid-closed mode ─────────────────────────────
//
// Pure decision logic for "stay awake with the lid closed" (`pmset disablesleep`).
// The app feeds it the lid / power / Claude state every tick and applies the
// result; everything here is deterministic so it can be unit-tested.

/// A one-off "stay awake with the lid closed" session started from the menu.
public enum LidSession: Equatable {
    case untilLidOpens        // ends the next time the lid goes closed → open
    case until(Date)          // ends at a time
    case indefinite           // ends only when turned off
}

/// Why lid-closed mode was forced off despite something wanting it.
public enum LidGuard: String {
    case lowBattery, unplugged, hot
}

/// `batteryFloor` value meaning "never on battery, only on the charger".
public let lidOnlyPluggedIn = 100
/// The lowest battery limit there is: nothing Ephedrine does runs a battery flat.
public let minBatteryFloor = 10

/// How hot the Mac may get before lid-closed mode gives up. macOS has no
/// public °C reading; this is its thermal pressure, the one it throttles on.
public enum LidHeatLimit: String, CaseIterable {
    case warm, hot, veryHot
}

public func lidTooHot(_ t: ProcessInfo.ThermalState, limit: LidHeatLimit) -> Bool {
    switch limit {
    case .warm:    return t != .nominal
    case .hot:     return t == .serious || t == .critical
    case .veryHot: return t == .critical
    }
}

public struct LidState: Equatable {
    public var session: LidSession?
    public var lidWasClosed = false
    public var lastClaudeBusy = Date.distantPast
    /// Set when a guard forces lid mode off; stays set until the guard clears
    /// AND the lid is open, so a Mac that cooled down in a bag doesn't re-arm.
    public var tripped: LidGuard?
    public var closedSince: Date?
    public var capped = false          // the lid-shut cap already stopped Claude-driven mode this close
    public init(session: LidSession? = nil) { self.session = session }

    /// A Remote Control check-in starts the lid-shut cap over, or work it
    /// picks up after hours asleep would be stopped at once.
    public mutating func restartClosedClock(now: Date) {
        if closedSince != nil { closedSince = now }
        capped = false
    }
}

public struct LidInputs {
    public var whileClaude: Bool      // the "While Claude is working" setting (and the master switch)
    public var claudeBusy: Bool       // Claude working, retrying, or waiting out a usage limit
    public var lidClosed: Bool
    public var onBattery: Bool
    public var batteryPercent: Int?   // nil = no battery / unknown
    public var batteryFloor: Int      // the battery setting (awakeBatteryFloor applies the 10% minimum)
    public var hot: Bool              // past the heat limit (lidTooHot)
    public var closedCap: TimeInterval   // Claude-driven mode stops once the lid's been shut this long; 0 = never
    public var checkIn: Bool         // a Remote Control check-in is open (RemoteCheckIn.isOpen)
    public var now: Date
    public init(whileClaude: Bool, claudeBusy: Bool, lidClosed: Bool, onBattery: Bool,
                batteryPercent: Int?, batteryFloor: Int, hot: Bool, closedCap: TimeInterval = 0,
                checkIn: Bool = false, now: Date) {
        self.whileClaude = whileClaude; self.claudeBusy = claudeBusy; self.lidClosed = lidClosed
        self.onBattery = onBattery; self.batteryPercent = batteryPercent; self.batteryFloor = batteryFloor
        self.hot = hot; self.closedCap = closedCap; self.checkIn = checkIn; self.now = now
    }
}

public enum LidSessionEnd: String {
    case lidOpened, timeUp, lowBattery, unplugged, hot
}

public struct LidOutput: Equatable {
    public var disableSleep: Bool
    public var sessionEnded: LidSessionEnd?
    public var newlyTripped: LidGuard?    // report once per trip (notification)
    public var capReached = false         // the lid-shut cap just stopped Claude-driven mode (once per close)
}

/// Keep lid mode on this long after Claude stops, so the gap between turns,
/// subagents, or an auto-continue retry doesn't put the Mac to sleep.
public let lidClaudeLinger: TimeInterval = 60

public func stepLid(_ s: inout LidState, _ i: LidInputs) -> LidOutput {
    var out = LidOutput(disableSleep: false, sessionEnded: nil, newlyTripped: nil)
    let opened = s.lidWasClosed && !i.lidClosed
    if i.lidClosed && !s.lidWasClosed { s.closedSince = i.now }
    if !i.lidClosed { s.closedSince = nil; s.capped = false }
    s.lidWasClosed = i.lidClosed
    if i.claudeBusy { s.lastClaudeBusy = i.now }

    switch s.session {
    case .untilLidOpens? where opened:
        s.session = nil; out.sessionEnded = .lidOpened
    case .until(let end)? where i.now >= end:
        s.session = nil; out.sessionEnded = .timeUp
    default: break
    }

    var fromClaude = i.whileClaude
        && (i.claudeBusy || i.now.timeIntervalSince(s.lastClaudeBusy) < lidClaudeLinger)
    // The cap is a backstop for automatic mode (say, a stuck session that looks
    // busy forever); a session the user started runs as chosen.
    if fromClaude, i.closedCap > 0, let since = s.closedSince, i.now.timeIntervalSince(since) >= i.closedCap {
        fromClaude = false
        if !s.capped { s.capped = true; out.capReached = true }
    }
    let wanted = s.session != nil || fromClaude || i.checkIn
    let guardNow = lidGuard(i)

    if let g = guardNow, wanted || s.tripped != nil {
        if s.tripped == nil { out.newlyTripped = g }
        s.tripped = g
        if s.session != nil { s.session = nil; out.sessionEnded = LidSessionEnd(rawValue: g.rawValue) }
    } else if guardNow == nil && !i.lidClosed {
        s.tripped = nil
    }

    out.disableSleep = s.tripped == nil && wanted
    return out
}

/// The battery or heat limit that says "sleep anyway" right now, if any.
public func lidGuard(_ i: LidInputs) -> LidGuard? {
    let floor = awakeBatteryFloor(i.batteryFloor)
    let unplugged = i.onBattery && floor >= lidOnlyPluggedIn
    let low = i.onBattery && (i.batteryPercent.map { $0 <= floor } ?? false)
    return i.hot ? .hot : unplugged ? .unplugged : low ? .lowBattery : nil
}

/// On battery at or below this, Ephedrine stops keeping the Mac awake for
/// anything ("I'm leaving", Stay awake, Claude, lid mode, usage-limit waits),
/// so a night on battery can't end with a dead Mac. The battery setting, never
/// under 10%; `lidOnlyPluggedIn` means never on battery at all.
public func awakeBatteryFloor(_ setting: Int) -> Int {
    setting >= lidOnlyPluggedIn ? lidOnlyPluggedIn : max(minBatteryFloor, setting)
}

/// Latches when the battery reaches the floor and holds until the Mac is
/// plugged in, so hovering around the floor can't flip keep-awake on and off.
public struct BatteryStop: Equatable {
    public private(set) var stopped = false
    public init() {}

    /// True only at the moment it stops (to log and notify once).
    public mutating func step(onBattery: Bool, percent: Int?, floor: Int) -> Bool {
        if !onBattery { stopped = false; return false }
        guard !stopped, let p = percent, p <= floor else { return false }
        stopped = true
        return true
    }
}

/// A limit says "sleep anyway" now, or tripped earlier and holds until the lid opens.
public func lidGuardActive(_ s: LidState, _ i: LidInputs) -> Bool {
    lidGuard(i) != nil || s.tripped != nil
}

// ── Remote Control check-ins ──
//
// `claude remote-control` asks Anthropic for new messages; nothing can reach a
// sleeping Mac. With the lid shut, macOS still naps awake every 10 to 18
// minutes (a DarkWake: no screen, no Wi-Fi). A check-in turns one of those naps
// into a full wake for `window`, so Remote Control can fetch what was sent from
// a phone. If Claude starts working, Claude-driven lid mode keeps the Mac awake
// as usual; if not, the window closes and it sleeps again.

public enum CheckInEnd: String {
    case windowOver, noFullWake, lidOpened, turnedOff, guarded
}

public enum CheckInEvent: Equatable {
    case started                          // switch sleep off and ask for a full wake
    case fullyAwake(after: TimeInterval)
    case ended(CheckInEnd)
}

public struct CheckInInputs {
    public var enabled: Bool          // the setting, lid setup, and Claude-driven lid mode all on
    public var lidClosed: Bool
    public var fullyAwake: Bool       // systemFullyAwake: false during a nap
    public var sleepStarting: Bool    // macOS announced a sleep in the last minute
    public var externalDisplay: Bool
    public var guarded: Bool          // lidGuard says sleep anyway
    public var onBattery: Bool        // check in less often
    public var now: Date
    public init(enabled: Bool, lidClosed: Bool, fullyAwake: Bool, sleepStarting: Bool,
                externalDisplay: Bool, guarded: Bool, onBattery: Bool = false, now: Date) {
        self.enabled = enabled; self.lidClosed = lidClosed; self.fullyAwake = fullyAwake
        self.sleepStarting = sleepStarting; self.externalDisplay = externalDisplay
        self.guarded = guarded; self.onBattery = onBattery; self.now = now
    }
}

public struct RemoteCheckIn: Equatable {
    /// Fully awake this long, waiting for a message.
    public static let window: TimeInterval = 120
    /// A nap that hasn't become a full wake by now won't (on 2026-10-05 sleep
    /// switched off inside a nap held the Mac there, no Wi-Fi, for 74 minutes).
    public static let fullWakeTimeout: TimeInterval = 30
    /// Between check-ins, so clustered naps don't each wake the Mac. Naps can
    /// come every 5 minutes, which on battery meant 2 minutes awake in every 5.
    public static let spacing: TimeInterval = 300
    public static let spacingOnBattery: TimeInterval = 900
    /// Not right as the lid closes: capabilities drop the same way while it falls asleep.
    public static let afterClose: TimeInterval = 60

    public private(set) var startedAt: Date?
    public private(set) var awakeAt: Date?
    public private(set) var lastStart = Date.distantPast
    private var closedSince: Date?
    public init() {}

    /// Holding the Mac awake (feeds LidInputs.checkIn).
    public var isOpen: Bool { startedAt != nil }

    /// Call every tick.
    public mutating func step(_ i: CheckInInputs) -> CheckInEvent? {
        if !i.lidClosed { closedSince = nil } else if closedSince == nil { closedSince = i.now }
        if let start = startedAt {
            let end: CheckInEnd?
            if !i.lidClosed { end = .lidOpened }
            else if !i.enabled { end = .turnedOff }
            else if i.guarded { end = .guarded }
            else if let awake = awakeAt { end = i.now.timeIntervalSince(awake) >= Self.window ? .windowOver : nil }
            else if i.fullyAwake { awakeAt = i.now; return .fullyAwake(after: i.now.timeIntervalSince(start)) }
            else { end = i.now.timeIntervalSince(start) >= Self.fullWakeTimeout ? .noFullWake : nil }
            guard let e = end else { return nil }
            cancel()
            return .ended(e)
        }
        guard i.enabled, i.lidClosed, !i.fullyAwake, !i.sleepStarting, !i.externalDisplay, !i.guarded,
              let closed = closedSince, i.now.timeIntervalSince(closed) >= Self.afterClose,
              i.now.timeIntervalSince(lastStart) >= (i.onBattery ? Self.spacingOnBattery : Self.spacing) else { return nil }
        startedAt = i.now; awakeAt = nil; lastStart = i.now
        return .started
    }

    /// Drop an open check-in (say the sleep switch failed). Spacing still applies.
    public mutating func cancel() { startedAt = nil; awakeAt = nil }
}

/// Re-asks macOS to sleep when it should be asleep but isn't. macOS only
/// clamshell-sleeps at the moment the lid closes: switching disablesleep off
/// with the lid already shut leaves the Mac awake until something asks, and on
/// 2026-10-07 the one request went unanswered, leaving it awake in the dark for up to 55 minutes.
public struct LidSleepWatch {
    public static let settle: TimeInterval = 20      // give a normal sleep time to start first
    public static let retryEvery: TimeInterval = 60
    private var stuckSince: Date?
    private var lastRequest = Date.distantPast
    public init() {}

    /// True when it's time to request sleep (again). `sleepStarting`: macOS
    /// announced a sleep that hasn't happened yet (it can take 30s).
    public mutating func step(lidClosed: Bool, sleepDisabled: Bool, fullyAwake: Bool,
                              externalDisplay: Bool, lidWanted: Bool, sleepStarting: Bool, now: Date) -> Bool {
        guard lidClosed, !sleepDisabled, fullyAwake, !externalDisplay, !lidWanted, !sleepStarting else {
            stuckSince = nil; return false
        }
        let since = stuckSince ?? now
        stuckSince = since
        guard now.timeIntervalSince(since) >= Self.settle,
              now.timeIntervalSince(lastRequest) >= Self.retryEvery else { return false }
        lastRequest = now
        return true
    }
}

/// Menu/status wording for a session.
public func lidSessionText(_ s: LidSession, now: Date) -> String {
    switch s {
    case .untilLidOpens: return "until you open the lid"
    case .indefinite:    return "until you turn it off"
    case .until(let d):  return "until \(clockStr(d)) (\(fmtDuration(Int(d.timeIntervalSince(now)))) left)"
    }
}

/// "7h 05m", "45m", "30s": for spans too long for fmtCountdown's m:ss.
public func fmtDuration(_ secs: Int) -> String {
    let s = max(0, secs)
    if s < 60 { return "\(s)s" }
    let m = (s + 59) / 60   // round up: "1m left" until it's really gone
    return m >= 60 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(m)m"
}

/// The next `count` whole hours after `now` (for the "Until…" submenu).
public func nextWholeHours(after now: Date, count: Int, calendar: Calendar = .current) -> [Date] {
    guard let top = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
    return (1...max(1, count)).compactMap { calendar.date(byAdding: .hour, value: $0, to: top) }
}

/// The sudoers drop-in that lets the app flip `disablesleep` without a password.
/// Only these two exact command lines are allowed.
public func lidSudoersRule(user: String) -> String {
    "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
}

/// The next moment at `time`'s hour:minute strictly after `now` (today, else tomorrow).
public func nextOccurrence(ofTimeIn time: Date, after now: Date, calendar: Calendar = .current) -> Date {
    let hm = calendar.dateComponents([.hour, .minute], from: time)
    let today = calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: now) ?? now
    return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
}

/// Applies on/off changes to a slow external switch (`sudo pmset`) strictly in
/// order on one serial queue, so a synchronous "off" at quit can never be
/// overtaken by an earlier asynchronous "on" that's still running.
public final class SerialSwitch {
    private let queue: DispatchQueue
    private let apply: (Bool) -> Bool

    public init(label: String, apply: @escaping (Bool) -> Bool) {
        queue = DispatchQueue(label: label)
        self.apply = apply
    }
    /// `done` runs on the switch's queue with whether the change worked.
    public func setAsync(_ on: Bool, done: @escaping (Bool) -> Void) {
        queue.async { [apply] in done(apply(on)) }
    }
    /// Waits for anything queued before it. Keep slow work (dialogs) off this
    /// queue: quit and sleep wait on it.
    @discardableResult
    public func setSync(_ on: Bool) -> Bool { queue.sync { apply(on) } }
}

// ── Background reasons on battery ──

/// Only wait out usage limits resetting within this (session limits are ≤5h).
public let limitWaitCap: TimeInterval = 6 * 3600
/// Stay awake this long past a reset so the resume can land.
public let limitWaitGrace: TimeInterval = 5 * 60
/// On battery, a usage-limit wait keeps the Mac awake only this close to the reset.
public let limitWaitOnBattery: TimeInterval = 3600

/// Whether scheduled usage-limit resumes (reset + 1 min each) keep the Mac
/// awake now. On 2026-10-13 a 4h40m wait held it awake on battery from 80%
/// down to the battery limit; on battery only a reset within the hour counts.
public func limitWaitHolds(resumeAts: [Date], now: Date, onBattery: Bool) -> Bool {
    resumeAts.contains { at in
        now < at + limitWaitGrace && (!onBattery || at.timeIntervalSince(now) <= limitWaitOnBattery)
    }
}

/// "Also keep awake while…" detectors have no end of their own (a dev server
/// runs all day; one held the Mac awake 12.6 hours on 2026-10-09). On battery
/// they get an hour, then the Mac may sleep. The activity stopping or the
/// charger coming and going starts the hour over.
public struct DetectorBatteryCap {
    public static let limit: TimeInterval = 3600
    private var since: Date?
    public init() {}

    public mutating func allows(active: Bool, onBattery: Bool, now: Date) -> Bool {
        guard active, onBattery else { since = nil; return active }
        let s = since ?? now
        since = s
        return now.timeIntervalSince(s) < Self.limit
    }
}
