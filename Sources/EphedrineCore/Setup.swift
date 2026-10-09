import Foundation

// Pure pieces of the first-run setup screen.

/// What macOS says about controlling another app (Automation), from
/// AEDeterminePermissionToAutomateTarget's result.
public enum AutomationPermission: Equatable {
    case granted, denied, notAsked, appNotRunning, unknown
}

public func automationPermission(_ status: Int32) -> AutomationPermission {
    switch status {
    case 0:     return .granted
    case -1743: return .denied          // errAEEventNotPermitted
    case -1744: return .notAsked        // errAEEventWouldRequireUserConsent
    case -600:  return .appNotRunning   // procNotFound
    default:    return .unknown
    }
}

/// Whether ~/.claude/settings.json runs our hook script (`ephedrine setup` adds it).
public func claudeHooksInstalled(settingsJSON: String?) -> Bool {
    settingsJSON?.contains("/.claude/ephedrine/hook.sh") ?? false
}
