import Foundation

/// The longest a Stay awake timer can run: 30 days.
public let maxStayAwake: TimeInterval = 30 * 24 * 3600

/// Days, hours and minutes as typed into the custom-duration panel. Empty
/// fields count as zero; nil for no input, anything but digits, a field over
/// three digits, a total of zero, or a total beyond `maxStayAwake`.
public func parseDuration(days: String, hours: String, minutes: String) -> TimeInterval? {
    let fields = [days, hours, minutes]
    guard fields.contains(where: { !$0.isEmpty }) else { return nil }
    var parts: [Int] = []
    for f in fields {
        guard f.count <= 3, f.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        parts.append(Int(f) ?? 0)
    }
    let total = TimeInterval(parts[0] * 86400 + parts[1] * 3600 + parts[2] * 60)
    guard total > 0, total <= maxStayAwake else { return nil }
    return total
}

/// `until` pushed back by `by`, never more than `maxStayAwake` from `now`.
public func extendedUntil(_ until: Date, by: TimeInterval, now: Date) -> Date {
    min(until.addingTimeInterval(by), now.addingTimeInterval(maxStayAwake))
}

/// Countdown for a Stay awake timer: "45s", "4:05", "1:30:00", "2d 3h".
public func fmtRemaining(_ secs: Int) -> String {
    if secs >= 86400 { return "\(secs / 86400)d \(secs % 86400 / 3600)h" }
    if secs >= 3600 { return String(format: "%d:%02d:%02d", secs / 3600, secs % 3600 / 60, secs % 60) }
    return fmtCountdown(secs)   // floors at "0s"

}
