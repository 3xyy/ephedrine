import Cocoa
import Darwin
import EphedrineCore

// ───────────────────────────── Docker rule ─────────────────────────────
//
// Docker Desktop is on the keep-running list, so the general pause never
// stops it. With the rule on, the lid-shut hold pauses it, but only when
// `docker ps -q` on Docker Desktop's own socket prints nothing, asked twice:
// at the hold's start and right before the stop. Any failure or a 5 s
// timeout leaves it running. Its processes are found by executable path
// (Docker can run as a menu-bar-only app) and join pausedProcesses, so
// they're written to paused-pids before the stop, resumed with everything
// else, and SIGCONTed by the watchdog after a crash.

let dockerSocketPath = "\(home)/.docker/run/docker.sock"

/// The docker CLI, from where Docker Desktop and Homebrew put it.
func dockerCLI() -> String? {
    ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.docker/bin", "/Applications/Docker.app/Contents/Resources/bin"]
        .map { $0 + "/docker" }
        .first { fm.isExecutableFile(atPath: $0) }
}

/// Docker Desktop's socket exists and is a socket.
func dockerSocketReady() -> Bool {
    var st = stat()
    return stat(dockerSocketPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
}

/// Docker Desktop's bundle: where Launch Services has it, else /Applications.
func dockerAppPath() -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker")?.resolvingSymlinksInPath().path
        ?? "/Applications/Docker.app"
}

/// Every process whose executable lies inside Docker.app (`bundle`), roots
/// first (each one's parent comes before it), the order the apps' processes are kept in.
func dockerProcesses(in procs: [ProcEntry], bundle: String = dockerAppPath()) -> [ProcEntry] {
    let prefix = bundle + "/"
    var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
    let inside = procs.filter { p in
        guard p.pid > 1 else { return false }
        let n = proc_pidpath(p.pid, &buf, UInt32(buf.count))
        guard n > 0 else { return false }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix(prefix)
    }
    let pids = Set(inside.map(\.pid))
    return descendants(of: inside.filter { !pids.contains($0.ppid) }.map(\.pid), in: inside)
}

/// Docker Desktop's processes now; empty when it isn't running (or the process list can't be read).
func dockerPids() -> [Int32] { dockerProcesses(in: processSnapshot()).map(\.pid) }

/// Ask Docker whether any container runs: idle only when `docker ps -q`
/// exits 0 within 5 s and prints nothing. No CLI, no socket, an error or the
/// timeout all count as busy, so Docker is left running. Runs the CLI off the
/// main thread; `completion` runs on main.
func probeDockerIdle(completion: @escaping (Bool) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        let idle = runDockerProbe()
        DispatchQueue.main.async { completion(idle) }
    }
}

private func runDockerProbe() -> Bool {
    guard let cli = dockerCLI() else { logLine("Docker rule: no docker CLI found, left Docker running"); return false }
    guard dockerSocketReady() else { logLine("Docker rule: \(dockerSocketPath) isn't there, left Docker running"); return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = dockerProbeArguments(socket: dockerSocketPath)
    // --host names the socket; an inherited DOCKER_CONTEXT could clash with it.
    p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DOCKER_") }
    p.standardInput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let out = Pipe()
    p.standardOutput = out
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { logLine("Docker rule: couldn't run docker (\(error.localizedDescription)), left Docker running"); return false }
    var data = Data()
    let read = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: read) { data = out.fileHandleForReading.readDataToEndOfFile() }
    if exited.wait(timeout: .now() + 5) == .timedOut {
        p.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
        logLine("Docker rule: docker didn't answer within 5s, left Docker running")
        return false
    }
    guard read.wait(timeout: .now() + 1) == .success else { logLine("Docker rule: couldn't read docker's answer, left Docker running"); return false }
    guard p.terminationStatus == 0 else { logLine("Docker rule: docker ps exited \(p.terminationStatus), left Docker running"); return false }
    let ps = String(decoding: data, as: UTF8.self)
    if !dockerIdle(psOutput: ps) {
        let n = ps.split(whereSeparator: \.isNewline).count
        logLine("Docker rule: \(n) container\(n == 1 ? "" : "s") running, left Docker running")
        return false
    }
    return true
}

extension AppController {

    /// The Docker rule, at the start of a lid-shut hold: ask Docker twice
    /// whether it's idle, then stop it. `generation` is the hold's; a newer one,
    /// or the hold ending (the lid opening) while Docker is asked, cancels it.
    func pauseDockerIfIdle(generation: Int) {
        guard !dockerPids().isEmpty else { return }   // not running
        probeDockerIdle { [weak self] idle in
            guard let self = self, idle, self.dockerRuleStillWanted(generation) else { return }
            // Once more, right before the stop: a container may have started meanwhile.
            probeDockerIdle { [weak self] idle in
                guard let self = self, idle, self.dockerRuleStillWanted(generation) else { return }
                self.stopDocker()
            }
        }
    }

    /// Still the same hold, still on, and nothing else owns the paused list.
    private func dockerRuleStillWanted(_ generation: Int) -> Bool {
        generation == lidHoldGeneration && lidHoldActive && lidShutHold(closed: lidIsClosed())
            && settings.lidDockerRule && !awayMode && !dockerPaused
    }

    /// SIGSTOP Docker Desktop's processes, the way suspendApps stops apps:
    /// recorded (and the record checked) first, then only those still the
    /// same process, children before parents.
    private func stopDocker() {
        let procs = processSnapshot()
        let docker = dockerProcesses(in: procs).filter { p in !pausedProcesses.contains { $0.pid == p.pid } }
        guard !docker.isEmpty else { return }   // quit meanwhile, or already paused (Always pause)
        let ps = runTool("/bin/ps", ["-axo", "pid=,args="])
        guard !ps.isEmpty else { logLine("Docker rule: couldn't run ps, so left Docker running in case Claude Code runs under it"); return }
        let claude = claudePids(psLines: ps.split(separator: "\n").map(String.init))
        if let why = claudeUsesDocker(dockerPIDs: docker.map(\.pid), procs: procs, claudePIDs: claude) {
            logLine("kept Docker running: \(why)")
            return
        }
        let entries = docker.map { PausedProcess(pid: $0.pid, start: $0.start) }
        pausedProcesses += entries
        guard persistAwayState() else {
            pausedProcesses.removeAll { entries.contains($0) }
            persistAwayState()
            logLine("Docker rule: couldn't record what to pause, left Docker running")
            return
        }
        let now = processSnapshot()
        let live = now.isEmpty ? [] : entries.filter { stillSame($0, in: now) }
        var failed = Set<pid_t>()
        for p in live.reversed() {   // children first, parents last
            if kill(p.pid, SIGSTOP) != 0 { failed.insert(p.pid) }
        }
        let stopped = Set(live.map(\.pid)).subtracting(failed)
        pausedProcesses.removeAll { entries.contains($0) && !stopped.contains($0.pid) }
        guard !stopped.isEmpty else {
            persistAwayState()
            logLine("Docker rule: Docker's processes changed before the stop, left it running")
            return
        }
        dockerPaused = true
        logLine("lid shut, paused Docker (\(stopped.count) processes): no container running")
    }
}
