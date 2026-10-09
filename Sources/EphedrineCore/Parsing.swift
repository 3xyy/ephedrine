import Foundation

// ── Dates & formatting ──

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

/// Parse ISO-8601 like "2026-06-30T01:20:00.943766+00:00" (any fractional precision).
public func parseISO(_ s: String) -> Date? {
    if let d = isoFractional.date(from: s) ?? isoPlain.date(from: s) { return d }
    // Fallback: strip the fractional part (ISO8601DateFormatter only accepts millisecond precision).
    guard let dot = s.firstIndex(of: ".") else { return nil }
    let tail = s[s.index(after: dot)...]
    guard let sign = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
    return isoPlain.date(from: String(s[..<dot]) + String(tail[sign...]))
}

public func clockStr(_ d: Date?) -> String {
    guard let d = d else { return "?" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
    return f.string(from: d)
}

public func fmtCountdown(_ secs: Int) -> String {
    let s = max(0, secs)
    return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)s"
}

// ── Regex helper ──

public func regexGroups(_ pattern: String, _ text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
    }
}

// ── Session markers ──

/// Expiry epoch for a session marker: the file's numeric contents, else
/// mtime + fallback lease, else nil (unreadable → caller should delete).
public func markerExpiry(contents: String?, mtime: Date?, leaseFallback: TimeInterval) -> Double? {
    if let s = contents, let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
    if let m = mtime { return m.timeIntervalSince1970 + leaseFallback }
    return nil
}

// ── AppleScript ──

/// Quote a string for interpolation inside an AppleScript string literal.
public func appleScriptQuoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Single-quote a string for /bin/sh.
public func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
