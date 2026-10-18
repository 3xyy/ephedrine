import Foundation

// Owner-only files, and the lid simulation file.

/// The mode to set on an item in Ephedrine's folder when group or other can
/// reach it (0700 for a folder, 0600 for a file), or nil when it is already
/// owner-only. Never returns a looser mode than it was given.
public func tightenedMode(current: UInt16, isDirectory: Bool) -> UInt16? {
    guard current & 0o077 != 0 else { return nil }
    return isDirectory ? 0o700 : 0o600
}

/// What the lid simulation file says: "closed" is true, "open" is false,
/// anything else (or no file) is nil, meaning use the real sensor.
public func simulatedLid(_ fileContents: String?) -> Bool? {
    switch fileContents?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "closed": return true
    case "open": return false
    default: return nil
    }
}
