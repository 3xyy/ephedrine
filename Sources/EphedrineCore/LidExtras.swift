import Foundation

// What the lid-shut hold does besides pausing apps: mute the sound, turn the
// keyboard light off, and (opt-in) pause an idle Docker Desktop. The rules
// for undoing each are pure, so they're unit-testable; CoreAudio,
// CoreBrightness and the docker CLI live in the app target.

// ── Mute ──

/// An output device as it was before the hold muted it. `volume` is -1 for a
/// device with no volume control (nothing to put back).
public struct SavedOutput: Codable, Equatable {
    public let uid: String
    public let name: String?
    public let volume: Float
    public let muted: Bool
    public init(uid: String, name: String?, volume: Float, muted: Bool) {
        self.uid = uid; self.name = name; self.volume = volume; self.muted = muted
    }
}

/// What to do with one saved output when the hold ends. `restore`: put its
/// volume and mute back. `drop`: forget it, the owner unmuted it by hand.
/// `wait`: keep it for later, it isn't connected or can't be read.
public enum MuteRestore: Equatable { case restore(SavedOutput), drop(SavedOutput), wait(SavedOutput) }

/// One step per saved output, in order. Only a device that's connected and
/// still muted is restored: one the owner unmuted meanwhile is left as they
/// set it, and one that's gone keeps its entry until it's back.
public func muteRestorePlan(saved: [SavedOutput], connected: Set<String>, mutedNow: (String) -> Bool?) -> [MuteRestore] {
    saved.map { o in
        guard connected.contains(o.uid) else { return .wait(o) }
        switch mutedNow(o.uid) {
        case true?:  return .restore(o)
        case false?: return .drop(o)
        case nil:    return .wait(o)
        }
    }
}

/// The saved list with `o` added, unless its device is saved already: the
/// first entry holds the owner's settings, a later one only ours.
public func addingOutput(_ o: SavedOutput, to saved: [SavedOutput]) -> [SavedOutput] {
    saved.contains { $0.uid == o.uid } ? saved : saved + [o]
}

// ── Keyboard light ──

/// The type encodings of private CoreBrightness `KeyboardBrightnessClient`
/// methods, offsets stripped, as Insomnia measured them on macOS 26.2.
public let keyboardClientEncodings: [String: String] = [
    "copyKeyboardBacklightIDs": "@@:",
    "isKeyboardBuiltIn:": "B@:Q",
    "brightnessForKeyboard:": "f@:Q",
    "setBrightness:forKeyboard:": "B@:fQ",
    "isBacklightSuppressedOnKeyboard:": "B@:Q",
    "isBacklightDimmedOnKeyboard:": "B@:Q",
]

/// The ones Ephedrine calls; the class is left alone without any of them.
public let keyboardRequiredSelectors: [String] = [
    "copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:", "setBrightness:forKeyboard:",
]

/// Checked when present, so a class that changed shape is refused.
let keyboardOptionalSelectors = ["isBacklightSuppressedOnKeyboard:", "isBacklightDimmedOnKeyboard:"]

/// Why the class can't be called safely, or nil when it can. `encodingFor`
/// gives a method's type encoding (nil when the class lacks it). Digits are
/// stack offsets and sizes, which differ by architecture, so they're dropped
/// before comparing. A call through a mismatched signature reads garbage or
/// crashes, so any difference refuses.
public func keyboardClientRefusal(encodingFor: (String) -> String?) -> String? {
    for selector in keyboardRequiredSelectors + keyboardOptionalSelectors {
        guard let want = keyboardClientEncodings[selector] else { continue }
        guard let raw = encodingFor(selector) else {
            if keyboardRequiredSelectors.contains(selector) { return "KeyboardBrightnessClient has no \(selector)" }
            continue
        }
        let found = raw.filter { !("0"..."9").contains($0) }
        if found != want { return "KeyboardBrightnessClient's \(selector) has type encoding \(found), expected \(want)" }
    }
    return nil
}

// ── Docker ──

/// `docker ps -q` printed no container ids: nothing is running.
public func dockerIdle(psOutput: String) -> Bool {
    psOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Why Docker must keep running for Claude Code, or nil: Claude Code runs
/// under one of Docker's processes (`dockerPIDs`), or one of them runs under
/// Claude Code (the docker CLI lives in Docker.app, so a `docker build`
/// Claude started shows up as Docker's, while `ps -q` lists no container).
public func claudeUsesDocker(dockerPIDs: [Int32], procs: [ProcEntry], claudePIDs: Set<Int32>) -> String? {
    if descendants(of: dockerPIDs, in: procs).contains(where: { claudePIDs.contains($0.pid) }) { return "Claude Code runs under it" }
    var parent: [Int32: Int32] = [:]
    for p in procs { parent[p.pid] = p.ppid }
    for pid in dockerPIDs {
        var seen: Set<Int32> = [pid]
        var up = parent[pid]
        while let p = up, p > 1, seen.insert(p).inserted {
            if claudePIDs.contains(p) { return "Claude Code is running docker" }
            up = parent[p]
        }
    }
    return nil
}

/// The probe's arguments: Docker Desktop's own socket, named explicitly so a
/// DOCKER_HOST or context pointing elsewhere can't answer for it.
public func dockerProbeArguments(socket: String) -> [String] {
    ["--host", "unix://" + socket, "ps", "-q"]
}
