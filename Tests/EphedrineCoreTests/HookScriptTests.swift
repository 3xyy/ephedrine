import Testing
import Foundation

// Runs scripts/hook.sh as Claude Code would: event JSON on stdin, HOME pointed
// at a scratch folder, then looks at the session markers it leaves.

private let hookScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("scripts/hook.sh").path

private func scratchHome() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func hook(_ home: String, _ args: [String], _ json: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [hookScript] + args
    p.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
    let input = Pipe()
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    input.fileHandleForWriting.write(Data(json.utf8))
    try? input.fileHandleForWriting.close()
    p.waitUntilExit()
}

private func markers(_ home: String) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: home + "/.claude/ephedrine/sessions")) ?? [])
}

@Test func theMainTurnEndingLeavesARunningBackgroundAgentMarked() {
    // 2026-10-20 13:42: the main turn's Stop cleared every marker, a background
    // agent was still generating, and Ephedrine slept the Mac with the lid shut.
    let home = scratchHome()
    hook(home, ["busy", "7200"], #"{"session_id":"s1","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"general-purpose"}"#)
    hook(home, ["busy", "7200"], #"{"session_id":"s1","hook_event_name":"PreToolUse","tool_use_id":"t1"}"#)
    #expect(markers(home) == ["s1~agent-a1", "s1~t1"])
    hook(home, ["idle"], #"{"session_id":"s1","hook_event_name":"Stop"}"#)
    #expect(markers(home) == ["s1~agent-a1"])
    // The agent finishes: the session stays busy a short lease, as after a tool call.
    hook(home, ["busy", "300"], #"{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"a1"}"#)
    #expect(markers(home) == ["s1"])
}

@Test func endingTheSessionClearsItsAgentsToo() {
    let home = scratchHome()
    hook(home, ["busy", "7200"], #"{"session_id":"s1","hook_event_name":"SubagentStart","agent_id":"a1"}"#)
    hook(home, ["busy", "7200"], #"{"session_id":"s2","hook_event_name":"SubagentStart","agent_id":"a2"}"#)
    hook(home, ["idle"], #"{"session_id":"s1","hook_event_name":"SessionEnd"}"#)
    #expect(markers(home) == ["s2~agent-a2"])
}

@Test func anAgentMarkerHoldsALease() {
    let home = scratchHome()
    let before = Date().timeIntervalSince1970
    hook(home, ["busy", "7200"], #"{"session_id":"s1","hook_event_name":"SubagentStart","agent_id":"a1"}"#)
    let text = (try? String(contentsOfFile: home + "/.claude/ephedrine/sessions/s1~agent-a1", encoding: .utf8)) ?? ""
    let expiry = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    #expect(expiry >= before + 7200 - 1 && expiry <= before + 7200 + 5)
}
