import Foundation

public enum FeatureKind: Equatable { case lid, lowPower, whenShut, cmux, hotspot, network, tmux }
public enum RowTone: Equatable { case normal, active, ok, warn, dim }

public struct FeatureRow: Equatable {
    public let kind: FeatureKind
    public let label: String
    public let text: String
    public let tone: RowTone
    public init(kind: FeatureKind, label: String, text: String, tone: RowTone) {
        self.kind = kind; self.label = label; self.text = text; self.tone = tone
    }
}

public enum CmuxRowState: Equatable { case notInstalled, notRunning, noPassword, badPassword, failed, connected(Int) }

public struct FeatureSnapshot {
    public var lidSetup: Bool, lidHolding: Bool, lidClosed: Bool, claudeWorking: Bool, stayAwake: Bool
    public var lowPowerNeedsRerun: Bool
    public var lowPowerOn: LowPowerCause?
    public var lowPowerOnLidShut: Bool
    public var lowPowerFloor: Int
    public var muteOnShut: Bool, keyboardOffOnShut: Bool, pauseAppsOnShut: Bool, dockerRule: Bool
    public var cmux: CmuxRowState
    public var hotspotSSID: String
    public var hotspotPassword: HotspotPasswordState
    public var holding: Bool
    public var networkUp: Bool
    public var downFor: TimeInterval?
    public var lastGap: TimeInterval?
    public var tmuxTargets: Int

    public init(lidSetup: Bool, lidHolding: Bool, lidClosed: Bool, claudeWorking: Bool, stayAwake: Bool,
                lowPowerNeedsRerun: Bool, lowPowerOn: LowPowerCause?, lowPowerOnLidShut: Bool, lowPowerFloor: Int,
                muteOnShut: Bool, keyboardOffOnShut: Bool, pauseAppsOnShut: Bool, dockerRule: Bool,
                cmux: CmuxRowState, hotspotSSID: String, hotspotPassword: HotspotPasswordState, holding: Bool,
                networkUp: Bool, downFor: TimeInterval?, lastGap: TimeInterval?, tmuxTargets: Int) {
        self.lidSetup = lidSetup; self.lidHolding = lidHolding; self.lidClosed = lidClosed
        self.claudeWorking = claudeWorking; self.stayAwake = stayAwake
        self.lowPowerNeedsRerun = lowPowerNeedsRerun; self.lowPowerOn = lowPowerOn
        self.lowPowerOnLidShut = lowPowerOnLidShut; self.lowPowerFloor = lowPowerFloor
        self.muteOnShut = muteOnShut; self.keyboardOffOnShut = keyboardOffOnShut
        self.pauseAppsOnShut = pauseAppsOnShut; self.dockerRule = dockerRule
        self.cmux = cmux; self.hotspotSSID = hotspotSSID; self.hotspotPassword = hotspotPassword
        self.holding = holding; self.networkUp = networkUp; self.downFor = downFor; self.lastGap = lastGap
        self.tmuxTargets = tmuxTargets
    }
}

public enum FeatureRows {
    public static func rows(_ s: FeatureSnapshot) -> [FeatureRow] {
        var out: [FeatureRow] = []
        func add(_ k: FeatureKind, _ label: String, _ text: String, _ tone: RowTone) {
            out.append(FeatureRow(kind: k, label: label, text: text, tone: tone))
        }

        if !s.lidSetup { add(.lid, "Lid", "Sleeps when shut", .dim) }
        else if s.lidClosed { add(.lid, "Lid", "Shut, on an external display", .normal) }
        else if s.lidHolding { add(.lid, "Lid", s.claudeWorking ? "Shut it, Claude keeps going" : "Shut it, stays awake", .active) }
        else { add(.lid, "Lid", "Sleeps if you shut it now", .normal) }

        if s.lidSetup {
            let floor = s.lowPowerFloor
            if s.lowPowerNeedsRerun { add(.lowPower, "Low Power", "Needs lid setup re-run", .warn) }
            else if let cause = s.lowPowerOn {
                switch cause {
                case .lid: add(.lowPower, "Low Power", "On while the lid is shut", .active)
                case .battery: add(.lowPower, "Low Power", "On, battery under \(floor)%", .active)
                case .heat: add(.lowPower, "Low Power", "On, the Mac is hot", .active)
                }
            } else {
                let lid = s.lowPowerOnLidShut, bat = floor > 0
                switch (lid, bat) {
                case (true, true): add(.lowPower, "Low Power", "On with the lid shut, or below \(floor)%", .normal)
                case (true, false): add(.lowPower, "Low Power", "Comes on when the lid shuts", .normal)
                case (false, true): add(.lowPower, "Low Power", "Comes on below \(floor)% on battery", .normal)
                case (false, false): add(.lowPower, "Low Power", "Off", .dim)
                }
            }

            var parts: [String] = []
            if s.muteOnShut { parts.append("mutes") }
            if s.keyboardOffOnShut { parts.append("keys dark") }
            switch (s.pauseAppsOnShut, s.dockerRule) {
            case (true, true): parts.append("apps and Docker paused")
            case (true, false): parts.append("apps paused")
            case (false, true): parts.append("Docker paused")
            case (false, false): break
            }
            if parts.isEmpty { add(.whenShut, "When shut", "Nothing extra", .dim) }
            else { add(.whenShut, "When shut", parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst(), .normal) }
        }

        switch s.cmux {
        case .notInstalled: break
        case .notRunning: add(.cmux, "cmux", "Not running", .dim)
        case .noPassword: add(.cmux, "cmux", "Add its password in Settings to connect", .dim)
        case .badPassword: add(.cmux, "cmux", "Password not accepted", .warn)
        case .failed: add(.cmux, "cmux", "Not connected", .dim)
        case .connected(let n):
            let panes = n == 1 ? "1 pane" : "\(n) panes"
            add(.cmux, "cmux", s.claudeWorking ? "Watching \(panes)" : "Connected, \(panes)", .ok)
        }

        if s.hotspotSSID.isEmpty { add(.hotspot, "Hotspot", "Not set up", .dim) }
        else if s.hotspotPassword == .unreadable { add(.hotspot, "Hotspot", "Password needs re-entering", .warn) }
        else if s.hotspotPassword == .missing { add(.hotspot, "Hotspot", "Add its password in Settings", .dim) }
        else if s.holding { add(.hotspot, "Hotspot", "Joins \(s.hotspotSSID) if Wi-Fi drops", .active) }
        else { add(.hotspot, "Hotspot", "Ready: \(s.hotspotSSID)", .normal) }

        if !s.networkUp {
            add(.network, "Network", "Offline for \(fmtDuration(Int((s.downFor ?? 0).rounded())))", .warn)
        } else if let g = s.lastGap, g > 0 {
            add(.network, "Network", "Online, last gap \(fmtDuration(Int(g.rounded())))", .normal)
        } else { add(.network, "Network", "Online", .normal) }

        if s.tmuxTargets > 0 {
            add(.tmux, "tmux", "Nudges \(s.tmuxTargets) pane\(s.tmuxTargets == 1 ? "" : "s") after outages", .normal)
        }
        return out
    }

    public static func hint(_ s: FeatureSnapshot) -> String? {
        if !s.lidSetup { return "Set up lid-closed mode in Settings to keep Claude going with the lid shut." }
        if !s.lidHolding && !s.claudeWorking { return "Start Claude Code and the lid can be shut without the Mac sleeping." }
        return nil
    }
}
