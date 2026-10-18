import Testing
@testable import EphedrineCore

@Test func ownerOnlyModes() {
    #expect(tightenedMode(current: 0o755, isDirectory: true) == 0o700)
    #expect(tightenedMode(current: 0o700, isDirectory: true) == nil)
    #expect(tightenedMode(current: 0o644, isDirectory: false) == 0o600)
    #expect(tightenedMode(current: 0o600, isDirectory: false) == nil)
}
@Test func lidSimulationFile() {
    #expect(simulatedLid("closed\n") == true); #expect(simulatedLid("open") == false)
    #expect(simulatedLid(nil) == nil); #expect(simulatedLid("shut") == nil)
}
