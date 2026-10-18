import Foundation
import Testing
@testable import EphedrineCore

let speakers = SavedOutput(uid: "BuiltIn", name: "MacBook Speakers", volume: 0.5, muted: false)
let buds = SavedOutput(uid: "AirPods", name: "AirPods", volume: 0.3, muted: false)
@Test func muteRestoreSkipsUserUnmuted() {
    #expect(muteRestorePlan(saved: [speakers], connected: ["BuiltIn"], mutedNow: { _ in false }) == [.drop(speakers)])
    #expect(muteRestorePlan(saved: [speakers], connected: ["BuiltIn"], mutedNow: { _ in true }) == [.restore(speakers)])
}
@Test func muteRestoreKeepsDisconnected() {
    #expect(muteRestorePlan(saved: [speakers, buds], connected: ["BuiltIn"], mutedNow: { _ in true })
            == [.restore(speakers), .wait(buds)])
    #expect(muteRestorePlan(saved: [speakers], connected: ["BuiltIn"], mutedNow: { _ in nil }) == [.wait(speakers)])
}
@Test func oneEntryPerDevice() {
    let again = SavedOutput(uid: "BuiltIn", name: "MacBook Speakers", volume: 0, muted: true)
    #expect(addingOutput(again, to: [speakers]) == [speakers])
    #expect(addingOutput(buds, to: [speakers]) == [speakers, buds])
}
@Test func keyboardGuard() {
    let good: (String) -> String? = { n in keyboardClientEncodings[n].map { e in e.replacingOccurrences(of: "@:", with: "24@0:8") } }
    #expect(keyboardClientRefusal(encodingFor: good) == nil)
    #expect(keyboardClientRefusal(encodingFor: { $0 == "setBrightness:forKeyboard:" ? nil : good($0) })?.contains("no setBrightness:forKeyboard:") == true)
    #expect(keyboardClientRefusal(encodingFor: { $0 == "brightnessForKeyboard:" ? "d24@0:8Q16" : good($0) }) != nil)
    #expect(keyboardClientRefusal(encodingFor: { $0.hasPrefix("isBacklight") ? nil : good($0) }) == nil)   // optional ones may be missing
}
@Test func dockerProbe() {
    #expect(dockerIdle(psOutput: "\n"))
    #expect(!dockerIdle(psOutput: "3f2a1b\n"))
    #expect(dockerProbeArguments(socket: "/Users/x/.docker/run/docker.sock") == ["--host", "unix:///Users/x/.docker/run/docker.sock", "ps", "-q"])
}
// The encodings this Mac's CoreBrightness reports (macOS 27.0, read with
// class_getInstanceMethod/method_getTypeEncoding), offsets and all.
@Test func keyboardGuardTakesRealEncodings() {
    let measured = ["copyKeyboardBacklightIDs": "@16@0:8", "isKeyboardBuiltIn:": "B24@0:8Q16",
                    "brightnessForKeyboard:": "f24@0:8Q16", "setBrightness:forKeyboard:": "B28@0:8f16Q20",
                    "isBacklightSuppressedOnKeyboard:": "B24@0:8Q16", "isBacklightDimmedOnKeyboard:": "B24@0:8Q16"]
    #expect(keyboardClientRefusal(encodingFor: { measured[$0] }) == nil)
    #expect(keyboardRequiredSelectors == ["copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:", "setBrightness:forKeyboard:"])
    // A changed optional method is refused too: the class isn't the one measured.
    #expect(keyboardClientRefusal(encodingFor: { $0 == "isBacklightDimmedOnKeyboard:" ? "c24@0:8Q16" : measured[$0] })
            == "KeyboardBrightnessClient's isBacklightDimmedOnKeyboard: has type encoding c@:Q, expected B@:Q")
    #expect(keyboardClientRefusal(encodingFor: { $0 == "copyKeyboardBacklightIDs" ? nil : measured[$0] })
            == "KeyboardBrightnessClient has no copyKeyboardBacklightIDs")
}
@Test func dockerIdleNeedsEmptyOutput() {
    #expect(dockerIdle(psOutput: ""))
    #expect(dockerIdle(psOutput: "  \n\t\n"))
    #expect(!dockerIdle(psOutput: "\n3f2a1b\n9c0d\n"))
}
// muted-outputs.json outlives the build that wrote it (a crash, then an upgrade).
@Test func savedOutputFileFormat() throws {
    let file = #"[{"uid":"BuiltIn","name":"MacBook Speakers","volume":0.5,"muted":false},{"uid":"HDMI","volume":-1,"muted":true}]"#
    let read = try JSONDecoder().decode([SavedOutput].self, from: Data(file.utf8))
    #expect(read.count == 2 && read[0] == speakers)
    #expect(read[1].uid == "HDMI" && read[1].name == nil && read[1].volume == -1 && read[1].muted)
    #expect(read[1] == SavedOutput(uid: "HDMI", name: nil, volume: -1, muted: true))   // what Audio.swift builds
    #expect(try JSONDecoder().decode([SavedOutput].self, from: JSONEncoder().encode(read)) == read)
}
@Test func lidExtrasSettings() {
    let name = "ephedrine-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    let s = AppSettings(defaults: d)
    #expect(s.lidMute && s.lidKeyboardOff && !s.lidDockerRule)
    s.lidMute = false; s.lidKeyboardOff = false; s.lidDockerRule = true
    #expect(d.object(forKey: "lidMute") as? Bool == false && d.object(forKey: "lidKeyboardOff") as? Bool == false
            && d.object(forKey: "lidDockerRule") as? Bool == true)
    let again = AppSettings(defaults: d)
    #expect(!again.lidMute && !again.lidKeyboardOff && again.lidDockerRule)
}
// Docker Desktop (200) with a helper (201); Claude Code (300) under a shell (299).
private let dockerTree = [ProcEntry(pid: 1, ppid: 0, start: 0), ProcEntry(pid: 200, ppid: 1, start: 1), ProcEntry(pid: 201, ppid: 200, start: 2),
                          ProcEntry(pid: 299, ppid: 1, start: 3), ProcEntry(pid: 300, ppid: 299, start: 4)]
@Test func dockerKeptForClaude() {
    #expect(claudeUsesDocker(dockerPIDs: [200, 201], procs: dockerTree, claudePIDs: [300]) == nil)
    // Claude Code running a docker command: the CLI lives in Docker.app, Claude is above it.
    let cli = dockerTree + [ProcEntry(pid: 301, ppid: 300, start: 5)]
    #expect(claudeUsesDocker(dockerPIDs: [200, 201, 301], procs: cli, claudePIDs: [300]) == "Claude Code is running docker")
    // Through a shell: Claude Code → sh -c → docker.
    let viaShell = dockerTree + [ProcEntry(pid: 303, ppid: 300, start: 5), ProcEntry(pid: 304, ppid: 303, start: 6)]
    #expect(claudeUsesDocker(dockerPIDs: [200, 201, 304], procs: viaShell, claudePIDs: [300]) == "Claude Code is running docker")
    // Claude Code started inside a container shell Docker spawned: Claude is below it.
    let under = dockerTree + [ProcEntry(pid: 302, ppid: 201, start: 6)]
    #expect(claudeUsesDocker(dockerPIDs: [200, 201], procs: under, claudePIDs: [302]) == "Claude Code runs under it")
    // A parent loop in a garbled table doesn't hang.
    let loop = [ProcEntry(pid: 200, ppid: 201, start: 1), ProcEntry(pid: 201, ppid: 200, start: 2)]
    #expect(claudeUsesDocker(dockerPIDs: [200, 201], procs: loop, claudePIDs: [300]) == nil)
}

// ── Review round 1 (R36, R37, unreadable files) ──

// R36: an output the owner muted is neither recorded nor touched; an entry a
// crash left for a device still muted is kept as the owner's.
@Test func muteStartLeavesOwnerMuted() {
    let mutedNow = SavedOutput(uid: "BuiltIn", name: "MacBook Speakers", volume: 0.5, muted: true)
    #expect(muteStartPlan(saved: [], current: mutedNow) == .leave)
    #expect(muteStartPlan(saved: [buds], current: mutedNow) == .leave)
    #expect(muteStartPlan(saved: [], current: speakers) == .mute([speakers]))
    #expect(muteStartPlan(saved: [buds], current: speakers) == .mute([buds, speakers]))
}
@Test func muteStartKeepsCrashEntry() {
    let ours = SavedOutput(uid: "BuiltIn", name: "MacBook Speakers", volume: 0, muted: true)   // muted by a hold a crash cut short
    #expect(muteStartPlan(saved: [speakers, buds], current: ours) == .mute([speakers, buds]))
    // The entry says the owner had it muted: still theirs, nothing to hold.
    let ownersMuted = SavedOutput(uid: "BuiltIn", name: "MacBook Speakers", volume: 0.5, muted: true)
    #expect(muteStartPlan(saved: [ownersMuted], current: ours) == .leave)
    // Unmuted since (by hand, or by the watchdog): the old entry is out of date.
    let fresh = SavedOutput(uid: "BuiltIn", name: "MacBook Speakers", volume: 0.7, muted: false)
    #expect(muteStartPlan(saved: [buds, ownersMuted], current: fresh) == .mute([buds, fresh]))
    #expect(muteStartPlan(saved: [speakers, buds], current: fresh) == .mute([buds, fresh]))
}

// R37: put a saved level back only on a keyboard that still reads off.
@Test func backlightRestoreOnlyWhereStillOff() {
    let off = backlightRestorePlan(saved: [1: 0.5], listed: [1], builtIn: 1, levelNow: { _ in 0 })
    #expect(off.restore == [1: 0.5] && off.drop.isEmpty && off.keep.isEmpty)
    let setByHand = backlightRestorePlan(saved: [1: 0.5], listed: [1], builtIn: 1, levelNow: { _ in 0.0625 })   // the lowest step
    #expect(setByHand.restore.isEmpty && setByHand.drop == [1] && setByHand.keep.isEmpty)
}
@Test func backlightRestoreKeepsUnreadable() {
    let unreadable = backlightRestorePlan(saved: [1: 0.5], listed: [1], builtIn: 1, levelNow: { _ in nil })
    #expect(unreadable.restore.isEmpty && unreadable.drop.isEmpty && unreadable.keep == [1: 0.5])
    let negative = backlightRestorePlan(saved: [1: 0.5], listed: [1], builtIn: 1, levelNow: { _ in -1 })
    #expect(negative.keep == [1: 0.5] && negative.restore.isEmpty)
    // No keyboard listed at all (the client answered nothing): keep for later.
    let none = backlightRestorePlan(saved: [7: 0.4], listed: [], builtIn: nil, levelNow: { _ in 0 })
    #expect(none.keep == [7: 0.4] && none.restore.isEmpty && none.drop.isEmpty)
}
@Test func backlightRestoreMapsToBuiltIn() {
    // The id changed (a restart can renumber it): the level goes to today's built-in keyboard.
    let moved = backlightRestorePlan(saved: [7: 0.4], listed: [1], builtIn: 1, levelNow: { $0 == 1 ? 0 : nil })
    #expect(moved.restore == [1: 0.4] && moved.drop.isEmpty && moved.keep.isEmpty)
    // An entry under the keyboard's own id wins over one mapped onto it.
    let both = backlightRestorePlan(saved: [1: 0.5, 7: 0.4], listed: [1], builtIn: 1, levelNow: { _ in 0 })
    #expect(both.restore == [1: 0.5] && both.drop == [7] && both.keep.isEmpty)
}

// Unreadable state files are never taken for empty ones (they'd be overwritten or deleted).
@Test func stateFilesUnreadableIsNotEmpty() {
    #expect(decodeSavedOutputs(nil) == [])
    #expect(decodeSavedOutputs(Data()) == [])
    #expect(decodeSavedOutputs(Data("{\"uid\":".utf8)) == nil)
    #expect(decodeSavedOutputs(try! JSONEncoder().encode([speakers])) == [speakers])
    #expect(decodeBacklightLevels(nil) == [:])
    #expect(decodeBacklightLevels(Data()) == [:])
    #expect(decodeBacklightLevels(Data("[1,0.5]".utf8)) == nil)
    #expect(decodeBacklightLevels(Data("{\"kbd\":0.5}".utf8)) == nil)
    #expect(decodeBacklightLevels(Data("{\"95158272\":0.5}".utf8)) == [95158272: 0.5])
    #expect(decodeBacklightLevels(encodeBacklightLevels([95158272: 0.25, 3: 1])) == [95158272: 0.25, 3: 1])
}
