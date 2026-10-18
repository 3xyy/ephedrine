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
