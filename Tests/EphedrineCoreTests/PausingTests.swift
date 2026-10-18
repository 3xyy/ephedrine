import Testing
import Foundation
@testable import EphedrineCore

@Test func alwaysPauseWins() {
    let slack = RunningAppInfo(pid: 50, bundleID: "com.tinyspeck.slackmacgap", name: "Slack", regular: true)
    #expect(!shouldPause(slack, keepRunning: ["com.tinyspeck.slackmacgap"], alwaysPause: [], selfPID: 9))
    #expect(shouldPause(slack, keepRunning: ["com.tinyspeck.slackmacgap"], alwaysPause: ["com.tinyspeck.slackmacgap"], selfPID: 9))
}
@Test func keepRunningRules() {
    let ij = RunningAppInfo(pid: 51, bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA", regular: true)
    let menuBar = RunningAppInfo(pid: 52, bundleID: "x.y", name: "Thing", regular: false)
    let arc = RunningAppInfo(pid: 53, bundleID: "z.z", name: "Arc", regular: true)
    let notes = RunningAppInfo(pid: 54, bundleID: "com.apple.Notes", name: "Notes", regular: true)
    #expect(!shouldPause(ij, keepRunning: [], alwaysPause: [], selfPID: 9))
    #expect(!shouldPause(menuBar, keepRunning: [], alwaysPause: [], selfPID: 9))
    #expect(!shouldPause(arc, keepRunning: [], alwaysPause: [], selfPID: 9))
    #expect(shouldPause(notes, keepRunning: [], alwaysPause: [], selfPID: 9))
    #expect(!shouldPause(RunningAppInfo(pid: 9, bundleID: "me", name: "Ephedrine", regular: true), keepRunning: [], alwaysPause: [], selfPID: 9))
}
@Test func descendantTree() {
    let procs = [ProcEntry(pid: 10, ppid: 1, start: 1), ProcEntry(pid: 11, ppid: 10, start: 2),
                 ProcEntry(pid: 12, ppid: 11, start: 3), ProcEntry(pid: 13, ppid: 1, start: 4)]
    #expect(descendants(of: [10], in: procs).map(\.pid).sorted() == [10, 11, 12])
}
@Test func resumeSkipsReusedPid() {
    let procs = [ProcEntry(pid: 11, ppid: 1, start: 99)]
    #expect(!stillSame(PausedProcess(pid: 11, start: 2), in: procs))
    #expect(stillSame(PausedProcess(pid: 11, start: 99), in: procs))
    #expect(!stillSame(PausedProcess(pid: 12, start: 3), in: procs))
}

// Always pause can't reach Ephedrine itself or launchd: a stopped Ephedrine
// never resumes anything, and its watchdog waits for it to exit.
@Test func alwaysPauseNeverSelfOrLaunchd() {
    let me = RunningAppInfo(pid: 9, bundleID: "io.github.3xyy.ephedrine", name: "Ephedrine", regular: true)
    let launchd = RunningAppInfo(pid: 1, bundleID: "x.launchd", name: "launchd", regular: true)
    #expect(!shouldPause(me, keepRunning: [], alwaysPause: ["io.github.3xyy.ephedrine"], selfPID: 9))
    #expect(!shouldPause(launchd, keepRunning: [], alwaysPause: ["x.launchd"], selfPID: 9))
    // A menu-bar app is only paused when it's on Always pause.
    let menuBar = RunningAppInfo(pid: 52, bundleID: "x.y", name: "Thing", regular: false)
    #expect(shouldPause(menuBar, keepRunning: [], alwaysPause: ["x.y"], selfPID: 9))
}

// Stop order is this list reversed (helpers first), resume order is this list
// (apps first), so the order matters, not only the set.
@Test func descendantOrderAndCycles() {
    let procs = [ProcEntry(pid: 10, ppid: 1, start: 1), ProcEntry(pid: 11, ppid: 10, start: 2),
                 ProcEntry(pid: 12, ppid: 11, start: 3), ProcEntry(pid: 20, ppid: 1, start: 4),
                 ProcEntry(pid: 21, ppid: 20, start: 5)]
    #expect(descendants(of: [10, 20], in: procs).map(\.pid) == [10, 20, 11, 21, 12])
    #expect(descendants(of: [10, 11], in: procs).map(\.pid) == [10, 11, 12])   // a root that's also a child, once
    #expect(descendants(of: [99], in: procs).isEmpty)                          // gone since the snapshot
    let loop = [ProcEntry(pid: 0, ppid: 0, start: 0), ProcEntry(pid: 30, ppid: 31, start: 6),
                ProcEntry(pid: 31, ppid: 30, start: 7)]
    #expect(descendants(of: [0], in: loop).map(\.pid) == [0])
    #expect(descendants(of: [30], in: loop).map(\.pid) == [30, 31])
}

// An empty snapshot means the process table couldn't be read: resume all of
// them rather than leave apps frozen.
@Test func resumeWithoutSnapshotResumesAll() {
    let paused = [PausedProcess(pid: 10, start: 1), PausedProcess(pid: 11, start: 2), PausedProcess(pid: 12, start: 3)]
    #expect(toResume(paused, in: []) == paused)
    let procs = [ProcEntry(pid: 12, ppid: 10, start: 3), ProcEntry(pid: 11, ppid: 10, start: 50), ProcEntry(pid: 10, ppid: 1, start: 1)]
    #expect(toResume(paused, in: procs) == [PausedProcess(pid: 10, start: 1), PausedProcess(pid: 12, start: 3)])
}

// A state file from before process records: resume its bare pids.
@Test func awayStateOldFormat() throws {
    let old = #"{"pids":[501,502],"brightness":0.5}"#.data(using: .utf8)!
    let s = try JSONDecoder().decode(AwayState.self, from: old)
    #expect(s.processes == nil && s.brightness == 0.5)
    #expect(s.pidsToResume(in: [ProcEntry(pid: 501, ppid: 1, start: 7)]) == [501, 502])
    #expect(s.pidsToResume(in: []) == [501, 502])
}

@Test func awayStateNewFormat() throws {
    let written = AwayState(processes: [PausedProcess(pid: 501, start: 7), PausedProcess(pid: 502, start: 8)],
                            pids: [501, 502], brightness: -1)
    let s = try JSONDecoder().decode(AwayState.self, from: JSONEncoder().encode(written))
    #expect(s == written)
    let procs = [ProcEntry(pid: 501, ppid: 1, start: 7), ProcEntry(pid: 502, ppid: 1, start: 99)]
    #expect(s.pidsToResume(in: procs) == [501])     // 502 is someone else now
    #expect(s.pidsToResume(in: []) == [501, 502])   // couldn't read the table: resume all
}

// The walk below a paused app stops at Ephedrine (its watchdog is its child)
// and at an app kept running in its own right, even one a paused app started.
// Helper apps (Electron's "Discord Helper" is a menu-bar app) are paused.
@Test func pausePlanSparesSelfAndKeptApps() {
    let apps = [RunningAppInfo(pid: 100, bundleID: "a.chat", name: "Chat", regular: true),
                RunningAppInfo(pid: 101, bundleID: "a.chat.helper", name: "Chat Helper", regular: false),
                RunningAppInfo(pid: 9, bundleID: "me", name: "Ephedrine", regular: false),   // a menu-bar app
                RunningAppInfo(pid: 200, bundleID: "com.apple.Terminal", name: "Terminal", regular: true),
                RunningAppInfo(pid: 220, bundleID: "org.test.cft", name: "Google Chrome for Testing", regular: true),
                RunningAppInfo(pid: 300, bundleID: "gone.app", name: "Gone", regular: true)]
    let procs = [ProcEntry(pid: 0, ppid: 0, start: 0), ProcEntry(pid: 1, ppid: 0, start: 0),
                 ProcEntry(pid: 100, ppid: 1, start: 1), ProcEntry(pid: 101, ppid: 100, start: 2),
                 ProcEntry(pid: 102, ppid: 101, start: 3),
                 ProcEntry(pid: 9, ppid: 100, start: 4), ProcEntry(pid: 10, ppid: 9, start: 5),
                 ProcEntry(pid: 200, ppid: 100, start: 6), ProcEntry(pid: 201, ppid: 200, start: 7),
                 ProcEntry(pid: 220, ppid: 100, start: 10), ProcEntry(pid: 221, ppid: 220, start: 11)]
    let plan = pausePlan(apps: apps, procs: procs, keepRunning: ["com.apple.Terminal"], alwaysPause: [], selfPID: 9)
    #expect(plan.apps.map(\.pid) == [100])   // Gone exited before the snapshot
    #expect(plan.processes == [ProcEntry(pid: 100, ppid: 1, start: 1), ProcEntry(pid: 101, ppid: 100, start: 2),
                               ProcEntry(pid: 102, ppid: 101, start: 3)])
    #expect(pausePlan(apps: apps, procs: [], keepRunning: [], alwaysPause: [], selfPID: 9).processes.isEmpty)
    let garbled = [ProcEntry(pid: 100, ppid: 1, start: 1), ProcEntry(pid: 1, ppid: 100, start: 0)]   // never launchd
    #expect(pausePlan(apps: apps, procs: garbled, keepRunning: [], alwaysPause: [], selfPID: 9).processes.map(\.pid) == [100])
}

// Always pause takes the app's helper apps too, even ones the keep-running
// rules name (Zoom's helpers match the us.zoom. prefix).
@Test func pausePlanAlwaysPauseTakesListedHelpers() {
    let apps = [RunningAppInfo(pid: 400, bundleID: "us.zoom.xos", name: "zoom.us", regular: true),
                RunningAppInfo(pid: 401, bundleID: "us.zoom.CptHost", name: "CptHost", regular: false)]
    let procs = [ProcEntry(pid: 400, ppid: 1, start: 1), ProcEntry(pid: 401, ppid: 400, start: 2)]
    let keep: Set<String> = ["us.zoom.xos"]
    #expect(pausePlan(apps: apps, procs: procs, keepRunning: keep, alwaysPause: [], selfPID: 9).processes.isEmpty)
    #expect(pausePlan(apps: apps, procs: procs, keepRunning: keep, alwaysPause: ["us.zoom.xos"], selfPID: 9).processes.map(\.pid) == [400, 401])
}
