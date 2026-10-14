import Foundation

// ── "Update available" check ──
//
// The app reads the Homebrew formula now and then and shows an item at the
// top of the menu when it installs a newer version than the running one.

/// The Homebrew formula: exactly what `brew upgrade` installs, and served
/// from GitHub's file CDN, which unlike api.github.com isn't limited to 60
/// requests an hour per address (a shared VPN address used that up).
public let updateCheckURL = "https://raw.githubusercontent.com/3xyy/homebrew-tap/main/Formula/ephedrine.rb"

/// Numeric parts of a version ("v1.10.0-beta" → [1, 10, 0]), nil if it
/// doesn't start with a number.
func versionParts(_ v: String) -> [Int]? {
    var s = Substring(v)
    if s.first == "v" || s.first == "V" { s = s.dropFirst() }
    let parts = s.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }.split(separator: ".").map { Int($0) }
    guard !parts.isEmpty, !parts.contains(nil) else { return nil }
    return parts.compactMap { $0 }
}

/// Compares numerically, part by part; missing parts count as 0. Anything it
/// can't read is "not newer", so a bad reply never shows a false update.
public func isNewerVersion(_ latest: String, than current: String) -> Bool {
    guard let a = versionParts(latest), let b = versionParts(current) else { return false }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

public struct LatestRelease: Equatable {
    public let version: String   // without the "v"
    public let url: String       // the release page
}

/// The version the formula installs, and its release page. Nil for an error
/// page or a formula that points anywhere but this project's tagged releases.
public func parseFormulaVersion(_ text: String) -> LatestRelease? {
    let pattern = #"url "https://github\.com/3xyy/ephedrine/archive/refs/tags/v([0-9][0-9A-Za-z.-]*)\.tar\.gz""#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r = Range(m.range(at: 1), in: text) else { return nil }
    let version = String(text[r])
    guard versionParts(version) != nil else { return nil }
    return LatestRelease(version: version, url: "https://github.com/3xyy/ephedrine/releases/tag/v\(version)")
}
