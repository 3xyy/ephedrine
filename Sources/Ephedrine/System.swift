import Cocoa
import CoreGraphics
import IOKit.ps
import IOKit.pwr_mgt
import EphedrineCore

// ───────────────────────────── Logging ─────────────────────────────

// All log writes are funneled through one serial queue: logLine is called from
// the main thread and from the terminal-scan queue, and unsynchronized appends
// could interleave bytes and race the rotation.
private let logQueue = DispatchQueue(label: "ephedrine.log")
private let logStamp = ISO8601DateFormatter()

func logLine(_ msg: String) {
    logQueue.async {
        let line = "[\(logStamp.string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let sz = (try? fm.attributesOfItem(atPath: logPath))?[.size] as? Int, sz > 1_000_000 {
            try? fm.removeItem(atPath: logPath + ".1")
            try? fm.moveItem(atPath: logPath, toPath: logPath + ".1")
        }
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}

/// Block until queued log lines are written (call before exiting).
func flushLog() { logQueue.sync {} }

// ───────────────────────────── Subprocesses ─────────────────────────────

@discardableResult
func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice   // an undrained pipe can block the child forever
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Run osascript capturing stdout and stderr, draining both concurrently so a
/// full stderr pipe can never deadlock the read.
func runOsascript(_ script: String) -> (out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return ("", "spawn failed") }
    var errData = Data()
    let group = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: group) {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    return (String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

// ───────────────────────────── System state (in-process, no subprocess) ─────────────────────────────

/// Seconds since the last keyboard/mouse event. Verified to match ioreg's
/// HIDIdleTime; unlike shelling out to ioreg this is a few microseconds.
func hidIdleSeconds() -> Double {
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                .keyDown, .scrollWheel, .flagsChanged]
    var m = Double.greatestFiniteMagnitude
    for t in types { m = min(m, CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: t)) }
    return m.isFinite ? m : 0   // 0 = "active now" → fails safe (keeps awake / no sleep)
}

func onACPower() -> Bool {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else {
        return true   // unknown → assume AC (desktop); fails toward not sleeping on batteryOnly
    }
    return type == kIOPMACPowerKey
}

/// Ask macOS to sleep now, straight through the power manager. Replaces
/// `tell application "System Events" to sleep`, which on 2026-10-07 silently
/// did nothing three times with the lid shut and the screen locked.
/// Returns nil on success, else what went wrong.
func requestSystemSleep() -> String? {
    let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
    if port != 0 {
        let r = IOPMSleepSystem(port)
        IOServiceClose(port)
        if r == kIOReturnSuccess { return nil }
        // Not expected for the console user, but don't strand the Mac awake.
        let fallback = runToolStatus("/usr/bin/pmset", ["sleepnow"])
        return String(format: "IOPMSleepSystem 0x%x, pmset sleepnow exit %d", r, fallback)
    }
    return "no power manager connection, pmset sleepnow exit \(runToolStatus("/usr/bin/pmset", ["sleepnow"]))"
}

/// "Turn display off when inactive" minutes from pmset (0 = Never/unknown).
/// Still a subprocess, so callers cache it (see AppController.displaySleepMins).
func systemDisplaySleepMinutes() -> Int {
    let out = runTool("/usr/bin/pmset", ["-g"])
    for line in out.split(separator: "\n") where line.contains("displaysleep") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { $0 == "displaysleep" }),
           i + 1 < parts.count, let v = Int(parts[i + 1]) { return v }
    }
    return 0
}

// ───────────────────────────── Sleep assertions ─────────────────────────────

/// IOKit power assertions instead of a spawned `caffeinate`: released
/// automatically by the kernel if the process dies, so a crash can never
/// leave the Mac stuck awake.
final class AwakeAssertions {
    private var systemID = IOPMAssertionID(0)
    private var displayID = IOPMAssertionID(0)
    private(set) var systemOn = false
    private(set) var displayOn = false

    /// Returns true if anything changed (for logging).
    @discardableResult
    func apply(system: Bool, display: Bool) -> Bool {
        let a = set(&systemID, current: &systemOn, want: system,
                    type: kIOPMAssertionTypePreventUserIdleSystemSleep)
        let b = set(&displayID, current: &displayOn, want: display,
                    type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
        return a || b
    }

    private func set(_ id: inout IOPMAssertionID, current: inout Bool, want: Bool, type: String) -> Bool {
        if want == current { return false }
        if want {
            let r = IOPMAssertionCreateWithName(type as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Ephedrine: Claude Code / activity in progress" as CFString,
                                                &id)
            current = (r == kIOReturnSuccess)
            if !current { logLine("power assertion failed (\(type)): \(r)") }
        } else {
            IOPMAssertionRelease(id)
            id = IOPMAssertionID(0)
            current = false
        }
        return true
    }
}

// ───────────────────────────── ps snapshot cache ─────────────────────────────

/// One `ps` spawn per output format per evaluate tick, shared by all detectors.
final class PSCache {
    private var cache: [String: [String]] = [:]
    func lines(_ format: String) -> [String] {
        if let c = cache[format] { return c }
        let l = runTool("/bin/ps", ["-axo", format]).split(separator: "\n").map(String.init)
        cache[format] = l
        return l
    }
}

// ── Activity detectors (opt-in "also stay awake while…") ──

struct Detector {
    let key: String
    let label: String
    let tip: String
    let check: (PSCache) -> Bool
}
