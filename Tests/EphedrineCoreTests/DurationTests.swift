import Testing
import Foundation
@testable import EphedrineCore

@Test func durationParses() {
    #expect(parseDuration(days: "", hours: "1", minutes: "30") == 5400)
    #expect(parseDuration(days: "2", hours: "", minutes: "") == 172800)
    #expect(parseDuration(days: "30", hours: "", minutes: "") == 2592000)
}
@Test func durationRejects() {
    #expect(parseDuration(days: "", hours: "", minutes: "") == nil)
    #expect(parseDuration(days: "0", hours: "0", minutes: "0") == nil)
    #expect(parseDuration(days: "", hours: "1h", minutes: "") == nil)
    #expect(parseDuration(days: "30", hours: "0", minutes: "1") == nil)
    #expect(parseDuration(days: "1000", hours: "", minutes: "") == nil)
    #expect(parseDuration(days: "", hours: "", minutes: "1000") == nil)
}
@Test func addTimeClampsToMax() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(extendedUntil(now.addingTimeInterval(3600), by: 1800, now: now) == now.addingTimeInterval(5400))
    #expect(extendedUntil(now.addingTimeInterval(maxStayAwake - 60), by: 3600, now: now) == now.addingTimeInterval(maxStayAwake))
}
@Test func remainingFormat() {
    #expect(fmtRemaining(245) == "4:05")
    #expect(fmtRemaining(5400) == "1:30:00")
    #expect(fmtRemaining(86400 * 2 + 3 * 3600 + 59) == "2d 3h")
    #expect(fmtRemaining(-3) == "0s")
}
