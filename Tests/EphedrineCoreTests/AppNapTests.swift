import Testing
import Foundation
@testable import EphedrineCore

@Test func appNapIds() {
    #expect(appNapRestorable("com.apple.Terminal")); #expect(!appNapRestorable("NSGlobalDomain"))
    #expect(!appNapRestorable("-com.x")); #expect(!appNapRestorable("/tmp/x")); #expect(!appNapRestorable("com.ü"))
}
@Test func appNapJournalPlan() {
    var j = AppNapJournal(prior: [:])
    let write = j.plan(current: ["a.b": nil, "c.d": true, "e.f": false, "NSGlobalDomain": nil])
    #expect(write == ["a.b", "e.f"])
    #expect(j.prior == ["a.b": .absent, "e.f": .value(false)])
    #expect(j.plan(current: ["a.b": true]) == [])          // already journaled: keep the first prior value
    #expect(j.restorePlan().map(\.0) == ["a.b", "e.f"])
}
@Test func appNapAgentList() {
    for id in ["com.apple.Terminal", "com.cmuxterm.app", "com.vscodium", "com.google.android.studio",
               "com.anthropic.claudefordesktop", "com.openai.codex", "com.conductor.app", "com.t3tools.t3code",
               "com.google.Chrome", "ai.perplexity.comet"] {
        #expect(appNapAgentApps.contains(id), "\(id)")
    }
    #expect(!appNapAgentApps.contains("com.1password.1password")); #expect(!appNapAgentApps.contains("us.zoom.xos"))
    #expect(Set(appNapAgentApps).count == appNapAgentApps.count)
    #expect(appNapAgentApps.allSatisfy(appNapRestorable))
}
@Test func appNapJournalRoundTrip() throws {
    let j = AppNapJournal(prior: ["a.b": .absent, "c.d": .value(true), "e.f": .value(false)])
    #expect(try JSONDecoder().decode(AppNapJournal.self, from: JSONEncoder().encode(j)) == j)
}
@Test func appNapPlanSkipsYesButRecordsLater() {
    var j = AppNapJournal(prior: ["a.b": .absent])
    #expect(j.plan(current: ["a.b": true, "x.y": nil]) == ["x.y"])    // a.b stays journaled, not rewritten
    #expect(j.prior == ["a.b": .absent, "x.y": .absent])
    #expect(j.plan(current: ["x.y": nil]) == ["x.y"])   // journaled but not YES (a write failed): try again, same prior
    #expect(j.prior["x.y"] == .absent)
    #expect(j.plan(current: ["x.y": true]) == [])
}
@Test func appNapRetryKeepsFirstPrior() {
    var j = AppNapJournal(prior: ["a.b": .value(false)])
    #expect(j.plan(current: ["a.b": nil]) == ["a.b"])
    #expect(j.prior["a.b"] == .value(false))
}
@Test func appNapRestoreSkipsUnsafeIds() {
    #expect(!appNapRestorable("kCFPreferencesAnyApplication"))
    let j = AppNapJournal(prior: ["NSGlobalDomain": .absent, "/tmp/x": .value(false), "kCFPreferencesAnyApplication": .absent,
                                  "com.old.app": .value(false), "a.b": .absent])
    #expect(j.restorePlan().map(\.0) == ["a.b", "com.old.app"])      // an id outside appNapAgentApps still restores
    #expect(j.unrestorable == ["NSGlobalDomain", "/tmp/x", "kCFPreferencesAnyApplication"].sorted())
}
@Test func appNapRestorePlanIsSortedWithValues() {
    let ids = (0..<30).map { "app.n\(String(format: "%02d", $0))" }
    let j = AppNapJournal(prior: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0 % 2 == 0 ? PriorValue.absent : .value($0 % 3 == 0)) }))
    #expect(j.restorePlan().map(\.0) == ids)
    #expect(j.restorePlan().map(\.1) == ids.indices.map { $0 % 2 == 0 ? PriorValue.absent : .value($0 % 3 == 0) })
}
