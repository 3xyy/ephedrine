import Foundation

/// Times network outages. Feed it every path update; it reports a gap's
/// length once, on the update that ends it. Main thread only.
public struct OutageTracker {
    public private(set) var downSince: Date?
    public private(set) var lastGap: TimeInterval?
    public init() {}

    @discardableResult
    public mutating func step(satisfied: Bool, now: Date) -> TimeInterval? {
        if !satisfied {
            if downSince == nil { downSince = now }
            return nil
        }
        guard let since = downSince else { return nil }
        downSince = nil
        let gap = max(0, now.timeIntervalSince(since))
        lastGap = gap
        return gap
    }
}

/// The pane option the owner sets to allow typing there. Set per pane (`-p`).
public let tmuxMarkOption = "@ephedrine-nudge"
public let tmuxPaneStateFormat = "#{pane_id} #{pane_dead} #{pane_in_mode} #{pane_input_off}"

public enum PaneCheck: Equatable { case ready(String), skip(String) }

/// Read `display-message -p -F tmuxPaneStateFormat`: the pane id when it is
/// alive, not in copy or choose mode, and accepting input.
public func checkPane(_ output: String) -> PaneCheck {
    let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.isEmpty { return .skip("no such pane") }
    let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard f.count == 4, f[0].count > 1, f[0].hasPrefix("%"), f[0].dropFirst().allSatisfy(\.isNumber),
          f[1...].allSatisfy({ $0 == "0" || $0 == "1" }) else {
        return .skip("pane id unreadable (\(line))")
    }
    let id = f[0]
    if f[1] != "0" { return .skip("pane \(id) is dead") }
    if f[2] != "0" { return .skip("pane \(id) is in copy or choose mode") }
    if f[3] != "0" { return .skip("pane \(id) has input turned off") }
    return .ready(id)
}

/// `show-options -qpv` output: marked only when it is exactly "on".
public func paneMarked(_ showOptionsOutput: String) -> Bool {
    showOptionsOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "on" &&
        showOptionsOutput.split(whereSeparator: \.isNewline).count == 1
}

public func tmuxMarkCommand(_ target: String) -> String {
    let plain = !target.isEmpty && target.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "%:._-".unicodeScalars.contains($0)
    }
    let t = plain ? target : "'" + target.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return "tmux set-option -p -t \(t) \(tmuxMarkOption) on"
}

/// Whether an outage that just ended should type into the marked panes: long
/// enough, panes listed, fully awake, and it began after the last sleep began
/// (a gap that is mostly sleep, or a path-up before the wake is noticed, never types).
public func shouldNudge(gap: TimeInterval, threshold: TimeInterval, targets: [String], awake: Bool,
                        downSince: Date?, lastSleep: Date) -> Bool {
    guard let since = downSince else { return false }
    return gap >= threshold && !targets.isEmpty && awake && since > lastSleep
}
