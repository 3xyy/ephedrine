import Testing
import Foundation
@testable import EphedrineCore

@Test func outageGap() {
    var t = OutageTracker(); let t0 = Date(timeIntervalSince1970: 0)
    #expect(t.step(satisfied: true, now: t0) == nil)
    #expect(t.step(satisfied: false, now: t0) == nil)
    #expect(t.step(satisfied: false, now: t0.addingTimeInterval(50)) == nil)
    #expect(t.step(satisfied: true, now: t0.addingTimeInterval(95)) == 95)
    #expect(t.lastGap == 95)
    #expect(t.step(satisfied: true, now: t0.addingTimeInterval(99)) == nil)
}
@Test func paneCheckSkips() {
    #expect(checkPane("%3 0 0 0\n") == .ready("%3"))
    #expect(checkPane("%3 1 0 0") == .skip("pane %3 is dead"))
    #expect(checkPane("%3 0 1 0") == .skip("pane %3 is in copy or choose mode"))
    #expect(checkPane("%3 0 0 1") == .skip("pane %3 has input turned off"))
    #expect(checkPane("") == .skip("no such pane"))
    #expect(checkPane("3 0 0 0") == .skip("pane id unreadable (3 0 0 0)"))
    #expect(checkPane("x12 0 0 0") == .skip("pane id unreadable (x12 0 0 0)"))
    #expect(checkPane("%a 0 0 0") == .skip("pane id unreadable (%a 0 0 0)"))
    #expect(checkPane("%3 0 0") == .skip("pane id unreadable (%3 0 0)"))
}
@Test func markMustBeExactlyOn() {
    #expect(paneMarked("on\n")); #expect(paneMarked("on"))
    #expect(!paneMarked("")); #expect(!paneMarked("off\n")); #expect(!paneMarked("on on\n"))
}
@Test func markCommandAndConstants() {
    #expect(tmuxMarkCommand("work:1.0") == "tmux set-option -p -t work:1.0 @ephedrine-nudge on")
    #expect(tmuxMarkOption == "@ephedrine-nudge")
    #expect(tmuxPaneStateFormat == "#{pane_id} #{pane_dead} #{pane_in_mode} #{pane_input_off}")
}
@Test func outageStartsDownAndFirstUpIsNoGap() {
    var t = OutageTracker(); let t0 = Date(timeIntervalSince1970: 0)
    #expect(t.step(satisfied: false, now: t0) == nil)       // launched offline: down from now
    #expect(t.downSince == t0)
    #expect(t.step(satisfied: true, now: t0.addingTimeInterval(10)) == 10)
    #expect(t.downSince == nil)
}

@Test func tmuxSettingsDefaultAndPersist() {
    let d = UserDefaults(suiteName: "tmux-\(UUID().uuidString)")!
    let s = AppSettings(defaults: d)
    #expect(s.tmuxTargets.isEmpty && !s.tmuxPressEnter && s.outageNudgeSeconds == 90)
    s.addTmuxTarget("  work:1.0 "); s.addTmuxTarget("work:1.0"); s.addTmuxTarget("   ")
    s.tmuxPressEnter = true
    #expect(s.tmuxTargets == ["work:1.0"])
    let again = AppSettings(defaults: d)
    #expect(again.tmuxTargets == ["work:1.0"] && again.tmuxPressEnter)
    s.tmuxTargets.removeAll()
    #expect(AppSettings(defaults: d).tmuxTargets.isEmpty)
}
