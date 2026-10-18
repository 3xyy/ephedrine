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

    /// "15 seconds", "1 minute", "10 minutes".
    private static func waitText(_ secs: Int) -> String {
        let s = max(0, secs)
        if s < 60 { return s == 1 ? "1 second" : "\(s) seconds" }
        let m = (s + 30) / 60
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}
