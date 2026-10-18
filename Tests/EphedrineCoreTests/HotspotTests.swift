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
    // a dark wake in the middle of an outage doesn't count as time down
    #expect(!s(true, 400)); #expect(!s(false, 410)); #expect(!s(false, 413, awake: false)); #expect(!s(false, 416))
    #expect(!s(false, 420)); #expect(s(false, 421))
}
