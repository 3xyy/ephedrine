import Foundation

/// Seconds to wait before join attempt number `attempt` (0 is the first).
public func hotspotRetryDelay(attempt: Int) -> TimeInterval {
    switch attempt {
    case ..<1: return 5
    case 1: return 10
    case 2: return 20
    default: return 30
    }
}

/// Decides when to try joining the saved hotspot: Wi-Fi has been down for 5 s,
/// something is holding the Mac awake, it is fully awake (a dark wake can't
/// join) and past the quiet after a wake (home Wi-Fi needs a moment to
/// reconnect), a hotspot is saved, Wi-Fi is switched on, nothing else (Ethernet)
/// keeps the Mac online, and the backoff since the last try has passed. Coming
/// back online, or any of those failing, restarts the count. Main thread only.
public struct HotspotJoinGate {
    private var downSince: Date?
    private var lastAttempt: Date?
    private var attempts = 0
    public init() {}

    /// True when a join attempt should start now.
    /// `wifiOn`: the Wi-Fi radio is on. `anyPathUp`: the network is usable on any interface. `afterWakeQuiet`: the post-wake quiet has passed.
    public mutating func step(wifiUp: Bool, holding: Bool, fullyAwake: Bool, configured: Bool,
                              wifiOn: Bool = true, anyPathUp: Bool = false, afterWakeQuiet: Bool = true, now: Date) -> Bool {
        guard !wifiUp else { reset(); return false }
        guard holding, fullyAwake, configured, wifiOn, !anyPathUp, afterWakeQuiet else { reset(); return false }
        let since = downSince ?? now
        downSince = since
        guard now.timeIntervalSince(since) >= hotspotRetryDelay(attempt: 0) else { return false }
        if let last = lastAttempt, now.timeIntervalSince(last) < hotspotRetryDelay(attempt: attempts) { return false }
        lastAttempt = now
        attempts += 1
        return true
    }

    private mutating func reset() { downSince = nil; lastAttempt = nil; attempts = 0 }
}

/// Whether the saved hotspot password could be read without asking.
public enum HotspotPasswordState: Equatable { case ok, missing, unreadable }
