import Testing
import Foundation
@testable import EphedrineCore

private func snap(_ f: (inout FeatureSnapshot) -> Void = { _ in }) -> FeatureSnapshot {
    var s = FeatureSnapshot(lidSetup: true, lidHolding: false, lidClosed: false, claudeWorking: false, stayAwake: false,
                            lowPowerNeedsRerun: false, lowPowerOn: nil, lowPowerOnLidShut: true, lowPowerFloor: 40,
                            muteOnShut: true, keyboardOffOnShut: true, pauseAppsOnShut: true, dockerRule: false,
                            cmux: .notInstalled, hotspotSSID: "", hotspotPassword: .ok, holding: false,
                            networkUp: true, downFor: nil, lastGap: nil, tmuxTargets: 0)
    f(&s)
    return s
}
private func row(_ k: FeatureKind, _ f: (inout FeatureSnapshot) -> Void = { _ in }) -> FeatureRow? {
    FeatureRows.rows(snap(f)).first { $0.kind == k }
}
private func isRow(_ k: FeatureKind, _ text: String, _ tone: RowTone, _ f: (inout FeatureSnapshot) -> Void = { _ in }) -> Bool {
    row(k, f)?.text == text && row(k, f)?.tone == tone
}

@Test func lidRow() {
    #expect(isRow(.lid, "Sleeps when shut", .dim) { $0.lidSetup = false; $0.lidClosed = true; $0.lidHolding = true })
    #expect(isRow(.lid, "Shut, on an external display", .normal) { $0.lidClosed = true; $0.lidHolding = true })
    #expect(isRow(.lid, "Shut it, Claude keeps going", .active) { $0.lidHolding = true; $0.claudeWorking = true })
    #expect(isRow(.lid, "Shut it, stays awake", .active) { $0.lidHolding = true })
    #expect(isRow(.lid, "Sleeps if you shut it now", .normal))
    #expect(row(.lid)?.label == "Lid")
}

@Test func lowPowerRow() {
    #expect(row(.lowPower) { $0.lidSetup = false } == nil)
    #expect(isRow(.lowPower, "Needs lid setup re-run", .warn) { $0.lowPowerNeedsRerun = true; $0.lowPowerOn = .lid })
    #expect(isRow(.lowPower, "On while the lid is shut", .active) { $0.lowPowerOn = .lid })
    #expect(isRow(.lowPower, "On, battery under 25%", .active) { $0.lowPowerOn = .battery; $0.lowPowerFloor = 25 })
    #expect(isRow(.lowPower, "On, the Mac is hot", .active) { $0.lowPowerOn = .heat })
    #expect(isRow(.lowPower, "On with the lid shut, or below 40%", .normal))
    #expect(isRow(.lowPower, "Comes on when the lid shuts", .normal) { $0.lowPowerFloor = 0 })
    #expect(isRow(.lowPower, "Comes on below 30% on battery", .normal) { $0.lowPowerOnLidShut = false; $0.lowPowerFloor = 30 })
    #expect(isRow(.lowPower, "Off", .dim) { $0.lowPowerOnLidShut = false; $0.lowPowerFloor = 0 })
    #expect(row(.lowPower)?.label == "Low Power")
}

@Test func whenShutRow() {
    #expect(row(.whenShut) { $0.lidSetup = false } == nil)
    #expect(isRow(.whenShut, "Mutes, keys dark, apps paused", .normal))
    #expect(isRow(.whenShut, "Keys dark, apps and Docker paused", .normal) { $0.muteOnShut = false; $0.dockerRule = true })
    #expect(isRow(.whenShut, "Docker paused", .normal) { $0.muteOnShut = false; $0.keyboardOffOnShut = false; $0.pauseAppsOnShut = false; $0.dockerRule = true })
    #expect(isRow(.whenShut, "Mutes", .normal) { $0.keyboardOffOnShut = false; $0.pauseAppsOnShut = false })
    #expect(isRow(.whenShut, "Nothing extra", .dim) { $0.muteOnShut = false; $0.keyboardOffOnShut = false; $0.pauseAppsOnShut = false })
    #expect(row(.whenShut)?.label == "When shut")
}

@Test func cmuxRow() {
    #expect(row(.cmux) { $0.cmux = .notInstalled } == nil)
    #expect(isRow(.cmux, "Not running", .dim) { $0.cmux = .notRunning })
    #expect(isRow(.cmux, "Add its password in Settings to connect", .dim) { $0.cmux = .noPassword })
    #expect(isRow(.cmux, "Password not accepted", .warn) { $0.cmux = .badPassword })
    #expect(isRow(.cmux, "Not connected", .dim) { $0.cmux = .failed })
    #expect(isRow(.cmux, "Connected, 5 panes", .ok) { $0.cmux = .connected(5) })
    #expect(isRow(.cmux, "Connected, 1 pane", .ok) { $0.cmux = .connected(1) })
    #expect(isRow(.cmux, "Watching 5 panes", .ok) { $0.cmux = .connected(5); $0.claudeWorking = true })
    #expect(isRow(.cmux, "Watching 1 pane", .ok) { $0.cmux = .connected(1); $0.claudeWorking = true })
    #expect(row(.cmux) { $0.cmux = .notRunning }?.label == "cmux")
}

@Test func hotspotRow() {
    #expect(isRow(.hotspot, "Not set up", .dim) { $0.hotspotPassword = .unreadable })
    #expect(isRow(.hotspot, "Password needs re-entering", .warn) { $0.hotspotSSID = "Pixel"; $0.hotspotPassword = .unreadable; $0.holding = true })
    #expect(isRow(.hotspot, "Add its password in Settings", .dim) { $0.hotspotSSID = "Pixel"; $0.hotspotPassword = .missing })
    #expect(isRow(.hotspot, "Joins Pixel if Wi-Fi drops", .active) { $0.hotspotSSID = "Pixel"; $0.holding = true })
    #expect(isRow(.hotspot, "Ready: Pixel", .normal) { $0.hotspotSSID = "Pixel" })
    #expect(row(.hotspot)?.label == "Hotspot")
}

@Test func networkRow() {
    #expect(isRow(.network, "Offline for 45s", .warn) { $0.networkUp = false; $0.downFor = 45 })
    #expect(isRow(.network, "Offline for 3m", .warn) { $0.networkUp = false; $0.downFor = 150; $0.lastGap = 9 })
    #expect(isRow(.network, "Online, last gap 12s", .normal) { $0.lastGap = 12 })
    #expect(isRow(.network, "Online", .normal))
    #expect(isRow(.network, "Online", .normal) { $0.lastGap = 0 })
    #expect(row(.network)?.label == "Network")
}

@Test func tmuxRow() {
    #expect(row(.tmux) == nil)
    #expect(isRow(.tmux, "Nudges 1 pane after outages", .normal) { $0.tmuxTargets = 1 })
    #expect(isRow(.tmux, "Nudges 3 panes after outages", .normal) { $0.tmuxTargets = 3 })
    #expect(row(.tmux) { $0.tmuxTargets = 1 }?.label == "tmux")
}

@Test func rowOrderAndOmissions() {
    let all = FeatureRows.rows(snap {
        $0.cmux = .connected(2); $0.hotspotSSID = "P"; $0.tmuxTargets = 2
    }).map(\.kind)
    #expect(all == [.lid, .lowPower, .whenShut, .cmux, .hotspot, .network, .tmux])
    let bare = FeatureRows.rows(snap { $0.lidSetup = false }).map(\.kind)
    #expect(bare == [.lid, .hotspot, .network])
}

@Test func hints() {
    #expect(FeatureRows.hint(snap { $0.lidSetup = false }) == "Set up lid-closed mode in Settings to keep Claude going with the lid shut.")
    #expect(FeatureRows.hint(snap()) == "Start Claude Code and the lid can be shut without the Mac sleeping.")
    #expect(FeatureRows.hint(snap { $0.lidHolding = true }) == nil)
    #expect(FeatureRows.hint(snap { $0.claudeWorking = true }) == nil)
}
