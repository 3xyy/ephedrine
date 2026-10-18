import Foundation
import EphedrineCore

/// tmux's own serial queue, so a hung tmux can't stall the terminal scan.
private let tmuxQueue = DispatchQueue(label: "ephedrine.tmux")

/// A gap that ended longer ago than this is stale: never type for it.
private let nudgeFreshness: TimeInterval = 30

private func tmuxPath() -> String? {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

private struct TmuxRun { let status: Int32; let out: String; let timedOut: Bool }

/// One tmux call, never waiting more than `timeout` for it.
private func runTmux(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> TmuxRun {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    // TMUX would pick the server of whatever launched us; always use the default one.
    p.environment = ProcessInfo.processInfo.environment.filter { $0.key != "TMUX" && $0.key != "TMUX_PANE" }
    p.standardInput = FileHandle.nullDevice
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal() }
    do { try p.run() } catch { return TmuxRun(status: -1, out: "", timedOut: false) }
    let lock = NSLock()
    var data = Data()
    let reads = DispatchGroup()
    DispatchQueue.global(qos: .utility).async(group: reads) {
        let d = outPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); data = d; lock.unlock()
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
    return TmuxRun(status: timedOut ? -2 : p.terminationStatus, out: String(decoding: data, as: UTF8.self), timedOut: timedOut)
}

/// Type "continue" into each marked tmux pane, off the main thread. A pane is
/// typed into only when it is alive, not in copy or choose mode, accepting
/// input, and carries the owner's own pane-level mark. `canTypeNow` is asked
/// right before each send; `backAt` is when the network returned.
func nudgeTmux(targets: [String], pressEnter: Bool, backAt: Date = Date(), canTypeNow: @escaping () -> Bool) {
    guard !targets.isEmpty else { return }
    tmuxQueue.async {
        guard let tmux = tmuxPath() else { logLine("tmux nudge: tmux isn't installed"); return }
        for target in targets {
            guard Date().timeIntervalSince(backAt) <= nudgeFreshness else {
                logLine("tmux nudge: too long since the network came back, not typing into \(target)"); continue
            }
            func skip(_ why: String) { logLine("tmux nudge: skipped \(target): \(why). To allow it: \(tmuxMarkCommand(target))") }
            let state = runTmux(tmux, ["display-message", "-p", "-t", target, "-F", tmuxPaneStateFormat])
            if state.timedOut { skip("tmux didn't answer within 5s"); continue }
            // A failed lookup can leave stray output; only a clean exit counts.
            let pane: String
            switch state.status == 0 ? checkPane(state.out) : .skip("no such pane") {
            case .skip(let why): skip(why); continue
            case .ready(let id): pane = id
            }
            // -p: this pane's own option, never inherited from its window or session.
            let mark = runTmux(tmux, ["show-options", "-qpv", "-t", pane, tmuxMarkOption])
            if mark.timedOut { skip("tmux didn't answer within 5s"); continue }
            guard mark.status == 0, paneMarked(mark.out) else { skip("pane \(pane) isn't marked"); continue }
            guard canTypeNow() else { logLine("tmux nudge: the Mac isn't fully awake, not typing into \(target)"); continue }
            let typed = runTmux(tmux, ["send-keys", "-t", pane, "continue"])
            guard typed.status == 0 else { skip(typed.timedOut ? "tmux didn't answer within 5s" : "send-keys failed"); continue }
            if pressEnter {
                let enter = runTmux(tmux, ["send-keys", "-t", pane, "Enter"])
                guard enter.status == 0 else { skip("typed continue but not Enter"); continue }
            }
            logLine("tmux nudge: typed continue into \(target) (\(pane))")
        }
    }
}
