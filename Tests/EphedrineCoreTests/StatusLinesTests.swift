import Testing
@testable import EphedrineCore

@Test func chipsAll() {
    let c = StatusLines.chips(lid: .canClose, watts: -9.43, batteryPercent: 36, charging: false, wifi: "home")
    #expect(c.map(\.text) == ["Lid can close", "9.4 W", "36%", "home"])
    #expect(c.map(\.kind) == [.lid, .power, .battery(level: 25, charging: false), .wifi])
}
@Test func chipsOmitUnknown() {
    #expect(StatusLines.chips(lid: .none, watts: nil, batteryPercent: nil, charging: false, wifi: nil).isEmpty)
    #expect(StatusLines.chips(lid: .shut, watts: 0.01, batteryPercent: 82, charging: true, wifi: "on").map(\.text)
            == ["Lid shut", "82% charging", "Connected"])
    #expect(StatusLines.chips(lid: .none, watts: nil, batteryPercent: 100, charging: true, wifi: nil).map(\.text) == ["100%"])
}
@Test func heldLine() {
    #expect(StatusLines.held(paused: 0, dockerPaused: false, muted: false, lowPower: false, lastGap: nil) == nil)
    #expect(StatusLines.held(paused: 0, dockerPaused: false, muted: false, lowPower: false, lastGap: 0) == nil)
    #expect(StatusLines.held(paused: 1, dockerPaused: false, muted: false, lowPower: false, lastGap: nil) == "1 app paused")
    #expect(StatusLines.held(paused: 3, dockerPaused: true, muted: true, lowPower: true, lastGap: 11.6)
            == "3 apps paused · Docker paused · muted · Low Power Mode on · last network gap 12s")
}
@Test func batteryNoteText() { #expect(StatusLines.batteryNote(floor: 20) == "On battery, stops keeping it awake at 20%") }
@Test func wattsTwosComplement() {
    #expect(batteryWatts(amperage: -1000, voltage: 12000) == -12.0)
    #expect(batteryWatts(amperage: 4294966296, voltage: 12000) == -12.0)   // -1000 as UInt32
    #expect(batteryWatts(amperage: 500, voltage: 12000) == 6.0)
}
