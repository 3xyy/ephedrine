import Foundation

/// The two Chromium flags that keep hidden or covered windows running at full speed.
public let unthrottleFlags = ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]

/// Chromium browsers that slow down hidden windows when the lid shuts.
public let chromiumBrowsers = [
    "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser",
    "ai.perplexity.comet", "com.brave.Browser", "com.microsoft.edgemac",
]

/// Split a command line into words: single quotes are literal, double quotes
/// allow `\"` and `\\`, and a backslash outside quotes escapes the next character.
public func shellWords(_ args: String) -> [String] {
    var words: [String] = []
    var cur = ""
    var started = false   // an empty quoted word ('') still counts
    var quote: Character?
    var escaped = false
    for c in args {
        if escaped {
            if quote == "\"" && c != "\"" && c != "\\" { cur.append("\\") }
            cur.append(c); escaped = false; continue
        }
        if let q = quote {
            if c == q { quote = nil }
            else if c == "\\" && q == "\"" { escaped = true }
            else { cur.append(c) }
            continue
        }
        switch c {
        case "'", "\"": quote = c; started = true
        case "\\": escaped = true; started = true
        case " ", "\t", "\n":
            if started || !cur.isEmpty { words.append(cur); cur = ""; started = false }
        default: cur.append(c); started = true
        }
    }
    if escaped { cur.append("\\") }
    if started || !cur.isEmpty { words.append(cur) }
    return words
}

private func hasFlag(_ words: [String], _ flag: String) -> Bool {
    words.contains { $0 == flag || $0.hasPrefix(flag + "=") }
}

/// Both flags are on the command line (`--flag=value` counts).
public func hasUnthrottleFlags(args: String) -> Bool {
    let words = shellWords(args)
    return unthrottleFlags.allSatisfy { hasFlag(words, $0) }
}

/// The flags to relaunch with: the unthrottle pair plus the original profile
/// choice, so the browser comes back in the same profile. `ps` joins argv with
/// plain spaces, so a value with spaces arrives as several words: the words that
/// follow a profile flag belong to it until the next flag, URL or absolute path.
public func relaunchArguments(args: String) -> [String] {
    let words = shellWords(args)
    var out = unthrottleFlags
    var i = 0
    while i < words.count {
        let w = words[i]
        i += 1
        guard w.hasPrefix("--user-data-dir=") || w.hasPrefix("--profile-directory=") else { continue }
        var value = w
        while i < words.count, let f = words[i].first, f != "-", f != "/", !words[i].contains("://") {
            value += " " + words[i]; i += 1
        }
        out.append(value)
    }
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
