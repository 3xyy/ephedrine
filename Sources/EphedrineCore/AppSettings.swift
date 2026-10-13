import Foundation
import Combine

/// Every persisted preference. Each change is saved to UserDefaults right away
/// and reported through `onChange` with its key. Keys and defaults match the
/// pre-window app so existing preferences carry over. Main thread only.
public final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    /// Called after a setting changes, with its UserDefaults key.
    public var onChange: ((String) -> Void)?

    @Published public var enabled: Bool { didSet { save(enabled, "enabled") } }
    @Published public var finishMode: FinishMode { didSet { save(finishMode.rawValue, "finishMode") } }
    @Published public var gracePeriod: Double { didSet { save(gracePeriod, "gracePeriod") } }
    @Published public var graceUseSystem: Bool { didSet { save(graceUseSystem, "graceUseSystem") } }
    @Published public var powerMode: PowerMode { didSet { save(powerMode.rawValue, "powerMode") } }
    @Published public var detectors: Set<String> { didSet { save(detectors.sorted(), "detectors") } }
    @Published public var usageAlert: Int { didSet { save(usageAlert, "usageAlert") } }
    @Published public var allowDisplaySleep: Bool { didSet { save(allowDisplaySleep, "allowDisplaySleep") } }
    @Published public var autoContinueMode: AutoContinueMode { didSet { save(autoContinueMode.rawValue, "autoContinueMode") } }
    @Published public var autoResumeLimit: Bool { didSet { save(autoResumeLimit, "autoResumeLimit") } }
    @Published public var keepAwakeClaudeWorking: Bool { didSet { save(keepAwakeClaudeWorking, "keepAwakeClaudeWorking") } }
    @Published public var lidWhileClaude: Bool { didSet { save(lidWhileClaude, "lidWhileClaude") } }
    @Published public var lidBatteryFloor: Int { didSet { save(lidBatteryFloor, "lidBatteryFloor") } }
    @Published public var lidPauseApps: Bool { didSet { save(lidPauseApps, "lidPauseApps") } }
    @Published public var lidLockOnClose: Bool { didSet { save(lidLockOnClose, "lidLockOnClose") } }
    @Published public var lidHeatLimit: LidHeatLimit { didSet { save(lidHeatLimit.rawValue, "lidHeatLimit") } }
    /// Claude-driven lid mode stops once the lid's been shut this many hours; 0 = never.
    @Published public var lidClosedCapHours: Int { didSet { save(lidClosedCapHours, "lidClosedCapHours") } }
    /// Wake fully from lid-shut naps so `claude remote-control` can pick up messages (RemoteCheckIn).
    @Published public var lidRemoteCheckIn: Bool { didSet { save(lidRemoteCheckIn, "lidRemoteCheckIn") } }
    /// The first-run setup screen was finished (or skipped).
    @Published public var setupDone: Bool { didSet { save(setupDone, "setupDone") } }
    @Published public var menuBarIconStyle: MenuBarIconStyle { didSet { save(menuBarIconStyle.rawValue, "menuBarIconStyle") } }
    /// User additions to the apps "I'm leaving" never pauses (bundle ids).
    @Published public var awayKeepRunning: [String] { didSet { save(awayKeepRunning, "awayKeepRunning") } }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        enabled = bool("enabled", true)
        finishMode = defaults.string(forKey: "finishMode").flatMap(FinishMode.init(rawValue:)) ?? .sleepIfIdle
        gracePeriod = defaults.object(forKey: "gracePeriod") as? Double ?? 120
        graceUseSystem = bool("graceUseSystem", true)
        powerMode = defaults.string(forKey: "powerMode").flatMap(PowerMode.init(rawValue:)) ?? .always
        detectors = Set(defaults.stringArray(forKey: "detectors") ?? [])
        usageAlert = defaults.object(forKey: "usageAlert") as? Int ?? 80
        allowDisplaySleep = bool("allowDisplaySleep", false)
        autoContinueMode = defaults.string(forKey: "autoContinueMode").flatMap(AutoContinueMode.init(rawValue:))
            ?? (bool("autoContinue", false) ? .backoff : .off)   // pre-2026 on/off setting
        autoResumeLimit = bool("autoResumeLimit", false)
        keepAwakeClaudeWorking = bool("keepAwakeClaudeWorking", false)
        lidWhileClaude = bool("lidWhileClaude", true)
        lidBatteryFloor = defaults.object(forKey: "lidBatteryFloor") as? Int ?? 20
        lidPauseApps = bool("lidPauseApps", true)
        lidLockOnClose = bool("lidLockOnClose", true)
        lidHeatLimit = defaults.string(forKey: "lidHeatLimit").flatMap(LidHeatLimit.init(rawValue:)) ?? .hot
        lidClosedCapHours = defaults.object(forKey: "lidClosedCapHours") as? Int ?? 0
        lidRemoteCheckIn = bool("lidRemoteCheckIn", false)
        setupDone = bool("setupDone", false)
        menuBarIconStyle = defaults.string(forKey: "menuBarIconStyle").flatMap(MenuBarIconStyle.init(rawValue:)) ?? .mono
        // Drop duplicates (the old `defaults write … -array-add` tip could add some), keep order.
        var seen = Set<String>()
        awayKeepRunning = (defaults.stringArray(forKey: "awayKeepRunning") ?? []).filter { seen.insert($0).inserted }
    }

    public func addKeepRunning(_ bundleID: String) {
        guard !bundleID.isEmpty, !awayKeepRunning.contains(bundleID) else { return }
        awayKeepRunning.append(bundleID)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?(key)
    }
}
