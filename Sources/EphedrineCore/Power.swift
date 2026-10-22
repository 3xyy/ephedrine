import Foundation

// ───────────────────────────── Low Power Mode and heat ─────────────────────────────
//
// While Ephedrine holds the Mac awake somewhere costly (lid shut, battery under
// the Low Power floor, running hot) it switches Low Power Mode on through the
// lid sudoers rule. It only switches it on when it's off, records that in a
// marker file, and only switches off what it switched on.

/// Why Ephedrine wants Low Power Mode on.
public enum LowPowerCause: String { case lid, battery, heat }

/// The reason to have Low Power Mode on right now, if any. Only while
/// Ephedrine keeps the Mac awake (`holding`) or holds the lid shut (`lidHold`).
/// `floor` 0 means the battery reason is off.
public func lowPowerCause(holding: Bool, lidHold: Bool, onLidShut: Bool, onBattery: Bool, percent: Int?,
                          floor: Int, thermal: ProcessInfo.ThermalState) -> LowPowerCause? {
    guard holding || lidHold else { return nil }
    if lidHold && onLidShut { return .lid }
    if floor > 0, onBattery, let p = percent, p < floor { return .battery }
    if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .heat }
    return nil
}

public enum LowPowerAction: Equatable { case turnOn(LowPowerCause), turnOff }

/// On only when a cause holds and the mode is off and not already ours; off
/// only when it's ours, no cause holds, and the battery isn't low (`keep`,
/// lowPowerKeep). A mode someone else switched on is never ours, so it's
/// never switched off.
public func lowPowerStep(cause: LowPowerCause?, modeOn: Bool, ours: Bool, keep: Bool = false) -> LowPowerAction? {
    if let c = cause, !modeOn, !ours { return .turnOn(c) }
    if cause == nil, ours, !keep { return .turnOff }
    return nil
}

/// On battery under the Low Power level, Low Power Mode that Ephedrine switched
/// on stays on, whatever ends: keeping the Mac awake, the battery limit,
/// sleep, or Ephedrine quitting. Turning it off there is never wanted
/// (2026-10-22: it went off at 29% when Ephedrine restarted). It goes off once
/// plugged in or charged back above the level. `floor` 0 = the level is off.
public func lowPowerKeep(onBattery: Bool, percent: Int?, floor: Int) -> Bool {
    guard floor > 0, onBattery, let p = percent else { return false }
    return p < floor
}

/// Critical heat: keep nothing awake, so the Mac can cool down and sleep.
/// Holds until the thermal state drops to serious or below.
public struct HeatStop: Equatable {
    public private(set) var stopped = false
    public init() {}

    /// True only at the moment it stops (to log and notify once).
    public mutating func step(_ t: ProcessInfo.ThermalState) -> Bool {
        guard t.rawValue >= ProcessInfo.ThermalState.critical.rawValue else { stopped = false; return false }
        guard !stopped else { return false }
        stopped = true
        return true
    }
}

/// A battery that's fitted but can't be read on two reads in a row while on
/// battery counts as at the floor, so an unreadable gauge can't keep the Mac
/// awake until it dies.
public struct BatteryReadMisses {
    private var misses = 0
    public init() {}

    /// The percent to hand BatteryStop: 0 after two unreadable reads in a row
    /// on battery with a battery present, else `percent`.
    public mutating func step(onBattery: Bool, hasBattery: Bool, percent: Int?) -> Int? {
        guard onBattery, hasBattery, percent == nil else { misses = 0; return percent }
        misses = min(misses + 1, 2)
        return misses >= 2 ? 0 : nil
    }
}

/// `pmset -b` changes the battery profile only, and isLowPowerModeEnabled shows
/// that profile only while the Mac runs on its battery. Right after unplugging
/// it can still show the charger's, which could make an "Only on Battery" mode
/// the owner set look off and get recorded as Ephedrine's. So Low Power Mode is
/// switched on, and the sudoers rule tested, only once on battery this long.
public struct BatterySettle {
    public static let delay: TimeInterval = 10
    private var since: Date?
    public init() {}

    public mutating func step(onBattery: Bool, now: Date) -> Bool {
        guard onBattery else { since = nil; return false }
        let s = since ?? now
        since = s
        return now.timeIntervalSince(s) >= Self.delay
    }
}

/// The causes that could still hold right now, whatever the reading says:
/// battery while Ephedrine keeps the Mac awake on battery with a floor set,
/// heat while it keeps the Mac awake at all. Never the lid (LowPowerHold).
public func lowPowerEligible(holding: Bool, lidHold: Bool, onBattery: Bool, floor: Int) -> Set<LowPowerCause> {
    guard holding || lidHold else { return [] }
    return floor > 0 && onBattery ? [.battery, .heat] : [.heat]
}

/// Low Power Mode cools the Mac and so removes its own heat cause; a Mac near
/// serious would switch it on, off, on. While it's ours, a heat or battery
/// cause that held is still reported until `linger` after it last held, but
/// only while it's still `eligible` (lowPowerEligible): the hold is for a
/// reading that recovered, not for a cause that no longer applies (keep-awake
/// over, plugged in, the floor set to off), which ends at once. Not the lid:
/// opening it means the owner is back, so that ends at once too. Causes are
/// remembered even before it's ours, so the one that switched it on counts
/// from that tick.
public struct LowPowerHold {
    public static let linger: TimeInterval = 300
    private var last: LowPowerCause?
    private var lastAt = Date.distantPast
    public init() {}

    public mutating func step(cause: LowPowerCause?, ours: Bool, eligible: Set<LowPowerCause>, now: Date) -> LowPowerCause? {
        if let c = cause { last = c; lastAt = now; return c }
        guard ours, let held = last, held != .lid, eligible.contains(held),
              now.timeIntervalSince(lastAt) < Self.linger else { last = nil; return nil }
        return held
    }
}

/// Ours, yet off on a settled battery (where the reading is the battery
/// profile Ephedrine wrote) on two readings at least `confirm` apart, with no
/// other kind of reading between: the owner switched it off by hand. Timed,
/// not counted, because evaluate() also runs on clicks and setting changes,
/// so two readings can be moments apart. Then the marker is dropped without
/// writing anything, so a later "off" can't undo an "on" the owner makes, and
/// Ephedrine doesn't switch it on again until the cause has ended.
public struct LowPowerOwnership {
    /// Time after our switch-on for the reading to catch up.
    public static let settle: TimeInterval = 10
    /// The two "off" readings are at least this far apart.
    public static let confirm: TimeInterval = 3
    private var firstOffAt: Date?
    public private(set) var ownerTookOver = false
    public init() {}

    /// True when the marker should be dropped (once per takeover).
    public mutating func step(ours: Bool, settled: Bool, inFlight: Bool, sinceOurSwitchOn: TimeInterval, modeOn: Bool, now: Date) -> Bool {
        guard ours, settled, !inFlight, sinceOurSwitchOn >= Self.settle, !modeOn else { firstOffAt = nil; return false }
        guard let first = firstOffAt else { firstOffAt = now; return false }
        guard now.timeIntervalSince(first) >= Self.confirm else { return false }
        firstOffAt = nil
        ownerTookOver = true
        return true
    }

    /// Call every tick with the (held) cause; a tick with none ends the takeover.
    public mutating func noteCause(_ cause: LowPowerCause?) {
        if cause == nil { ownerTookOver = false }
    }
}

/// Wait before asking the sudoers rule again after it said no (`failures` in a
/// row): 1, 5, then every 15 minutes. sudo logs each refusal.
public func lowPowerRecheckDelay(failures: Int) -> TimeInterval {
    failures <= 1 ? 60 : failures == 2 ? 300 : 900
}
