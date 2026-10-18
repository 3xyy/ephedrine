import Testing
import Foundation
@testable import EphedrineCore

private func snap(_ f: (inout FeatureSnapshot) -> Void = { _ in }) -> FeatureSnapshot {
    var s = FeatureSnapshot(lidSetup: true, lidHolding: false, lidClosed: false, claudeWorking: false, claudeCanHoldLid: true,
                            foreignNoSleep: false,
                            lowPowerNeedsRerun: false, lowPowerOn: nil, lowPowerOnLidShut: true, lowPowerFloor: 40,
                            muteOnShut: true, keyboardOffOnShut: true, pauseAppsOnShut: true, dockerRule: false, keyboardLightWorks: true,
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

@Test func lidRowForeignNoSleep() {
    // pmset disablesleep set by someone else: it stays awake shut, with or without setup.
    #expect(isRow(.lid, "Stays awake when shut (set outside Ephedrine)", .warn) { $0.foreignNoSleep = true })
    #expect(isRow(.lid, "Stays awake when shut (set outside Ephedrine)", .warn) { $0.foreignNoSleep = true; $0.lidSetup = false })
    #expect(isRow(.lid, "Stays awake when shut (set outside Ephedrine)", .warn) { $0.foreignNoSleep = true; $0.lidClosed = true })
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

@Test func whenShutRowKeyboardRefused() {
    // This macOS refuses the keyboard light, so the row doesn't promise it.
    #expect(isRow(.whenShut, "Mutes, apps paused", .normal) { $0.keyboardLightWorks = false })
    #expect(isRow(.whenShut, "Nothing extra", .dim) { $0.keyboardLightWorks = false; $0.muteOnShut = false; $0.pauseAppsOnShut = false })
}

@Test func cmuxRow() {
    #expect(row(.cmux) { $0.cmux = .notInstalled } == nil)
    #expect(isRow(.cmux, "Not running", .dim) { $0.cmux = .notRunning })
    #expect(isRow(.cmux, "Add its password in Settings to connect", .dim) { $0.cmux = .noPassword })
    #expect(isRow(.cmux, "Password not accepted", .warn) { $0.cmux = .badPassword })
    #expect(isRow(.cmux, "Not connected", .warn) { $0.cmux = .failed })
    #expect(isRow(.cmux, "Set a password in cmux's Automation settings", .dim) { $0.cmux = .noPasswordInCmux })
    #expect(isRow(.cmux, "Not watched", .dim) { $0.cmux = .notWatched })
    #expect(isRow(.cmux, "Saved password can't be read", .warn) { $0.cmux = .unreadablePassword })
    #expect(isRow(.cmux, "Checking…", .dim) { $0.cmux = .checking })
    #expect(isRow(.cmux, "Connected, 5 panes", .ok) { $0.cmux = .connected(5) })
    #expect(isRow(.cmux, "Connected, 1 pane", .ok) { $0.cmux = .connected(1) })
    #expect(isRow(.cmux, "Watching 5 panes", .ok) { $0.cmux = .connected(5); $0.claudeWorking = true })
    #expect(isRow(.cmux, "Watching 1 pane", .ok) { $0.cmux = .connected(1); $0.claudeWorking = true })
    #expect(row(.cmux) { $0.cmux = .notRunning }?.label == "cmux")
}

@Test func hotspotRow() {
    #expect(isRow(.hotspot, "Not set up", .dim) { $0.hotspotPassword = .unreadable })
    #expect(isRow(.hotspot, "Password needs re-entering", .warn) { $0.hotspotSSID = "Pixel"; $0.hotspotPassword = .unreadable; $0.holding = true })
    #expect(isRow(.hotspot, "Add its password in Settings", .warn) { $0.hotspotSSID = "Pixel"; $0.hotspotPassword = .missing })
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
    #expect(FeatureRows.hint(snap { $0.lidSetup = false; $0.keepAwakeOn = false; $0.claudeCanHoldLid = false }) == nil)
    #expect(FeatureRows.hint(snap()) == "Start Claude Code and the lid can be shut without the Mac sleeping.")
    #expect(FeatureRows.hint(snap { $0.lidHolding = true }) == nil)
    #expect(FeatureRows.hint(snap { $0.claudeWorking = true }) == nil)
    // Shutting the lid wouldn't keep it awake (keep-awake or While Claude off, a battery or heat stop): no promise.
    #expect(FeatureRows.hint(snap { $0.claudeCanHoldLid = false }) == nil)
    #expect(FeatureRows.hint(snap { $0.claudeCanHoldLid = false; $0.lidSetup = false }) == "Set up lid-closed mode in Settings to keep Claude going with the lid shut.")
}

/// The inputs a quiet Mac on the charger gives, open lid, cool.
private func lidIn(_ f: (inout LidInputs) -> Void = { _ in }) -> LidInputs {
    var i = LidInputs(whileClaude: true, claudeBusy: false, lidClosed: false, onBattery: false,
                      batteryPercent: 80, batteryFloor: 20, hot: false, now: Date(timeIntervalSince1970: 1000))
    f(&i)
    return i
}

@Test func claudeCanHoldLidWhenAllIsOn() {
    #expect(claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: false, LidState(), lidIn()))
    #expect(claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: false, LidState(), lidIn { $0.onBattery = true; $0.batteryPercent = 60 }))
}

@Test func claudeCanHoldLidMasterOff() {
    #expect(!claudeCanHoldLid(enabled: false, batteryStopped: false, heatStopped: false, LidState(), lidIn()))
}

@Test func claudeCanHoldLidWhileClaudeOff() {
    #expect(!claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: false, LidState(), lidIn { $0.whileClaude = false }))
}

@Test func claudeCanHoldLidBatteryStop() {
    #expect(!claudeCanHoldLid(enabled: true, batteryStopped: true, heatStopped: false, LidState(), lidIn()))
    // The lid's own battery limits, now: at the floor, or on battery with "Only on the charger".
    #expect(!claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: false, LidState(), lidIn { $0.onBattery = true; $0.batteryPercent = 15 }))
    #expect(!claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: false, LidState(), lidIn { $0.onBattery = true; $0.batteryFloor = lidOnlyPluggedIn }))
}

@Test func claudeCanHoldLidHeatStop() {
    #expect(!claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: true, LidState(), lidIn()))
    #expect(!claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: false, LidState(), lidIn { $0.hot = true }))
}

@Test func claudeCanHoldLidTripped() {
    // A limit that tripped earlier holds until the lid opens.
    var s = LidState(); s.tripped = .hot
    #expect(!claudeCanHoldLid(enabled: true, batteryStopped: false, heatStopped: false, s, lidIn()))
}

private func cmuxState(installed: Bool = true, running: Bool = true, password: CmuxSavedPassword = .saved,
                       access: CmuxAccess? = nil, panes: Int = 2, watched: Bool = true) -> CmuxRowState {
    cmuxRowState(installed: installed, running: running, password: password, access: access, panes: panes, watched: watched)
}

@Test func cmuxRowStateMapping() {
    #expect(cmuxState(installed: false, access: .ok) == .notInstalled)
    #expect(cmuxState(running: false, access: .ok) == .notRunning)
    #expect(cmuxState(password: .unreadable(-25308), access: .ok) == .unreadablePassword)
    #expect(cmuxState(password: .none, access: .ok) == .noPassword)
    #expect(cmuxState(access: .ok) == .connected(2))
    #expect(cmuxState(access: .badPassword) == .badPassword)
    #expect(cmuxState(access: .denied) == .failed)
    #expect(cmuxState(access: .failed("socket off")) == .failed)
}

@Test func cmuxRowStateNoPasswordSetInCmux() {
    // A password is saved and sent, yet cmux asks for one: it has none set.
    #expect(cmuxState(access: .needsPassword) == .noPasswordInCmux)
    #expect(cmuxState(access: .needsPassword, watched: true) == .noPasswordInCmux)
}

@Test func cmuxRowStateNotWatched() {
    // No scan reads cmux (retries, limit waits and the Terminal busy check all off): no answer is coming.
    #expect(cmuxState(watched: true) == .checking)
    #expect(cmuxState(watched: false) == .notWatched)
    // A stale answer (say from Settings' own check) must not read as live when nothing watches.
    #expect(cmuxState(access: .ok, watched: false) == .notWatched)
    #expect(cmuxState(access: .badPassword, watched: false) == .notWatched)
    #expect(cmuxState(access: .needsPassword, watched: false) == .notWatched)
}
