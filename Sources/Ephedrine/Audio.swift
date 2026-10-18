import Foundation
import CoreAudio
import AudioToolbox
import EphedrineCore

// ───────────────────────────── Lid-shut mute ─────────────────────────────
//
// The hold mutes the default output and records how it was first, in
// muted-outputs.json, before muting. Undoing it goes through muteRestorePlan:
// a device the owner unmuted meanwhile is left alone, and one that's
// disconnected keeps its entry until it's back (evaluate retries). The file
// outlives a crash: the watchdog unmutes while it's non-empty, and the next
// launch restores from it.

let mutedOutputsPath = "\(home)/.claude/ephedrine/muted-outputs.json"

private func address(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func defaultOutputDevice() -> AudioObjectID? {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String   // CoreAudio hands over a +1 CFString
}

/// Every audio device's UID (inputs too: a UID names one device either way).
private func devicesByUID() -> [String: AudioObjectID] {
    var a = address(kAudioHardwarePropertyDevices)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [:] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [:] }
    var out: [String: AudioObjectID] = [:]
    for id in ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
        if let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) { out[uid] = id }
    }
    return out
}

private func settable(_ id: AudioObjectID, _ a: inout AudioObjectPropertyAddress) -> Bool {
    var can: DarwinBoolean = false
    return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &can) == noErr && can.boolValue
}

/// nil for a device with no volume control.
private func outputVolume(_ id: AudioObjectID) -> Float? {
    var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output: true)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var v = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

private func setOutputVolume(_ id: AudioObjectID, _ volume: Float) -> Bool {
    var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, output: true)
    guard settable(id, &a) else { return false }
    var v = Float32(volume)
    return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
}

/// nil when it can't be read (no mute control, or the device is going away).
private func outputMuted(_ id: AudioObjectID) -> Bool? {
    var a = address(kAudioDevicePropertyMute, output: true)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var v = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v != 0
}

private func canMute(_ id: AudioObjectID) -> Bool {
    var a = address(kAudioDevicePropertyMute, output: true)
    return settable(id, &a)
}

private func setOutputMuted(_ id: AudioObjectID, _ on: Bool) -> Bool {
    var a = address(kAudioDevicePropertyMute, output: true)
    var v = UInt32(on ? 1 : 0)
    return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
}

/// What muted-outputs.json holds; empty when it's missing or unreadable.
func savedOutputs() -> [SavedOutput] {
    guard let d = fm.contents(atPath: mutedOutputsPath) else { return [] }
    return (try? JSONDecoder().decode([SavedOutput].self, from: d)) ?? []
}

/// Write the list, or delete the file when it's empty. False if it couldn't be written.
@discardableResult
private func saveOutputs(_ list: [SavedOutput]) -> Bool {
    if list.isEmpty { try? fm.removeItem(atPath: mutedOutputsPath); return !fm.fileExists(atPath: mutedOutputsPath) }
    do {
        try JSONEncoder().encode(list).write(to: URL(fileURLWithPath: mutedOutputsPath), options: .atomic)
        return true
    } catch {
        logLine("couldn't write \(mutedOutputsPath): \(error.localizedDescription)")
        return false
    }
}

/// A non-empty muted-outputs.json: what the watchdog's `[ -s ]` sees.
func mutedOutputsPending() -> Bool {
    ((try? fm.attributesOfItem(atPath: mutedOutputsPath))?[.size] as? Int ?? 0) > 0
}

private func label(_ o: SavedOutput) -> String { o.name ?? o.uid }

/// Mute the default output, recording how it was first (a device saved
/// already keeps its first entry). Written down before muting: no record, no
/// mute. Returns what was recorded, or nil if nothing was muted.
func muteDefaultOutput() -> SavedOutput? {
    guard let id = defaultOutputDevice(), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else {
        logLine("lid shut: couldn't find the sound output, left it alone")
        return nil
    }
    let name = stringProperty(id, kAudioObjectPropertyName)
    // A device we can't mute, or whose mute can't be read, would sit in the
    // file forever waiting to be undone.
    guard canMute(id), let muted = outputMuted(id) else {
        logLine("lid shut: \(name ?? uid) has no mute control, left its sound alone")
        return nil
    }
    let before = savedOutputs()
    let o = SavedOutput(uid: uid, name: name, volume: outputVolume(id) ?? -1, muted: muted)
    guard saveOutputs(addingOutput(o, to: before)) else {
        logLine("lid shut: couldn't record the sound settings, left \(name ?? uid) unmuted")
        return nil
    }
    guard setOutputMuted(id, true) else {
        saveOutputs(before)   // only a new entry goes; an older one still holds the owner's settings
        logLine("lid shut: couldn't mute \(name ?? uid)")
        return nil
    }
    return before.first { $0.uid == uid } ?? o
}

/// Saved outputs that weren't connected, logged once each until they're back.
private var waitLogged = Set<String>()
/// Restores that failed, logged once each.
private var failLogged = Set<String>()

/// Undo the mute for each saved output muteRestorePlan says to: put back its
/// volume, then its mute. One the owner unmuted is dropped; one that isn't
/// connected stays saved. Written after every change.
func restoreOutputs() {
    var saved = savedOutputs()
    guard !saved.isEmpty else { saveOutputs([]); return }
    let devices = devicesByUID()
    let plan = muteRestorePlan(saved: saved, connected: Set(devices.keys), mutedNow: { devices[$0].flatMap(outputMuted) })
    for step in plan {
        switch step {
        case .restore(let o):
            guard let id = devices[o.uid] else { continue }
            if o.volume >= 0 { _ = setOutputVolume(id, o.volume) }
            guard setOutputMuted(id, o.muted) else {
                if failLogged.insert(o.uid).inserted { logLine("couldn't unmute \(label(o)), trying again later") }
                continue
            }
            saved.removeAll { $0.uid == o.uid }
            saveOutputs(saved)
            waitLogged.remove(o.uid); failLogged.remove(o.uid)
            logLine(o.muted ? "\(label(o)) was muted before the lid shut, left it muted" : "unmuted \(label(o))")
        case .drop(let o):
            saved.removeAll { $0.uid == o.uid }
            saveOutputs(saved)
            waitLogged.remove(o.uid); failLogged.remove(o.uid)
            logLine("\(label(o)) was unmuted by hand, left it as it is")
        case .wait(let o):
            if waitLogged.insert(o.uid).inserted { logLine("\(label(o)) isn't connected or can't be read, unmuting it once it's back") }
        }
    }
}
