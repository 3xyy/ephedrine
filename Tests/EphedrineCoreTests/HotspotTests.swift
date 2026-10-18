import Testing
import Foundation
@testable import EphedrineCore

@Test func hotspotBackoff() {
    #expect([0, 1, 2, 3, 9].map(hotspotRetryDelay) == [5, 10, 20, 30, 30])
}

@Test func hotspotGate() {
    var g = HotspotJoinGate(); let t0 = Date(timeIntervalSince1970: 0)
    func s(_ t: TimeInterval, up: Bool = false, holding: Bool = true, awake: Bool = true) -> Bool {
        g.step(wifiUp: up, holding: holding, fullyAwake: awake, configured: true, now: t0.addingTimeInterval(t))
    }
    #expect(!s(0))
    #expect(s(5))
    #expect(!s(9))
    #expect(s(15))
    #expect(!s(60, awake: false))
    #expect(!s(61, up: true))
    #expect(!s(62))
    #expect(!s(70, holding: false))   // down 8 s, but nothing is holding the Mac awake
}

@Test func hotspotGateRestartsAfterWifiReturns() {
    var g = HotspotJoinGate(); let t0 = Date(timeIntervalSince1970: 0)
    func s(_ up: Bool, _ t: TimeInterval, awake: Bool = true, configured: Bool = true) -> Bool {
        g.step(wifiUp: up, holding: true, fullyAwake: awake, configured: configured, now: t0.addingTimeInterval(t))
    }
    #expect(!s(false, 0)); #expect(s(false, 5))
    #expect(!s(true, 6))
    // a new outage: the 5 s wait and the first delay start over
    #expect(!s(false, 100)); #expect(!s(false, 104)); #expect(s(false, 105))
    // not configured: never, and no attempt is counted
    #expect(!s(false, 200, configured: false)); #expect(!s(false, 300, configured: false))
    // ...so the outage, which has gone on since 100, doesn't fire the moment it's configured again
    #expect(!s(false, 301)); #expect(!s(false, 305)); #expect(s(false, 306))
    #expect(!s(false, 310)); #expect(s(false, 316))   // the delay after one attempt is 10 s
    // a dark wake in the middle of an outage doesn't count as time down
    #expect(!s(true, 400)); #expect(!s(false, 410)); #expect(!s(false, 413, awake: false)); #expect(!s(false, 416))
    #expect(!s(false, 420)); #expect(s(false, 421))
}

@Test func hotspotGateWifiPoweredOff() {
    var g = HotspotJoinGate(); let t0 = Date(timeIntervalSince1970: 0)
    func s(_ t: TimeInterval, on: Bool = true) -> Bool {
        g.step(wifiUp: false, holding: true, fullyAwake: true, configured: true, wifiOn: on, now: t0.addingTimeInterval(t))
    }
    #expect(!s(0)); #expect(s(5))
    // switched off: never, no attempt counted, and the wait starts over once it's on again
    #expect(!s(20, on: false)); #expect(!s(100, on: false))
    #expect(!s(101)); #expect(!s(105)); #expect(s(106))
    #expect(!s(110)); #expect(s(116))   // 10 s after one attempt, not 20 s after two
}

@Test func hotspotGateOtherPathUp() {
    var g = HotspotJoinGate(); let t0 = Date(timeIntervalSince1970: 0)
    func s(_ t: TimeInterval, otherUp: Bool = false) -> Bool {
        g.step(wifiUp: false, holding: true, fullyAwake: true, configured: true, anyPathUp: otherUp, now: t0.addingTimeInterval(t))
    }
    #expect(!s(0)); #expect(!s(60, otherUp: true)); #expect(!s(600, otherUp: true))   // on Ethernet: never
    #expect(!s(601)); #expect(s(606))   // Ethernet unplugged: the wait starts then
}

@Test func hotspotGatePostWakeQuiet() {
    var g = HotspotJoinGate(); let t0 = Date(timeIntervalSince1970: 0)
    func s(_ t: TimeInterval, quiet: Bool) -> Bool {
        g.step(wifiUp: false, holding: true, fullyAwake: true, configured: true, afterWakeQuiet: quiet, now: t0.addingTimeInterval(t))
    }
    #expect(!s(0, quiet: false)); #expect(!s(6, quiet: false)); #expect(!s(59, quiet: false))
    #expect(!s(60, quiet: true)); #expect(!s(64, quiet: true)); #expect(s(65, quiet: true))   // 5 s down counted from the quiet's end
}
