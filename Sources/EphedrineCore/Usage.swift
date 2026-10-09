import Foundation

// Claude plan usage from Anthropic's `GET /api/oauth/usage` (the same data as
// claude.ai → Settings → Usage). Pure parsing so it can be tested against a
// captured response.

public struct UsageLimit: Equatable {
    public let key: String        // stable id for alert tracking, e.g. "weekly_scoped:Fable"
    public let label: String      // row label, e.g. "Fable only"
    public let percent: Double
    public let resetsAt: Date?
    public let severity: String?  // API's own rating ("normal", …) when present

    public init(key: String, label: String, percent: Double, resetsAt: Date?, severity: String? = nil) {
        self.key = key; self.label = label; self.percent = percent
        self.resetsAt = resetsAt; self.severity = severity
    }
}

/// The endpoint computes resets_at from the request time, so it jitters by
/// sub-second amounts between fetches (08:10:00.12 on one call, 08:09:59.63 on
/// the next). Round to the minute so equality means "same reset window" and
/// the clock shows 8:10, not 8:09.
public func roundedToMinute(_ d: Date) -> Date {
    Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
}

/// Every limit the response reports, in the API's order. Prefers the
/// `limits` array (session / weekly all-models / weekly per-model such as
/// "Fable only"); falls back to the legacy `five_hour` / `seven_day` keys.
public func parseUsageLimits(_ json: [String: Any]) -> [UsageLimit] {
    func date(_ v: Any?) -> Date? { (v as? String).flatMap(parseISO).map(roundedToMinute) }

    if let arr = json["limits"] as? [[String: Any]] {
        let parsed = arr.compactMap { l -> UsageLimit? in
            guard let kind = l["kind"] as? String,
                  let pct = (l["percent"] as? NSNumber)?.doubleValue else { return nil }
            let scope = l["scope"] as? [String: Any]
            let scopeName = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
            let label: String
            switch kind {
            case "session":    label = "Session (5h)"
            case "weekly_all": label = "Weekly · all models"
            default:
                if let s = scopeName { label = "\(s) only" }
                else { label = kind.replacingOccurrences(of: "_", with: " ").capitalized }
            }
            return UsageLimit(key: scopeName.map { "\(kind):\($0)" } ?? kind, label: label,
                              percent: pct, resetsAt: date(l["resets_at"]),
                              severity: l["severity"] as? String)
        }
        if !parsed.isEmpty { return parsed }
    }

    let legacy: [(String, String)] = [("five_hour", "Session (5h)"), ("seven_day", "Weekly · all models"),
                                      ("seven_day_opus", "Opus only"), ("seven_day_sonnet", "Sonnet only")]
    return legacy.compactMap { key, label in
        guard let o = json[key] as? [String: Any],
              let pct = (o["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return UsageLimit(key: key, label: label, percent: pct, resetsAt: date(o["resets_at"]))
    }
}

public enum UsageLevel { case normal, warning, critical }

/// Bar colour: by percentage, escalated if the API itself flags the limit.
public func usageLevel(percent: Double, severity: String? = nil) -> UsageLevel {
    switch severity?.lowercased() {
    case "critical", "error", "exceeded", "limited", "blocked", "danger": return .critical
    case "warning", "warn":
        return percent >= 90 ? .critical : .warning
    default:
        return percent >= 90 ? .critical : (percent >= 70 ? .warning : .normal)
    }
}

/// Decides when to post a "usage at N%" notification: once when a limit
/// crosses the threshold, and again if a *new* reset window starts while it's
/// still above. Keyed per limit, so new limits (e.g. "Fable only") just work.
public struct UsageAlertTracker {
    private var wasAbove: [String: Bool] = [:]
    private var alertedWindow: [String: Date] = [:]

    public init() {}

    /// Limits that should notify now (and records that they did).
    public mutating func check(_ limits: [UsageLimit], threshold: Int) -> [UsageLimit] {
        guard threshold > 0 else { return [] }
        var fire: [UsageLimit] = []
        for l in limits {
            let above = l.percent >= Double(threshold)
            let newWindow = l.resetsAt != nil && alertedWindow[l.key] != nil && l.resetsAt != alertedWindow[l.key]
            if above && (wasAbove[l.key] != true || newWindow) {
                fire.append(l)
                alertedWindow[l.key] = l.resetsAt
            }
            wasAbove[l.key] = above
        }
        return fire
    }
}
