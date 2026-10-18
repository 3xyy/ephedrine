import Testing
import Foundation
@testable import EphedrineCore

@Test func lidRuleRerunDecision() {
    #expect(lidRuleNeedsRerun(setupInstalled: true, stamp: nil) == true)
    #expect(lidRuleNeedsRerun(setupInstalled: true, stamp: "1") == true)
    #expect(lidRuleNeedsRerun(setupInstalled: true, stamp: "2") == false)
    #expect(lidRuleNeedsRerun(setupInstalled: false, stamp: nil) == false)
    #expect(lidRuleNeedsRerun(setupInstalled: true, stamp: " 2\n") == false)
}

@Test func savedPasswordLines() {
    #expect(savedPasswordLine(.found) == "A password is saved")
    #expect(savedPasswordLine(.missing) == "No password saved")
    #expect(savedPasswordLine(.unreadable) == "A password is saved but Ephedrine can't read it. Enter it again.")
    #expect(passwordFieldPlaceholder(.found, empty: "Password") == "Saved (hidden). Type a new one to replace it")
    #expect(passwordFieldPlaceholder(.missing, empty: "Password") == "Password")
    #expect(passwordFieldPlaceholder(.unreadable, empty: "Password") == "Password")
}

@Test func savedLabelTimesOut() {
    let t = Date(timeIntervalSince1970: 1000)
    #expect(savedLabelVisible(savedAt: nil, now: t) == false)
    #expect(savedLabelVisible(savedAt: t, now: t.addingTimeInterval(3.9)) == true)
    #expect(savedLabelVisible(savedAt: t, now: t.addingTimeInterval(4)) == false)
}

@Test func savedLabelShowsThroughClockLag() {
    // Settings' clock ticks once a second, so right after Save its time can be
    // up to a tick before the save: the label shows at once anyway.
    let t = Date(timeIntervalSince1970: 1000)
    #expect(savedLabelVisible(savedAt: t, now: t) == true)
    #expect(savedLabelVisible(savedAt: t, now: t.addingTimeInterval(-0.9)) == true)
    #expect(savedLabelVisible(savedAt: t, now: t.addingTimeInterval(-1.4)) == true)
    #expect(savedLabelVisible(savedAt: t, now: t.addingTimeInterval(-2)) == false)
}
