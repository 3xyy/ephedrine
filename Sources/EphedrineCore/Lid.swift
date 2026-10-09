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

/// `lidBatteryFloor` value meaning "never on battery, only on the charger".
public let lidOnlyPluggedIn = 100

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
}

public struct LidInputs {
    public var whileClaude: Bool      // the "While Claude is working" setting (and the master switch)
    public var claudeBusy: Bool       // Claude working, retrying, or waiting out a usage limit
    public var lidClosed: Bool
    public var onBattery: Bool
    public var batteryPercent: Int?   // nil = no battery / unknown
    public var batteryFloor: Int      // 0 = no battery guard
    public var hot: Bool              // past the heat limit (lidTooHot)
    public var closedCap: TimeInterval   // Claude-driven mode stops once the lid's been shut this long; 0 = never
    public var now: Date
    public init(whileClaude: Bool, claudeBusy: Bool, lidClosed: Bool, onBattery: Bool,
                batteryPercent: Int?, batteryFloor: Int, hot: Bool, closedCap: TimeInterval = 0, now: Date) {
        self.whileClaude = whileClaude; self.claudeBusy = claudeBusy; self.lidClosed = lidClosed
        self.onBattery = onBattery; self.batteryPercent = batteryPercent; self.batteryFloor = batteryFloor
        self.hot = hot; self.closedCap = closedCap; self.now = now
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
    let wanted = s.session != nil || fromClaude

    let unplugged = i.onBattery && i.batteryFloor >= lidOnlyPluggedIn
    let low = i.onBattery && i.batteryFloor > 0 && (i.batteryPercent.map { $0 <= i.batteryFloor } ?? false)
    let guardNow: LidGuard? = i.hot ? .hot : unplugged ? .unplugged : low ? .lowBattery : nil

    if let g = guardNow, wanted || s.tripped != nil {
        if s.tripped == nil { out.newlyTripped = g }
        s.tripped = g
        if s.session != nil { s.session = nil; out.sessionEnded = LidSessionEnd(rawValue: g.rawValue) }
    } else if guardNow == nil && !i.lidClosed {
        s.tripped = nil
    }

    out.disableSleep = s.tripped == nil && (s.session != nil || fromClaude)
    return out
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
