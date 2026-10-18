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

/// One tmux call, never waiting more than `timeout` for it.
private func runTmux(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> ProcRun {
    // TMUX would pick the server of whatever launched us; always use the default one.
    runProcess(path, args, tweakEnv: { $0["TMUX"] = nil; $0["TMUX_PANE"] = nil }, timeout: timeout)
}

/// tmux's own first error line, for the log.
private func tmuxWhy(_ r: ProcRun) -> String {
    if r.timedOut { return "tmux didn't answer within 5s" }
    let line = r.err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(r.status)"
    return String(line.prefix(200))
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
            func skip(_ why: String) { logLine("tmux nudge: skipped \(target): \(why). Mark command: \(tmuxMarkCommand(target))") }
            let state = runTmux(tmux, ["display-message", "-p", "-t", target, "-F", tmuxPaneStateFormat])
            // A failed lookup can leave stray output; only a clean exit counts.
            if state.status != 0 { skip(state.launchFailed ? "couldn't start tmux: \(state.err)" : tmuxWhy(state)); continue }
            let pane: String
            switch checkPane(state.out) {
            case .skip(let why): skip(why); continue
            case .ready(let id): pane = id
            }
            // -p: this pane's own option, never inherited from its window or session.
            let mark = runTmux(tmux, ["show-options", "-qpv", "-t", pane, tmuxMarkOption])
            if mark.status != 0 { skip(tmuxWhy(mark)); continue }
            guard paneMarked(mark.out) else { skip("pane \(pane) isn't marked"); continue }
            // Last checks, right before typing: the network came back recently, and the Mac is fully awake.
            guard Date().timeIntervalSince(backAt) <= nudgeFreshness else {
                logLine("tmux nudge: dropped, too long since the network came back (\(target))"); continue
            }
            guard canTypeNow() else { logLine("tmux nudge: dropped, the Mac isn't fully awake or just woke (\(target))"); continue }
            let typed = runTmux(tmux, ["send-keys", "-t", pane, "continue"])
            guard typed.status == 0 else { skip(tmuxWhy(typed)); continue }
            if pressEnter {
                let enter = runTmux(tmux, ["send-keys", "-t", pane, "Enter"])
                guard enter.status == 0 else { skip("typed continue but not Enter: " + tmuxWhy(enter)); continue }
            }
            logLine("tmux nudge: typed continue into \(target) (\(pane))")
        }
    }
}
