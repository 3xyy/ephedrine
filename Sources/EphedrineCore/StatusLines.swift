import Foundation

public enum LidChip: Equatable { case none, shut, canClose }

public struct StatusChip: Equatable {
    public enum Kind: Equatable { case lid, power, battery(level: Int, charging: Bool), wifi }
    public let kind: Kind
    public let text: String
    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

/// Plain data the menu's status card draws. Warnings carry no "⚠"; the card draws the triangle.
public struct MenuStatus: Equatable {
    public var headline: String
    public var detail: String?
    public var chips: [StatusChip]
    public var notes: [String]
    public var warnings: [String]
    public init(headline: String, detail: String? = nil, chips: [StatusChip] = [], notes: [String] = [], warnings: [String] = []) {
        self.headline = headline; self.detail = detail; self.chips = chips; self.notes = notes; self.warnings = warnings
    }
}

public enum StatusLines {
    /// Lid, power draw, battery, Wi-Fi, in that order; unknown ones are left out.
    public static func chips(lid: LidChip, watts: Double?, batteryPercent: Int?, charging: Bool, wifi: String?) -> [StatusChip] {
        var out: [StatusChip] = []
        switch lid {
        case .none: break
        case .shut: out.append(StatusChip(kind: .lid, text: "Lid shut"))
        case .canClose: out.append(StatusChip(kind: .lid, text: "Lid can close"))
        }
        if let w = watts, abs(w) >= 0.05 {
            out.append(StatusChip(kind: .power, text: String(format: "%.1f W", abs(w))))
        }
        if let p = batteryPercent {
            let level = min(100, max(0, p) / 25 * 25)
            out.append(StatusChip(kind: .battery(level: level, charging: charging),
                                  text: "\(p)%" + (charging && p < 100 ? " charging" : "")))
        }
        if let w = wifi {
            out.append(StatusChip(kind: .wifi, text: w == "on" ? "Connected" : w))
        }
        return out
    }

    /// What Ephedrine is currently holding back, or nil when nothing.
    public static func held(paused: Int, dockerPaused: Bool, muted: Bool, lowPower: Bool, lastGap: TimeInterval?) -> String? {
        var parts: [String] = []
        if paused > 0 { parts.append("\(paused) app\(paused == 1 ? "" : "s") paused") }
        if dockerPaused { parts.append("Docker paused") }
        if muted { parts.append("muted") }
        if lowPower { parts.append("Low Power Mode on") }
        if let g = lastGap, g > 0 { parts.append("last network gap \(Int(g.rounded()))s") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func batteryNote(floor: Int) -> String {
        "On battery, stops keeping it awake at \(floor)%"
    }
}

/// Watts from IOKit's InstantAmperage (mA) and Voltage (mV). Amperage is a
/// signed 32-bit value that sometimes arrives as its unsigned twin.
public func batteryWatts(amperage: Int64, voltage: Int64) -> Double {
    Double(Int32(truncatingIfNeeded: amperage)) * Double(voltage) / 1_000_000
}
