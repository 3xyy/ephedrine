import Foundation

public enum FinishMode: String, CaseIterable {
    case sleepIfIdle, alwaysSleep, stayNormal
    public var label: String {
        switch self {
        case .sleepIfIdle: return "Sleep once I'm away  (recommended)"
        case .alwaysSleep: return "Sleep even if I'm using the Mac"
        case .stayNormal:  return "Don't auto-sleep"
        }
    }
    public var short: String {
        switch self {
        case .sleepIfIdle: return "sleep once I'm away"
        case .alwaysSleep: return "always sleep"
        case .stayNormal:  return "don't auto-sleep"
        }
    }
    public var tip: String {
        switch self {
        case .sleepIfIdle: return "Sleeps after you haven't touched the keyboard or mouse for the wait time. Never while you're using it."
        case .alwaysSleep: return "Sleeps once the wait time has passed since Claude finished, even if you're typing."
        case .stayNormal:  return "Only keeps the Mac awake while Claude works; macOS handles sleep after that."
        }
    }
}

public enum PowerMode: String, CaseIterable {
    case always, batteryOnly, acOnly
    public var label: String {
        switch self {
        case .always:      return "Battery or power adapter"
        case .batteryOnly: return "Battery only"
        case .acOnly:      return "Power adapter only"
        }
    }
    public var short: String {
        switch self {
        case .always:      return "battery or adapter"
        case .batteryOnly: return "battery only"
        case .acOnly:      return "power adapter only"
        }
    }
    public var tip: String {
        switch self {
        case .always:      return "Auto-sleep whatever the power source."
        case .batteryOnly: return "Plugged in, the Mac just follows your normal macOS settings."
        case .acOnly:      return "On battery, the Mac just follows your normal macOS settings."
        }
    }
}

public enum AutoContinueMode: String, CaseIterable {
    case off, fast, backoff, persistent
    public var short: String {
        switch self {
        case .off: return "off"; case .fast: return "every 15s, 5 tries"
        case .backoff: return "slowing down, 8 tries"; case .persistent: return "every 60s, no limit"
        }
    }
    public var label: String {
        switch self {
        case .off: return "Off"
        case .fast: return "Every 15 seconds, up to 5 tries"
        case .backoff: return "Slowing down, up to 8 tries"
        case .persistent: return "Every 60 seconds until it works"
        }
    }
    public var tip: String {
        switch self {
        case .off: return "Never type “continue” automatically."
        case .fast: return "Good for brief blips."
        case .backoff: return "Waits 30s, 1m, 2m, 4m, then 5m between tries. Best for longer outages."
        case .persistent: return "Keeps trying until the connection comes back."
        }
    }
    public var maxAttempts: Int {
        switch self { case .off: return 0; case .fast: return 5; case .backoff: return 8; case .persistent: return Int.max }
    }
    public func delay(_ n: Int) -> TimeInterval {
        switch self {
        case .off, .persistent: return 60
        case .fast: return 15
        case .backoff: return min(30.0 * pow(2.0, Double(n)), 300.0)
        }
    }
}

/// What one try at typing "continue" for an API error came to.
public enum ContinueTry: Equatable { case typed, skipped, notAwake }

/// An error episode's retry count after one try (continueAfterTry).
public struct ContinueTryStep: Equatable {
    public var attempts: Int
    public var nextTryAt: Date
    public var stuck = false    // a cmux pane: no more typing there until this error or limit is over
    public var gaveUp = false   // this try used up a limited mode's tries: say so, once
}

/// After a try at an unanswered API error, `attempts` tries in. Not awake:
/// nothing typed or counted, it tries again next scan. Typed: one more try,
/// the next after the mode's delay, and the last one a limited mode allows
/// gives up. Skipped (cmux typed nothing: no agent, a draft, a dialog, an
/// unreadable live screen or password): that was the episode's one try, so it
/// ends now and doesn't count toward giving up. Counted as a try instead, a
/// skip that keeps happening kept a retry pending forever in the mode with no
/// limit, and with it the Mac awake with the lid shut.
public func continueAfterTry(_ result: ContinueTry, attempts: Int, nextTryAt: Date, mode: AutoContinueMode,
                             cmux: Bool, now: Date) -> ContinueTryStep {
    switch result {
    case .notAwake:
        return ContinueTryStep(attempts: attempts, nextTryAt: nextTryAt)
    case .skipped:
        return ContinueTryStep(attempts: mode.maxAttempts, nextTryAt: nextTryAt, stuck: cmux)
    case .typed:
        let n = attempts + 1
        return ContinueTryStep(attempts: n, nextTryAt: now.addingTimeInterval(mode.delay(n)),
                               gaveUp: mode.maxAttempts != Int.max && n >= mode.maxAttempts)
    }
}

/// How long after the network comes back the held "continue" goes out.
public let continueAfterNetworkBack: TimeInterval = 10

/// Whether an error episode's next "continue" is due. While the network is
/// down it would only fail again after Claude Code's own retries and use up a
/// try, so nothing is due. Once it's back and has settled, one try is due at
/// once if the outage ended after this episode began and after its last try,
/// not at the backoff's next slot (up to 5 minutes later); then the backoff
/// goes on. 2026-10-22: Wi-Fi down 08:09 to 08:30, the error at 08:17.
public func continueDue(nextTryAt: Date, startedAt: Date, lastTryAt: Date?,
                        networkDown: Bool, networkBackAt: Date?, now: Date) -> Bool {
    if networkDown { return false }
    if let back = networkBackAt, now < back.addingTimeInterval(continueAfterNetworkBack) { return false }
    if now >= nextTryAt { return true }
    guard let back = networkBackAt else { return false }
    return back > max(startedAt, lastTryAt ?? .distantPast)
}

/// A retry still to come in some error episode, which counts as Claude
/// working (keeps lid-closed mode on, and "I'm leaving" awake). Off allows no tries.
public func continueRetrying(attempts: [Int], mode: AutoContinueMode) -> Bool {
    attempts.contains { $0 < mode.maxAttempts }
}

/// How the menu bar icon is colored.
public enum MenuBarIconStyle: String, CaseIterable {
    case mono      // template: follows the menu bar like other icons
    case accent    // menu-bar-colored mug with an orange spark while awake
    case state     // orange while awake, blue in a lid session, purple when away

    public var label: String {
        switch self {
        case .mono:   return "Match the menu bar"
        case .accent: return "Orange spark"
        case .state:  return "Color by state"
        }
    }
}

/// Decides when you're back from "I'm leaving". Input in the first `grace`
/// seconds is the click that started it (and you getting up), so it doesn't
/// count; any input after that does. An earlier rule only listened after 4s
/// of stillness, so a cursor that never stopped never brought the screen back.
public struct AwayReturn {
    public let enteredAt: Date
    public let grace: TimeInterval

    public init(enteredAt: Date, grace: TimeInterval = 3) {
        self.enteredAt = enteredAt
        self.grace = grace
    }

    /// `idleSeconds`: time since the last keyboard or mouse input. That counter
    /// stops while the Mac sleeps, so it can't be compared with clock time
    /// across a sleep: only input in the last few seconds counts, and only if
    /// it came after the grace.
    public func isBack(now: Date, idleSeconds: Double) -> Bool {
        idleSeconds < min(5, now.timeIntervalSince(enteredAt) - grace)
    }

    /// Input brings the screen back under a click aimed at "I'm back", which by
    /// then reads "I'm leaving". That click must not start away mode again.
    public static func ignoresLeaving(lastReturnByInput: Date?, now: Date) -> Bool {
        guard let back = lastReturnByInput else { return false }
        return now.timeIntervalSince(back) < 2
    }
}

/// "I'm leaving": once nothing has needed the Mac for `quiet` seconds (Claude
/// done, no usage-limit wait, no Stay awake), it's time to sleep. It used to
/// hold the Mac awake until you came back, and twice that meant all night on
/// battery. Only counts while fully awake, and starts over after each sleep.
public struct AwaySleep {
    public static let quiet: TimeInterval = 60
    /// A longer pause between steps (3s apart) means the Mac was asleep.
    public static let gap: TimeInterval = 10
    private var idleSince: Date?
    private var lastStep: Date?
    public init() {}

    /// True when it's time to sleep. Time asleep never counts: on 2026-10-14
    /// a tick while falling asleep started the quiet minute, and the wake 100s
    /// later slept the Mac again the moment you came back.
    public mutating func step(away: Bool, needed: Bool, fullyAwake: Bool, now: Date) -> Bool {
        defer { lastStep = now }
        if let last = lastStep, now.timeIntervalSince(last) > Self.gap { idleSince = nil }
        guard away, !needed, fullyAwake else { idleSince = nil; return false }
        let since = idleSince ?? now
        idleSince = since
        guard now.timeIntervalSince(since) >= Self.quiet else { return false }
        idleSince = nil   // a wake right after the sleep must not sleep again at once
        return true
    }
}

/// "I'm leaving" ends when the Mac wakes up with the lid open: you opened it or
/// pressed a key. `sinceLastCheck` over AwaySleep.gap means it was asleep. A
/// wake with the lid shut is a nap or a Remote Control check-in, not you.
public func awayEndsOnWake(sinceLastCheck: TimeInterval, fullyAwake: Bool, lidClosed: Bool) -> Bool {
    sinceLastCheck > AwaySleep.gap && fullyAwake && !lidClosed
}
