import Testing
import Foundation
@testable import EphedrineCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// ── "continue" and the network ──

@Test func noContinueWhileTheNetworkIsDown() {
    // A "continue" with no network fails again after Claude Code's own retries
    // and uses up one of the tries for nothing.
    #expect(!continueDue(nextTryAt: at(30), startedAt: at(0), lastTryAt: nil,
                         networkDown: true, networkBackAt: nil, now: at(600)))
}

@Test func continueRightAfterTheNetworkComesBack() {
    // 2026-10-22: Wi-Fi down 08:09, the error at 08:17:47, back at 08:30:25.
    // The backoff's next slot could be 5 minutes off; go once it has settled.
    let back = at(760)
    #expect(!continueDue(nextTryAt: at(900), startedAt: at(0), lastTryAt: nil,
                         networkDown: false, networkBackAt: back, now: back.addingTimeInterval(continueAfterNetworkBack - 1)))
    #expect(continueDue(nextTryAt: at(900), startedAt: at(0), lastTryAt: nil,
                        networkDown: false, networkBackAt: back, now: back.addingTimeInterval(continueAfterNetworkBack)))
    // Even a slot that's already due waits for the network to settle.
    #expect(!continueDue(nextTryAt: at(30), startedAt: at(0), lastTryAt: nil,
                         networkDown: false, networkBackAt: back, now: back.addingTimeInterval(2)))
}

@Test func theShortcutIsOncePerOutage() {
    let back = at(760)
    // Tried after it came back: the backoff runs as usual from there.
    #expect(!continueDue(nextTryAt: at(1100), startedAt: at(0), lastTryAt: at(775),
                         networkDown: false, networkBackAt: back, now: at(800)))
    #expect(continueDue(nextTryAt: at(1100), startedAt: at(0), lastTryAt: at(775),
                        networkDown: false, networkBackAt: back, now: at(1100)))
    // An outage that ended before this error appeared has nothing to do with it.
    #expect(!continueDue(nextTryAt: at(1030), startedAt: at(1000), lastTryAt: nil,
                         networkDown: false, networkBackAt: back, now: at(1010)))
    #expect(continueDue(nextTryAt: at(1030), startedAt: at(1000), lastTryAt: nil,
                        networkDown: false, networkBackAt: back, now: at(1030)))
}

// ── The cmux password going unreadable ──

@Test func anUnreadableCmuxPasswordIsReportedOncePerEpisode() {
    // 2026-10-22: after a rebuild Ephedrine couldn't read it for 14 hours and only logged it.
    var n = UnreadableNotice()
    #expect(n.step(unreadable: true) == true)
    #expect(n.step(unreadable: true) == false)
    #expect(n.step(unreadable: false) == false)     // saved again
    #expect(n.step(unreadable: true) == true)       // the next rebuild or upgrade
}
