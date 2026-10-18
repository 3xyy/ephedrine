import Foundation

/// Which Settings tabs show the orange attention dot.
public struct SettingsAttention: Equatable {
    public var lid: Bool
    public var claude: Bool
    public var about: Bool

    public init(lid: Bool = false, claude: Bool = false, about: Bool = false) {
        self.lid = lid; self.claude = claude; self.about = about
    }

    /// Lid closed: the lid rule needs re-running for Low Power Mode, or there's
    /// no lid setup while "While Claude is working" (with keep-awake on) would
    /// use it. Claude Code: the saved cmux password can't be read, or cmux
    /// turned it down. About: a newer version is out.
    public static func evaluate(lidSetupOK: Bool, lowPowerSetupNeeded: Bool, keepAwakeOn: Bool, lidWhileClaude: Bool,
                                cmux: CmuxRowState, updateAvailable: Bool) -> SettingsAttention {
        SettingsAttention(lid: lowPowerSetupNeeded || (!lidSetupOK && keepAwakeOn && lidWhileClaude),
                          claude: cmux == .unreadablePassword || cmux == .badPassword,
                          about: updateAvailable)
    }
}

/// The status banners' text for the Settings panes that say it from settings alone.
public enum SettingsBanners {
    public static func general(enabled: Bool) -> (headline: String, sentence: String) {
        enabled
            ? ("Keeping the Mac awake while Claude works",
               "Once Claude is done it sleeps the way you set under Sleep. Stay awake, I'm leaving and lid sessions work either way.")
            : ("Off, macOS sleeps as usual",
               "Ephedrine won't keep the Mac awake for Claude. Stay awake, I'm leaving and lid sessions still work.")
    }

    /// What happens once Claude finishes. `waitSeconds` is the wait in use
    /// (the display-off time when it follows that).
    public static func sleep(finishMode: FinishMode, waitSeconds: Int, powerMode: PowerMode) -> (headline: String, sentence: String) {
        let wait = waitText(waitSeconds)
        let power: String
        switch powerMode {
        case .always: power = ""
        case .batteryOnly: power = " Plugged in, your normal macOS settings apply."
        case .acOnly: power = " On battery, your normal macOS settings apply."
        }
        switch finishMode {
        case .sleepIfIdle:
            return ("After Claude finishes, the Mac sleeps once you're away",
                    "It waits until the keyboard and mouse have been idle for \(wait)." + power)
        case .alwaysSleep:
            return ("After Claude finishes, the Mac sleeps even if you're using it",
                    "It sleeps \(wait) after Claude is done, even while you're typing." + power)
        case .stayNormal:
            return ("After Claude finishes, macOS handles sleep",
                    "Ephedrine only keeps the Mac awake while Claude works.")
        }
    }

    /// The Lid closed pane's banner. `action` is what its button does, if any.
    public enum LidAction: Equatable { case setUp, rerunSetup }

    public static func lid(setupOK: Bool, lowPowerSetupNeeded: Bool, whileClaude: Bool)
        -> (headline: String, sentence: String, action: LidAction?) {
        if !setupOK {
            return ("Lid-closed mode isn't set up",
                    "A MacBook sleeps the moment its lid closes, even while Claude is working. Setup lets Ephedrine keep it awake with the lid shut. It asks for your password once.",
                    .setUp)
        }
        let works = whileClaude
            ? "Close the lid while Claude works and it keeps going, then the Mac sleeps a minute after it finishes."
            : "Lid sessions you start work. “While Claude is working” is off, so closing the lid mid-task lets the Mac sleep."
        if lowPowerSetupNeeded {
            return ("Lid-closed mode needs one more step",
                    works + " Low Power Mode needs the setup re-run. It adds Low Power Mode to what Ephedrine may switch and asks for your password once.",
                    .rerunSetup)
        }
        return ("Lid-closed mode is ready", works, nil)
    }

    /// The Claude Code pane's banner: retries, limit waits and cmux in one place.
    public static func claude(autoContinue: AutoContinueMode, autoResumeLimit: Bool, cmux: CmuxRowState)
        -> (headline: String, sentence: String) {
        var cmuxConnected = false
        if case .connected = cmux { cmuxConnected = true }
        let headline = autoContinue == .off
            ? "Not retrying API errors"
            : "Retrying API errors in " + (cmuxConnected ? "Terminal and cmux" : "Terminal")
        var parts: [String] = []
        if autoContinue != .off { parts.append("Types “continue” \(autoContinue.short).") }
        parts.append(autoResumeLimit
            ? "Waits out usage limits that reset within 6 hours, then continues."
            : "Doesn't continue after a usage limit.")
        switch cmux {
        case .connected(let n): parts.append(n == 1 ? "cmux is connected, 1 pane." : "cmux is connected, \(n) panes.")
        case .unreadablePassword: parts.append("Ephedrine can't read the saved cmux password.")
        case .badPassword: parts.append("cmux turned the saved password down.")
        case .noPassword: parts.append("cmux is open but has no socket password saved here.")
        default: break
        }
        return (headline, parts.joined(separator: " "))
    }

    /// The Away pane's banner.
    public static func away(isAway: Bool) -> (headline: String, sentence: String) {
        let tail = "Claude keeps working, then the Mac sleeps a minute after it's done. Move the mouse, type or open the lid to come back."
        return ("I'm leaving pauses your apps and turns the screen off",
                isAway ? "You're away now. " + tail : "Other apps are paused, so Claude has the Mac to itself. " + tail)
    }

    /// The About pane's banner. `latest` is the newer version, when there is one.
    public static func about(version: String, latest: String?, checksForUpdates: Bool) -> (headline: String, sentence: String) {
        if let latest {
            return ("Ephedrine \(version), \(latest) is out",
                    "Upgrade with “brew upgrade 3xyy/tap/ephedrine”, then “ephedrine setup”.")
        }
        return ("Ephedrine \(version)",
                checksForUpdates ? "You're up to date as of the last check. It looks again every 6 hours."
                                 : "Update checks are off. Turn them on under Updates to hear about new versions.")
    }

    /// The little status next to a card's title.
    public enum Tone: Equatable { case ok, warn, dim }

    public static func hotspotBadge(name: String, saved: SavedPasswordState) -> (text: String, tone: Tone) {
        if name.isEmpty { return ("Not set up", .dim) }
        switch saved {
        case .found: return ("Ready", .ok)
        case .missing, .unreadable: return ("Needs password", .warn)
        }
    }

    public static func cmuxBadge(_ state: CmuxRowState) -> (text: String, tone: Tone) {
        switch state {
        case .connected: return ("Connected", .ok)
        case .checking: return ("Checking", .dim)
        case .notInstalled: return ("Not installed", .dim)
        case .notRunning: return ("Not running", .dim)
        case .noPassword: return ("No password", .dim)
        case .unreadablePassword: return ("Needs password", .warn)
        case .badPassword: return ("Wrong password", .warn)
        case .failed: return ("Can't connect", .warn)
        }
    }

    /// "15 seconds", "1 minute", "10 minutes".
    private static func waitText(_ secs: Int) -> String {
        let s = max(0, secs)
        if s < 60 { return s == 1 ? "1 second" : "\(s) seconds" }
        let m = (s + 30) / 60
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}
