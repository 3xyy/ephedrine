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

/// The Claude Code events `ephedrine setup` hooks (scripts/ephedrine, edit_hooks).
public let claudeHookEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd",
                               "SubagentStart", "SubagentStop"]

/// Whether ~/.claude/settings.json runs our hook script on every event in
/// claudeHookEvents. A setup from before 1.2.2 has no subagent events, so it
/// counts as missing and the setup screen offers the command again.
public func claudeHooksInstalled(settingsJSON: String?) -> Bool {
    guard let data = settingsJSON?.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = root["hooks"] as? [String: Any] else { return false }
    return claudeHookEvents.allSatisfy { event in
        (hooks[event] as? [[String: Any]] ?? []).contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains {
                ($0["command"] as? String)?.contains("/.claude/ephedrine/hook.sh") == true
            }
        }
    }
}
