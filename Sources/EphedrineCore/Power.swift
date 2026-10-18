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
/// only when it's ours and no cause holds. A mode someone else switched on is
/// never ours, so it's never switched off.
public func lowPowerStep(cause: LowPowerCause?, modeOn: Bool, ours: Bool) -> LowPowerAction? {
    if let c = cause, !modeOn, !ours { return .turnOn(c) }
    if cause == nil, ours { return .turnOff }
    return nil
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
