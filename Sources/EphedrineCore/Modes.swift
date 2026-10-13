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

    /// `idleSeconds`: time since the last keyboard or mouse input.
    public func isBack(now: Date, idleSeconds: Double) -> Bool {
        now.addingTimeInterval(-idleSeconds) > enteredAt.addingTimeInterval(grace)
    }

    /// Input brings the screen back under a click aimed at "I'm back", which by
    /// then reads "I'm leaving". That click must not start away mode again.
    public static func ignoresLeaving(lastReturnByInput: Date?, now: Date) -> Bool {
        guard let back = lastReturnByInput else { return false }
        return now.timeIntervalSince(back) < 2
    }
}
