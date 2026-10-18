import Foundation
import Testing
@testable import EphedrineCore

@Test func lowPowerCauses() {
    #expect(lowPowerCause(holding: false, lidHold: false, onLidShut: true, onBattery: true, percent: 5, floor: 40, thermal: .serious) == nil)
    #expect(lowPowerCause(holding: false, lidHold: true, onLidShut: true, onBattery: false, percent: 90, floor: 40, thermal: .nominal) == .lid)
    #expect(lowPowerCause(holding: true, lidHold: false, onLidShut: true, onBattery: true, percent: 39, floor: 40, thermal: .nominal) == .battery)
    #expect(lowPowerCause(holding: true, lidHold: false, onLidShut: true, onBattery: true, percent: 39, floor: 0, thermal: .nominal) == nil)
    #expect(lowPowerCause(holding: true, lidHold: false, onLidShut: true, onBattery: false, percent: 10, floor: 40, thermal: .serious) == .heat)
}
@Test func lowPowerNeverClearsForeignMode() {
    #expect(lowPowerStep(cause: nil, modeOn: true, ours: false) == nil)
    #expect(lowPowerStep(cause: .lid, modeOn: true, ours: false) == nil)
    #expect(lowPowerStep(cause: .lid, modeOn: false, ours: false) == .turnOn(.lid))
    #expect(lowPowerStep(cause: nil, modeOn: true, ours: true) == .turnOff)
    #expect(lowPowerStep(cause: .battery, modeOn: true, ours: true) == nil)
}
// #expect can't call a mutating method itself, so each test steps through a local func.
@Test func heatStopLatches() {
    var h = HeatStop()
    func step(_ t: ProcessInfo.ThermalState) -> Bool { h.step(t) }
    #expect(!step(.serious)); #expect(step(.critical)); #expect(!step(.critical)); #expect(h.stopped)
    #expect(!step(.serious)); #expect(!h.stopped)
}
@Test func unreadableBatteryCountsAsFloor() {
    var m = BatteryReadMisses()
    func step(onBattery: Bool, hasBattery: Bool, percent: Int?) -> Int? { m.step(onBattery: onBattery, hasBattery: hasBattery, percent: percent) }
    #expect(step(onBattery: true, hasBattery: true, percent: nil) == nil)
    #expect(step(onBattery: true, hasBattery: true, percent: nil) == 0)
    #expect(step(onBattery: true, hasBattery: true, percent: 50) == 50)
    #expect(step(onBattery: true, hasBattery: false, percent: nil) == nil)
}
@Test func sudoersRuleHasLowPower() {
    #expect(lidSudoersRule(user: "uv") == "uv ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -b lowpowermode 0, /usr/bin/pmset -b lowpowermode 1\n")
}

// `pmset -b` writes the battery profile, which isLowPowerModeEnabled shows only
// once the Mac has run on battery for a moment. Before that, an "Only on Battery"
// mode the owner set could read as off and be taken for Ephedrine's.
@Test func lowPowerWaitsForBatteryProfile() {
    var s = BatterySettle()
    let t0 = Date(timeIntervalSince1970: 1000)
    func step(_ onBattery: Bool, _ t: TimeInterval) -> Bool { s.step(onBattery: onBattery, now: t0 + t) }
    let d = BatterySettle.delay
    #expect(!step(false, 0))
    #expect(!step(true, 0))
    #expect(!step(true, d - 1))
    #expect(step(true, d))
    #expect(!step(false, d + 1))   // plugged in: starts over
    #expect(!step(true, d + 2))
}

// Beyond the cases above: what each remaining guard is there for.
@Test func lowPowerStepKeepsOursUntilNoCause() {
    #expect(lowPowerStep(cause: .lid, modeOn: false, ours: true) == nil)       // already ours (reads off on the charger): no second "on"
    #expect(lowPowerStep(cause: nil, modeOn: false, ours: true) == .turnOff)   // turned off by hand meanwhile: still drop our marker
    #expect(lowPowerStep(cause: nil, modeOn: false, ours: false) == nil)
}
@Test func lowPowerCauseEdges() {
    #expect(lowPowerCause(holding: true, lidHold: true, onLidShut: false, onBattery: false, percent: 90, floor: 40, thermal: .nominal) == nil)
    #expect(lowPowerCause(holding: true, lidHold: false, onLidShut: true, onBattery: true, percent: 40, floor: 40, thermal: .nominal) == nil)
    #expect(lowPowerCause(holding: true, lidHold: false, onLidShut: true, onBattery: true, percent: nil, floor: 40, thermal: .fair) == nil)
}
@Test func batteryMissesNeedABatteryOnBattery() {
    var m = BatteryReadMisses()
    func step(_ onBattery: Bool, _ hasBattery: Bool, _ percent: Int?) -> Int? { m.step(onBattery: onBattery, hasBattery: hasBattery, percent: percent) }
    #expect(step(true, false, nil) == nil); #expect(step(true, false, nil) == nil)   // no battery fitted (a desktop on a UPS)
    #expect(step(false, true, nil) == nil); #expect(step(false, true, nil) == nil)   // on the charger
    #expect(step(true, true, nil) == nil); #expect(step(true, true, 30) == 30); #expect(step(true, true, nil) == nil)   // a good read starts over
}

// Fix round 1 (R30): Low Power Mode cools the Mac and so removes its own heat
// cause. Holding a cause 5 minutes after it last held stops the on/off cycling.
@Test func lowPowerHoldKeepsACauseFiveMinutes() {
    var h = LowPowerHold()
    let t0 = Date(timeIntervalSince1970: 1000)
    func step(_ c: LowPowerCause?, ours: Bool = true, _ t: TimeInterval) -> LowPowerCause? { h.step(cause: c, ours: ours, eligible: [.battery, .heat], now: t0 + t) }
    #expect(step(.heat, 0) == .heat)
    #expect(step(nil, 60) == .heat)
    #expect(step(nil, 299) == .heat)
    #expect(step(nil, 301) == nil)
}
@Test func lowPowerHoldNewCauseReplacesHeld() {
    var h = LowPowerHold()
    let t0 = Date(timeIntervalSince1970: 1000)
    func step(_ c: LowPowerCause?, _ t: TimeInterval) -> LowPowerCause? { h.step(cause: c, ours: true, eligible: [.battery, .heat], now: t0 + t) }
    #expect(step(.heat, 0) == .heat)
    #expect(step(.battery, 60) == .battery)
    #expect(step(nil, 120) == .battery)
    #expect(step(nil, 60 + 299) == .battery)   // timed from the battery cause's last tick
    #expect(step(nil, 60 + 301) == nil)
}
@Test func lowPowerHoldOnlyWhileOurs() {
    var h = LowPowerHold()
    let t0 = Date(timeIntervalSince1970: 1000)
    func step(_ c: LowPowerCause?, ours: Bool, _ t: TimeInterval) -> LowPowerCause? { h.step(cause: c, ours: ours, eligible: [.battery, .heat], now: t0 + t) }
    #expect(step(.heat, ours: false, 0) == .heat)
    #expect(step(nil, ours: false, 60) == nil)
    // The cause on the tick that switched it on still counts once it's ours.
    var h2 = LowPowerHold()
    func step2(_ c: LowPowerCause?, ours: Bool, _ t: TimeInterval) -> LowPowerCause? { h2.step(cause: c, ours: ours, eligible: [.battery, .heat], now: t0 + t) }
    #expect(step2(.heat, ours: false, 0) == .heat)
    #expect(step2(nil, ours: true, 3) == .heat)
}

// Fix round 1 (R31): ours, on a settled battery, reading off on two ticks in a
// row means the owner switched it off by hand. The marker is dropped (nothing
// is written), and it isn't switched on again until the cause has ended.
@Test func ownershipDropsAfterTwoOffTicks() {
    var o = LowPowerOwnership()
    let t0 = Date(timeIntervalSince1970: 1000)
    func step(since: TimeInterval = 60, on: Bool, _ t: TimeInterval) -> Bool {
        o.step(ours: true, settled: true, inFlight: false, sinceOurSwitchOn: since, modeOn: on, now: t0 + t)
    }
    #expect(!step(since: 10, on: false, 0))
    #expect(step(since: 13, on: false, 3))
    #expect(o.ownerTookOver)
}
@Test func ownershipNeverDropsWhileUnsure() {
    var o = LowPowerOwnership()
    var t = Date(timeIntervalSince1970: 1000)
    func step(ours: Bool = true, settled: Bool = true, inFlight: Bool = false, since: TimeInterval = 60, on: Bool) -> Bool {
        t += 3   // a tick apart, so only the conditions keep it from dropping
        return o.step(ours: ours, settled: settled, inFlight: inFlight, sinceOurSwitchOn: since, modeOn: on, now: t)
    }
    for _ in 0..<3 { #expect(!step(inFlight: true, on: false)) }
    for _ in 0..<3 { #expect(!step(settled: false, on: false)) }
    for _ in 0..<3 { #expect(!step(since: 9, on: false)) }
    for _ in 0..<3 { #expect(!step(ours: false, on: false)) }
    #expect(!step(on: false)); #expect(!step(on: true)); #expect(!step(on: false))   // an on-reading starts the count over
    #expect(!o.ownerTookOver)
}
@Test func ownerTakeoverLastsUntilTheCauseEnds() {
    var o = LowPowerOwnership()
    var t = Date(timeIntervalSince1970: 1000)
    func step(on: Bool) -> Bool { t += 3; return o.step(ours: true, settled: true, inFlight: false, sinceOurSwitchOn: 60, modeOn: on, now: t) }
    _ = step(on: false)
    #expect(step(on: false))
    o.noteCause(.heat)
    #expect(o.ownerTookOver)
    o.noteCause(nil)
    #expect(!o.ownerTookOver)
}

// Fix round 1 (R32): sudo logs every failed rule check, so they back off.
@Test func ruleRecheckBacksOff() {
    #expect(lowPowerRecheckDelay(failures: 1) == 60)
    #expect(lowPowerRecheckDelay(failures: 2) == 300)
    #expect(lowPowerRecheckDelay(failures: 3) == 900)
    #expect(lowPowerRecheckDelay(failures: 9) == 900)
}

// R33: opening the lid means the owner is back, so the lid cause isn't held;
// heat (and battery) still are.
@Test func lowPowerHoldSkipsTheLid() {
    var h = LowPowerHold()
    let t0 = Date(timeIntervalSince1970: 1000)
    func step(_ c: LowPowerCause?, _ t: TimeInterval) -> LowPowerCause? { h.step(cause: c, ours: true, eligible: [.battery, .heat], now: t0 + t) }
    #expect(step(.lid, 0) == .lid)
    #expect(step(nil, 3) == nil)
    #expect(step(.heat, 6) == .heat)
    #expect(step(nil, 66) == .heat)
}

// Final review I1: the hold is for a reading that recovered, not for a cause
// that no longer applies. Battery stays eligible only while Ephedrine keeps
// the Mac awake on battery with a floor set; heat while it keeps it awake at all.
@Test func lowPowerEligibility() {
    func e(holding: Bool = true, lidHold: Bool = false, onBattery: Bool = true, floor: Int = 40) -> Set<LowPowerCause> {
        lowPowerEligible(holding: holding, lidHold: lidHold, onBattery: onBattery, floor: floor)
    }
    #expect(e() == [.battery, .heat])
    #expect(e(holding: false, lidHold: true) == [.battery, .heat])
    #expect(e(holding: false) == [])                  // keep-awake ended (master switch off, nothing working)
    #expect(e(onBattery: false) == [.heat])           // plugged in
    #expect(e(floor: 0) == [.heat])                   // the floor set to off
    #expect(!e().contains(.lid))
}
@Test func lowPowerHoldEndsWhenTheCauseNoLongerApplies() {
    let t0 = Date(timeIntervalSince1970: 1000)
    // Battery: held while eligible, dropped the tick it isn't (plugged in, floor off, keep-awake over).
    var b = LowPowerHold()
    #expect(b.step(cause: .battery, ours: true, eligible: [.battery, .heat], now: t0) == .battery)
    #expect(b.step(cause: nil, ours: true, eligible: [.battery, .heat], now: t0 + 60) == .battery)
    #expect(b.step(cause: nil, ours: true, eligible: [.heat], now: t0 + 63) == nil)
    #expect(b.step(cause: nil, ours: true, eligible: [.battery, .heat], now: t0 + 66) == nil)   // stays dropped
    // Heat: held while eligible, dropped once keep-awake ends.
    var h = LowPowerHold()
    #expect(h.step(cause: .heat, ours: true, eligible: [.heat], now: t0) == .heat)
    #expect(h.step(cause: nil, ours: true, eligible: [.heat], now: t0 + 60) == .heat)
    #expect(h.step(cause: nil, ours: true, eligible: [], now: t0 + 63) == nil)
    // The lid is never held, even if it were passed as eligible.
    var l = LowPowerHold()
    #expect(l.step(cause: .lid, ours: true, eligible: [.lid, .heat], now: t0) == .lid)
    #expect(l.step(cause: nil, ours: true, eligible: [.lid, .heat], now: t0 + 3) == nil)
}
// The linger is strict: a cause last seen 299.9 s ago is still held, one seen
// exactly 300 s ago is not.
@Test func lowPowerHoldBoundaryIsStrict() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var a = LowPowerHold()
    #expect(a.step(cause: .heat, ours: true, eligible: [.heat], now: t0) == .heat)
    #expect(a.step(cause: nil, ours: true, eligible: [.heat], now: t0 + 299.9) == .heat)
    #expect(a.step(cause: nil, ours: true, eligible: [.heat], now: t0 + 300) == nil)
}
// The two "off" readings must be at least 3 s apart, whatever the number of
// evaluate() calls between them; any other reading starts over.
@Test func ownershipTakeoverIsTimed() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var o = LowPowerOwnership()
    func off(_ t: TimeInterval) -> Bool { o.step(ours: true, settled: true, inFlight: false, sinceOurSwitchOn: 60, modeOn: false, now: t0 + t) }
    #expect(!off(0)); #expect(!off(0.1)); #expect(!off(1)); #expect(!off(2.9))   // quick evaluate() calls don't count
    #expect(off(3))
    #expect(o.ownerTookOver)
    var p = LowPowerOwnership()
    func off2(_ t: TimeInterval) -> Bool { p.step(ours: true, settled: true, inFlight: false, sinceOurSwitchOn: 60, modeOn: false, now: t0 + t) }
    func on2(_ t: TimeInterval) -> Bool { p.step(ours: true, settled: true, inFlight: false, sinceOurSwitchOn: 60, modeOn: true, now: t0 + t) }
    #expect(!off2(0)); #expect(!on2(2)); #expect(!off2(3))   // an "on" reading in between starts over
    #expect(!off2(5.9)); #expect(off2(6))
}
