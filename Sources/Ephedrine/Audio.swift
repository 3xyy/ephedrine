import Foundation
import CoreAudio
import AudioToolbox
import EphedrineCore

// ───────────────────────────── Lid-shut mute ─────────────────────────────
//
// The hold mutes the default output and records how it was first, in
// muted-outputs.json, before muting; an output its owner muted is left out
// (muteStartPlan). Undoing it goes through muteRestorePlan: a device the owner
// unmuted meanwhile is left alone, and one that's disconnected keeps its entry
// until it's back (the launch restore and evaluate's retry). The `muting`
// marker arms the watchdog's blind unmute only while the device the hold muted
// is still muted by it: from just before the mute until that device's entry is
// undone, the hold ends, or Ephedrine quits.

let mutedOutputsPath = "\(home)/.claude/ephedrine/muted-outputs.json"
let mutingMarkerPath = "\(home)/.claude/ephedrine/muting"   // holds the UID of the output the hold muted

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

private var unreadableLogged = false

/// What muted-outputs.json holds: empty when there's none, nil (logged once)
/// when it's there but can't be read. An unreadable file is left as it is,
/// never overwritten or deleted.
private func readSavedOutputs() -> [SavedOutput]? {
    guard let list = decodeSavedOutputs(fm.contents(atPath: mutedOutputsPath)) else {
        if !unreadableLogged { unreadableLogged = true; logLine("\(mutedOutputsPath) can't be read, leaving it as it is") }
        return nil
    }
    unreadableLogged = false
    return list
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

/// A non-empty muted-outputs.json: something is left to undo (now or once a device is back).
func mutedOutputsPending() -> Bool {
    ((try? fm.attributesOfItem(atPath: mutedOutputsPath))?[.size] as? Int ?? 0) > 0
}

/// The hold muted the default output and it's still ours to unmute: the
/// watchdog runs its unmute only while this is so, and the card says "muted".
func muteWatchdogArmed() -> Bool { fm.fileExists(atPath: mutingMarkerPath) }

/// The output the marker is for, nil when there's no (readable) marker.
private func mutingUID() -> String? {
    fm.contents(atPath: mutingMarkerPath).map { String(decoding: $0, as: UTF8.self) }
}

/// Stop the watchdog's unmute from firing: what's left, if anything, is for
/// the launch restore and evaluate's retry.
func disarmMuteWatchdog() { try? fm.removeItem(atPath: mutingMarkerPath) }

private func label(_ o: SavedOutput) -> String { o.name ?? o.uid }

/// Mute the default output, recording how it was first (muteStartPlan: one
/// its owner muted is left alone; an entry a crash left for it is kept).
/// Written down, and the watchdog's unmute armed, before muting: no record,
/// no mute. Returns the saved entry, or nil if nothing was muted.
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
    guard let before = readSavedOutputs() else {
        logLine("lid shut: left \(name ?? uid) unmuted (nowhere to record it)")
        return nil
    }
    let current = SavedOutput(uid: uid, name: name, volume: outputVolume(id) ?? -1, muted: muted)
    guard case .mute(let list) = muteStartPlan(saved: before, current: current) else {
        logLine("\(name ?? uid) was already muted, leaving it alone")
        return nil
    }
    guard saveOutputs(list) else {
        logLine("lid shut: couldn't record the sound settings, left \(name ?? uid) unmuted")
        return nil
    }
    guard fm.createFile(atPath: mutingMarkerPath, contents: Data(uid.utf8)) else {
        saveOutputs(before)
        logLine("lid shut: couldn't write \(mutingMarkerPath), left \(name ?? uid) unmuted")
        return nil
    }
    guard setOutputMuted(id, true) else {
        saveOutputs(before)   // as it was: a new entry goes, an older one stays the owner's
        disarmMuteWatchdog()
        logLine("lid shut: couldn't mute \(name ?? uid)")
        return nil
    }
    return list.first { $0.uid == uid }
}

/// Saved outputs that weren't connected, logged once each until they're back.
private var waitLogged = Set<String>()
/// Restores that failed, logged once each.
private var failLogged = Set<String>()

/// Undo the mute for each saved output muteRestorePlan says to: put back its
/// volume, then its mute. One the owner unmuted is dropped; one that isn't
/// connected stays saved. Written after every change. The watchdog's unmute
/// is disarmed once its device's entry is undone, or while that device is
/// gone (its unmute would land on another one).
func restoreOutputs() {
    guard var saved = readSavedOutputs() else { return }
    guard !saved.isEmpty else { saveOutputs([]); return }
    let armedFor = mutingUID()
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
            if o.uid == armedFor { disarmMuteWatchdog() }
            waitLogged.remove(o.uid); failLogged.remove(o.uid)
            logLine(o.muted ? "\(label(o)) was muted before the lid shut, left it muted" : "unmuted \(label(o))")
        case .drop(let o):
            saved.removeAll { $0.uid == o.uid }
            saveOutputs(saved)
            if o.uid == armedFor { disarmMuteWatchdog() }
            waitLogged.remove(o.uid); failLogged.remove(o.uid)
            logLine("\(label(o)) was unmuted by hand, left it as it is")
        case .wait(let o):
            if o.uid == armedFor && devices[o.uid] == nil { disarmMuteWatchdog() }
            if waitLogged.insert(o.uid).inserted { logLine("\(label(o)) isn't connected or can't be read, unmuting it once it's back") }
        }
    }
}
