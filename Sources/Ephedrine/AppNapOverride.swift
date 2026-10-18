import AppKit
import EphedrineCore

// ───────────────────────── App Nap off for agent apps ─────────────────────────
//
// With the setting on, NSAppSleepDisabled = YES goes into the preferences of the
// installed apps in appNapAgentApps. Each app's value from before (or "no key")
// is saved in app-nap.json first, and only the first value is kept, so turning
// the setting on again never records our own YES as the original. Turning it
// off writes every saved value back; an entry leaves the file only after its
// restore synchronized. A file that's there but can't be read is left alone:
// it is never treated as empty.

let appNapJournalPath = "\(home)/.claude/ephedrine/app-nap.json"
private let appNapKey = "NSAppSleepDisabled" as CFString

private enum JournalRead { case none, journal(AppNapJournal), unreadable }

private func readAppNapJournal() -> JournalRead {
    guard fm.fileExists(atPath: appNapJournalPath) else { return .none }
    guard let data = fm.contents(atPath: appNapJournalPath),
          let j = try? JSONDecoder().decode(AppNapJournal.self, from: data) else {
        logLine("\(appNapJournalPath) can't be read, leaving it as it is")
        return .unreadable
    }
    return .journal(j)
}

/// Write the journal, or delete the file when it's empty. False if that failed.
private func saveAppNapJournal(_ j: AppNapJournal) -> Bool {
    if j.prior.isEmpty { try? fm.removeItem(atPath: appNapJournalPath); return !fm.fileExists(atPath: appNapJournalPath) }
    do {
        try fm.createDirectory(atPath: (appNapJournalPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONEncoder().encode(j).write(to: URL(fileURLWithPath: appNapJournalPath), options: .atomic)
        return true
    } catch {
        logLine("couldn't write \(appNapJournalPath): \(error.localizedDescription)")
        return false
    }
}

/// The app's NSAppSleepDisabled: .some(nil) when there's no key, a Bool when
/// it's a boolean, nil (unknown) for any other kind of value, which is left alone.
private func appNapCurrent(_ id: String) -> Bool?? {
    CFPreferencesSynchronize(id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    guard let v = CFPreferencesCopyValue(appNapKey, id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return .some(nil) }
    guard CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
    return .some(CFBooleanGetValue((v as! CFBoolean)))
}

/// Set (or with nil, remove) the key and flush it. True once it synchronized.
private func appNapWrite(_ id: String, _ value: Bool?) -> Bool {
    CFPreferencesSetValue(appNapKey, value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }, id as CFString,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return CFPreferencesSynchronize(id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

extension AppController {
    /// Write YES for the installed listed apps that don't have it, journal first.
    /// Safe to run again: apps installed since are picked up, journaled ones are skipped.
    func applyAppNapOverride() {
        var journal = AppNapJournal(prior: [:])
        switch readAppNapJournal() {
        case .unreadable: return
        case .journal(let j): journal = j
        case .none: break
        }
        var current: [String: Bool?] = [:]
        for id in appNapAgentApps where appNapRestorable(id) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            if let c = appNapCurrent(id) { current[id] = c }
        }
        let before = journal
        let ids = journal.plan(current: current)
        guard !ids.isEmpty else { return }
        guard saveAppNapJournal(journal) else {   // no record, no write
            logLine("couldn't record the App Nap settings, changed nothing")
            _ = saveAppNapJournal(before)
            return
        }
        for id in ids where !appNapWrite(id, true) { logLine("App Nap: couldn't write \(id)'s settings") }
        logLine("App Nap off for \(ids.count) apps: \(ids.joined(separator: ", "))")
    }
}

/// Put every saved value back. An entry stays in the file until its restore
/// synchronized. Not tied to the controller: `ephedrine uninstall` runs it
/// through the `--restore-app-nap` launch flag, with no app running.
func restoreAppNapOverride() {
    guard case .journal(var journal) = readAppNapJournal() else { return }
    var restored: [String] = []
    for id in journal.unrestorable {   // never written to; just forgotten
        logLine("App Nap: dropping \(id) from the journal, not a bundle id")
        journal.prior[id] = nil
    }
    for (id, prior) in journal.restorePlan() {
        let value: Bool?
        switch prior { case .absent: value = nil; case .value(let b): value = b }
        if appNapWrite(id, value) { journal.prior[id] = nil; restored.append(id) }
        else { logLine("App Nap: couldn't put \(id)'s setting back, keeping it to try again") }
    }
    if !saveAppNapJournal(journal) { logLine("App Nap: couldn't update \(appNapJournalPath) after restoring") }
    if !restored.isEmpty { logLine("App Nap setting put back for \(restored.count) apps") }
}

/// Names of the listed apps that are installed, for the Settings list. Looked up once.
let appNapInstalledNames: [String] = {
    appNapAgentApps.compactMap { id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { fm.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }.sorted()
}()
