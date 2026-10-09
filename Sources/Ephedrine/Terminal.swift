import Foundation
import EphedrineCore

// ── Reading & typing into Terminal.app (auto-continue / limit-resume) ──

struct AutoContinueState { var attempts: Int; var nextTryAt: Date; var lastErrorAt: Date }

/// One tab's usage-limit wall, from first sighting until the limit text
/// leaves the screen.
struct LimitEpisode {
    var menuHandled = false     // answered (or deliberately skipped) Claude Code's limit menu
    var claudeResumes = false   // Claude Code continues by itself at reset, so type nothing
    var resumeAt: Date?         // reset + 1 min; set only when within limitWaitCap
    var noted = false           // logged why we're not waiting
    var resumed = false         // reset passed and was handled
}

/// Read every Terminal.app tab's visible text, keyed by tty. Tabs are joined
/// with ASCII unit/record separators (chars 31/30): control characters can't
/// appear in a tab's visible contents, so the delimiters can't collide with
/// on-screen text (unlike a printable marker string).
func terminalTabsSnapshot() -> (tabs: [(tty: String, text: String)], err: String) {
    let script = """
    set d to character id 31
    set c to character id 30
    set out to ""
    tell application "Terminal"
      set n to count windows
      repeat with i from 1 to n
        try
          set tc to count tabs of window i
          repeat with j from 1 to tc
            try
              set out to out & d & (tty of tab j of window i) & c & (contents of tab j of window i)
            end try
          end repeat
        end try
      end repeat
    end tell
    return out
    """
    let (out, err) = runOsascript(script)
    var res: [(String, String)] = []
    for chunk in out.components(separatedBy: "\u{1F}") where chunk.contains("\u{1E}") {
        let parts = chunk.components(separatedBy: "\u{1E}")
        if parts.count >= 2 {
            res.append((parts[0].trimmingCharacters(in: .whitespacesAndNewlines), parts[1]))
        }
    }
    return (res, err)
}

/// Type text + Return into the Terminal tab with this tty (no focus needed).
func sendToTerminal(_ text: String, tty: String) {
    let script = """
    tell application "Terminal"
      set n to count windows
      repeat with i from 1 to n
        try
          set tc to count tabs of window i
          repeat with j from 1 to tc
            try
              if (tty of tab j of window i) is \(appleScriptQuoted(tty)) then do script \(appleScriptQuoted(text)) in tab j of window i
            end try
          end repeat
        end try
      end repeat
    end tell
    """
    _ = runOsascript(script)
}

func sendContinue(tty: String) { sendToTerminal("continue", tty: tty) }
