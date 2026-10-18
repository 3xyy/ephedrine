import Foundation

/// The two Chromium flags that keep hidden or covered windows running at full speed.
public let unthrottleFlags = ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]

/// Chromium browsers that slow down hidden windows when the lid shuts.
public let chromiumBrowsers = [
    "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser",
    "ai.perplexity.comet", "com.brave.Browser", "com.microsoft.edgemac",
]

/// A process's argv from the bytes of `sysctl kern.procargs2`: an Int32 argc,
/// the exec path, NUL padding, then argc NUL-terminated arguments (the
/// environment follows and is ignored). nil when the bytes are cut short or
/// make no sense.
public func parseProcArgs2(_ data: [UInt8]) -> [String]? {
    guard data.count >= 4 else { return nil }
    let argc = Int(Int32(bitPattern: UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24))
    guard argc > 0, argc <= 4096 else { return nil }
    var i = 4
    func skip(_ nul: Bool) { while i < data.count && (data[i] == 0) == nul { i += 1 } }
    skip(false)                                   // exec path
    guard i < data.count else { return nil }
    skip(true)                                    // padding
    var argv: [String] = []
    while argv.count < argc {
        guard i < data.count else { return nil }
        guard let end = data[i...].firstIndex(of: 0) else { return nil }   // last argument not terminated
        argv.append(String(decoding: data[i..<end], as: UTF8.self))
        i = end + 1
    }
    return argv
}

private func hasFlag(_ argv: [String], _ flag: String) -> Bool {
    argv.contains { $0 == flag || $0.hasPrefix(flag + "=") }
}

/// Both flags are in the argument list (`--flag=value` counts).
public func hasUnthrottleFlags(argv: [String]) -> Bool {
    unthrottleFlags.allSatisfy { hasFlag(argv, $0) }
}

private let profileFlags = ["--user-data-dir=", "--profile-directory="]

/// The flags to relaunch with: the unthrottle pair plus the original profile
/// choice, so the browser comes back in the same profile.
public func relaunchArguments(argv: [String]) -> [String] {
    unthrottleFlags + argv.filter { a in profileFlags.contains { a.hasPrefix($0) } }
}

/// Directories that must exist before the browser is quit: the user data dir,
/// and the profile inside it when both flags are present.
public func profileDirectoriesToCheck(argv: [String]) -> [String] {
    func value(_ f: String) -> String? { argv.last { $0.hasPrefix(f) }.map { String($0.dropFirst(f.count)) } }
    guard let dir = value("--user-data-dir=") else { return [] }
    var out = [dir]
    if let p = value("--profile-directory=") { out.append((dir as NSString).appendingPathComponent(p)) }
    return out
}

/// "Chrome is throttled with the lid shut" for the menu; nil when none are.
public func throttleWarning(_ names: [String]) -> String? {
    switch names.count {
    case 0: return nil
    case 1: return "\(names[0]) is throttled with the lid shut"
    default:
        let list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "\(list) are throttled with the lid shut"
    }
}
