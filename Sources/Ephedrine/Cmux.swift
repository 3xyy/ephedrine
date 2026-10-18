import Cocoa
import Security
import EphedrineCore

// ── Reading & typing into cmux panes (auto-continue / limit-resume) ──
// cmux is a Ghostty-based terminal with a CLI that talks to its socket. Only
// its Password mode is supported: the password reaches the CLI as
// CMUX_SOCKET_PASSWORD in the child's environment, never as an argument
// (arguments show in `ps` to every user), and it is never logged.

let cmuxBundleID = "com.cmuxterm.app"
let cmuxKeyPrefix = "cmux:"   // per-tab state keys, so they can't collide with Terminal ttys

/// The CLI inside the running cmux, nil when cmux isn't running.
/// (NSRunningApplication is thread safe, so any queue may ask.)
func runningCmuxCLI() -> String? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: cmuxBundleID).first,
          let url = app.bundleURL else { return nil }
    return url.appendingPathComponent("Contents/Resources/bin/cmux").path
}

func cmuxInstalled() -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: cmuxBundleID) != nil }

/// The cmux socket password, a generic password in the login keychain.
enum CmuxKeychain {
    static let service = "ephedrine-cmux"
    static let account = "socket"
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// nil means no password saved. Never shows a dialog: an item macOS would
    /// ask about is skipped, which also reads as none.
    static func read() -> String? {
        var q = item
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,   // errSecItemNotFound: none saved
              let data = out as? Data, let pw = String(data: data, encoding: .utf8), !pw.isEmpty else { return nil }
        return pw
    }

    /// Save the password, or remove it when empty.
    static func save(_ password: String) -> OSStatus {
        guard !password.isEmpty else {
            let s = SecItemDelete(item as CFDictionary)
            return s == errSecItemNotFound ? errSecSuccess : s
        }
        let data = Data(password.utf8)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Ephedrine cmux socket password"
        let s = SecItemAdd(add as CFDictionary, nil)
        guard s == errSecDuplicateItem else { return s }
        return SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }
}

struct CmuxRun { let status: Int32; let out: String; let err: String; let timedOut: Bool }

/// Run the cmux CLI with the password in its environment, never waiting more
/// than `timeout` for it (plus a second or two to stop it). A stalled cmux
/// must not hold up the scan, which also serves Terminal.
func runCmux(_ cli: String, _ args: [String], password: String, timeout: TimeInterval = 5) -> CmuxRun {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = args
    // Inherited CMUX_* variables could point it at another socket or a default
    // surface; every call names its surface explicitly.
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
    env["CMUX_SOCKET_PASSWORD"] = password
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { return CmuxRun(status: cmuxLaunchFailed, out: "", err: "\(error)", timedOut: false) }
    // Drain both pipes while it runs, so a full pipe can't stall it.
    let lock = NSLock()
    var outData = Data(), errData = Data()
    let reads = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: reads) {
        let d = outPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); outData = d; lock.unlock()
    }
    DispatchQueue.global(qos: .utility).async(group: reads) {
        let d = errPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); errData = d; lock.unlock()
    }
    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        p.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }
    _ = reads.wait(timeout: .now() + 1)
    lock.lock(); defer { lock.unlock() }
    return CmuxRun(status: timedOut ? -2 : p.terminationStatus,
                   out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                   timedOut: timedOut)
}

/// Why a run didn't do its job, for the log (cmux's own error line).
private func cmuxWhy(_ r: CmuxRun) -> String {
    if r.timedOut { return "cmux didn't answer within 5s" }
    let line = r.err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(r.status)"
    return String(line.prefix(200))
}

/// cmux's terminal panes and each one's visible text: one listing, then one
/// read-screen per pane. Read-only. Runs off the main thread; every call
/// waits 5s at most, and the first one to time out ends the read, so a
/// stalled cmux costs one scan a few seconds, not one per pane.
/// access nil: cmux didn't answer, so this read says nothing about it.
func cmuxSurfacesSnapshot(cli: String, password: String) -> (tabs: [(CmuxSurface, String)], access: CmuxAccess?) {
    let list = runCmux(cli, cmuxListArgs, password: password)
    if list.timedOut { return ([], nil) }
    let access = cmuxAccess(exitCode: list.status, output: list.err + "\n" + list.out)
    guard access == .ok else { return ([], access) }
    var tabs: [(CmuxSurface, String)] = []
    for s in parseCmuxSurfaces(list.out) {
        let r = runCmux(cli, cmuxReadArgs(s.id), password: password)
        if r.timedOut { return ([], nil) }
        if r.status == 0 { tabs.append((s, r.out)) }   // closed since the listing, or not readable: skip it
    }
    return (tabs, .ok)
}

/// Type text, then Enter, into one cmux surface. nil when both went out,
/// else why not. Without `force`, cmux itself refuses to type over a
/// half-written prompt or into an open question, and nothing is typed.
func sendToCmux(_ text: String, surfaceID: String, force: Bool) -> String? {
    guard let cli = runningCmuxCLI() else { return "cmux isn't running" }
    guard let pw = CmuxKeychain.read() else { return "no cmux password saved" }
    let typed = runCmux(cli, cmuxSendArgs(surfaceID, text, force: force), password: pw)
    guard !typed.timedOut, typed.status == 0 else { return cmuxWhy(typed) }
    let enter = runCmux(cli, cmuxEnterArgs(surfaceID, force: force), password: pw)
    guard !enter.timedOut, enter.status == 0 else { return "typed “\(text)” but not Enter: " + cmuxWhy(enter) }
    return nil
}
