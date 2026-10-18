import Foundation
import Testing
@testable import EphedrineCore

// ── cmux ──

// `cmux --json --id-format uuids tree --all`, in the shape cmux 0.65.2 builds
// it (system.tree payload, refs dropped by --id-format uuids): two windows,
// three terminal surfaces, plus a browser surface that must be left out.
private let cmuxTreeSample = """
{
  "active" : {
    "pane_id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B001",
    "surface_id" : "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F01",
    "window_id" : "0B9F6A3E-6C1D-4D51-9E0A-2A61B7C1D001",
    "workspace_id" : "C3E1A2B4-5D6F-4A1B-8C9D-0E1F2A3B4C01"
  },
  "caller" : null,
  "windows" : [
    {
      "active" : true,
      "current" : true,
      "id" : "0B9F6A3E-6C1D-4D51-9E0A-2A61B7C1D001",
      "index" : 0,
      "key" : true,
      "selected_workspace_id" : "C3E1A2B4-5D6F-4A1B-8C9D-0E1F2A3B4C01",
      "visible" : true,
      "workspace_count" : 2,
      "workspaces" : [
        {
          "active" : true,
          "description" : null,
          "id" : "C3E1A2B4-5D6F-4A1B-8C9D-0E1F2A3B4C01",
          "index" : 0,
          "layout" : { "pane" : { "id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B001" } },
          "panes" : [
            {
              "active" : true,
              "focused" : true,
              "id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B001",
              "index" : 0,
              "selected_surface_id" : "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F01",
              "surface_count" : 2,
              "surface_ids" : [ "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F01", "9A8B7C6D-5E4F-4A3B-9C2D-1E0F9A8B7C01" ],
              "surfaces" : [
                {
                  "active" : true,
                  "focused" : true,
                  "id" : "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F01",
                  "index" : 0,
                  "index_in_pane" : 0,
                  "pane_id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B001",
                  "render_health" : "healthy",
                  "selected" : true,
                  "selected_in_pane" : true,
                  "title" : "Claude Code",
                  "tty" : "ttys004",
                  "type" : "terminal",
                  "url" : null
                },
                {
                  "active" : false,
                  "focused" : false,
                  "id" : "9A8B7C6D-5E4F-4A3B-9C2D-1E0F9A8B7C01",
                  "index" : 1,
                  "index_in_pane" : 1,
                  "pane_id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B001",
                  "render_health" : null,
                  "selected" : false,
                  "selected_in_pane" : false,
                  "title" : "Docs",
                  "tty" : null,
                  "type" : "browser",
                  "url" : "https://cmux.com/docs/api"
                }
              ]
            }
          ],
          "pinned" : false,
          "selected" : true,
          "title" : "claudesleep"
        },
        {
          "active" : false,
          "description" : null,
          "id" : "C3E1A2B4-5D6F-4A1B-8C9D-0E1F2A3B4C02",
          "index" : 1,
          "layout" : null,
          "panes" : [
            {
              "active" : false,
              "focused" : true,
              "id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B002",
              "index" : 0,
              "surface_count" : 1,
              "surfaces" : [
                {
                  "id" : "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F02",
                  "index" : 0,
                  "pane_id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B002",
                  "selected" : true,
                  "title" : "zsh",
                  "tty" : "ttys005",
                  "type" : "terminal",
                  "url" : null
                }
              ]
            }
          ],
          "pinned" : false,
          "selected" : false,
          "title" : "notes"
        }
      ]
    },
    {
      "active" : false,
      "current" : false,
      "id" : "0B9F6A3E-6C1D-4D51-9E0A-2A61B7C1D002",
      "index" : 1,
      "key" : false,
      "visible" : true,
      "workspace_count" : 1,
      "workspaces" : [
        {
          "id" : "C3E1A2B4-5D6F-4A1B-8C9D-0E1F2A3B4C03",
          "index" : 0,
          "panes" : [
            {
              "id" : "6A1B6E43-2F5C-4B7E-9C51-0D7A41C2B003",
              "index" : 0,
              "surfaces" : [
                {
                  "id" : "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F03",
                  "index" : 0,
                  "selected" : true,
                  "title" : "  ✳ Fix tests ",
                  "tty" : "ttys006",
                  "type" : "terminal",
                  "url" : null
                }
              ]
            }
          ],
          "selected" : true,
          "title" : "api"
        }
      ]
    }
  ]
}
"""

@Test func cmuxSurfacesFromTree() {
    #expect(parseCmuxSurfaces(cmuxTreeSample) == [
        CmuxSurface(id: "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F01", label: "claudesleep › Claude Code"),
        CmuxSurface(id: "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F02", label: "notes › zsh"),
        CmuxSurface(id: "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F03", label: "api › ✳ Fix tests"),
    ])
}

@Test func cmuxSurfacesEmptyAndGarbage() {
    #expect(parseCmuxSurfaces("").isEmpty)
    #expect(parseCmuxSurfaces("{\"active\":null,\"caller\":null,\"windows\":[]}").isEmpty)
    #expect(parseCmuxSurfaces("No windows").isEmpty)                                  // the text form
    #expect(parseCmuxSurfaces("window window:1 [current] ◀ active\n└── workspace workspace:1").isEmpty)
    #expect(parseCmuxSurfaces("[1, 2, 3]").isEmpty)
    #expect(parseCmuxSurfaces("{\"windows\": \"nope\"}").isEmpty)
    #expect(parseCmuxSurfaces("{\"windows\": [{\"workspaces\": [{\"panes\": [{\"surfaces\": [42, null]}]}]}]}").isEmpty)
    #expect(parseCmuxSurfaces(String(cmuxTreeSample.prefix(900))).isEmpty)           // cut off mid-way
}

/// Only a UUID ever names a surface to type into: refs ("surface:3") and
/// indexes renumber as tabs open and close.
@Test func cmuxSurfacesNeedUUIDs() {
    let refs = """
    {"windows":[{"workspaces":[{"title":"w","panes":[{"surfaces":[
      {"ref":"surface:1","type":"terminal","title":"a"},
      {"id":"surface:2","type":"terminal","title":"b"},
      {"id":"3","type":"terminal","title":"c"},
      {"id":"","type":"terminal","title":"d"},
      {"id":"5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F09","type":"terminal","title":""},
      {"id":"5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F09","type":"terminal","title":"again"}
    ]}]}]}]}
    """
    // The duplicate (a surface listed twice) is kept once; no titles leaves just the workspace.
    #expect(parseCmuxSurfaces(refs) == [CmuxSurface(id: "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F09", label: "w")])
}

@Test func cmuxAccessStates() {
    #expect(cmuxAccess(exitCode: 0, output: cmuxTreeSample) == .ok)
    // From a process cmux didn't start (the owner's Mac, 2026-10-18, exit 1;
    // the same text was also seen with exit 0).
    let denied = "Error: ERROR: Access denied - only processes started inside cmux can connect"
    #expect(cmuxAccess(exitCode: 1, output: denied) == .denied)
    #expect(cmuxAccess(exitCode: 0, output: denied) == .denied)
    // Password mode, no password sent (v2 and v1 replies), or none set in cmux.
    #expect(cmuxAccess(exitCode: 1, output: "Error: auth_required: Authentication required. Send auth <password> first.")
            == .needsPassword)
    #expect(cmuxAccess(exitCode: 1, output: "Error: ERROR: Authentication required — send auth <password> first")
            == .needsPassword)
    #expect(cmuxAccess(exitCode: 1, output: "Error: ERROR: Password mode is enabled but no socket password is configured in Settings.")
            == .needsPassword)
    // Wrong password.
    #expect(cmuxAccess(exitCode: 1, output: "Error: ERROR: Invalid password") == .badPassword)
    #expect(cmuxAccess(exitCode: 1, output: "Error: auth_failed: Invalid password") == .badPassword)
    // The CLI couldn't be started.
    #expect(cmuxAccess(exitCode: cmuxLaunchFailed, output: "") == .notInstalled)
    // Anything else that failed (socket off, cmux quitting) carries cmux's own line, not the Automation steps.
    #expect(cmuxAccess(exitCode: 1, output: "Error: Socket not found at /Users/me/.local/state/cmux/cmux.sock")
            == .failed("Socket not found at /Users/me/.local/state/cmux/cmux.sock"))
    #expect(cmuxAccess(exitCode: 1, output: "Error: ERROR: overloaded retry_after_ms=200 reason=pool_saturated\nmore")
            == .failed("overloaded retry_after_ms=200 reason=pool_saturated"))
    #expect(cmuxAccess(exitCode: 1, output: "") == .failed("exit 1"))
    #expect(cmuxAccess(exitCode: 2, output: "{\"windows\": []}") == .failed("exit 2"))
}

/// Error text counts only on the CLI's own "Error:" lines, so a pane or
/// workspace titled "Invalid password" doesn't turn a good listing into a failure.
@Test func cmuxAccessIgnoresTitles() {
    let titled = "{\"windows\":[{\"workspaces\":[{\"title\" : \"Error: Invalid password\"}]}]}\n  \"title\" : \"Access denied\""
    #expect(cmuxAccess(exitCode: 0, output: titled) == .ok)
}

@Test func cmuxCommandArgs() {
    let id = "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F01"
    #expect(cmuxListArgs == ["--json", "--id-format", "uuids", "tree", "--all"])
    #expect(cmuxReadArgs(id) == ["read-screen", "--surface", id])
    #expect(cmuxLiveTailArgs(id) == ["read-screen", "--surface", id, "--lines", "100"])
    #expect(cmuxInputStateArgs(id) == ["rpc", "surface.input_state", "{\"surface_id\":\"\(id)\"}"])
    // Never "{}": cmux would answer for whatever surface is focused.
    #expect(cmuxInputStateArgs("surface:1") == nil)
    #expect(cmuxInputStateArgs("") == nil)
    #expect(cmuxInputStateArgs("5D2F7A10\",\"x\":\"y") == nil)
    // The text goes after "--", so it can never be read as a flag.
    #expect(cmuxSendArgs(id, "continue", force: false) == ["send", "--surface", id, "--", "continue"])
    #expect(cmuxSendArgs(id, "1", force: true) == ["send", "--surface", id, "--force", "--", "1"])
    #expect(cmuxEnterArgs(id, force: false) == ["send-key", "--surface", id, "enter"])
    #expect(cmuxEnterArgs(id, force: true) == ["send-key", "--surface", id, "--force", "enter"])
}

@Test func cmuxStatusLines() {
    let notConnected = "Not connected: in cmux, open Settings › Automation, choose Password and set one, then enter it here"
    func line(installed: Bool = true, running: Bool = true, password: CmuxSavedPassword = .saved,
              _ access: CmuxAccess?, panes: Int = 0) -> String {
        cmuxStatusText(installed: installed, running: running, password: password, access: access, panes: panes)
    }
    #expect(line(installed: false, running: false, .ok, panes: 2) == "Not installed")
    #expect(line(password: .none, nil) == notConnected)
    #expect(line(running: false, password: .none, nil) == notConnected)
    #expect(line(password: .unreadable(-25293), .ok, panes: 2) == "Couldn't read the saved password (OSStatus -25293)")
    #expect(line(running: false, .ok, panes: 2) == "Password saved. Connects when cmux is open")
    #expect(line(nil) == "Checking…")
    #expect(line(.denied) == notConnected)
    #expect(line(.needsPassword) == notConnected)
    #expect(line(.badPassword) == "Password not accepted")
    #expect(line(.notInstalled) == "Not installed")
    #expect(line(.failed("Socket not found at /tmp/cmux.sock")) == "Not connected: Socket not found at /tmp/cmux.sock")
    #expect(line(.ok, panes: 3) == "Connected, 3 panes")
    #expect(line(.ok, panes: 1) == "Connected, 1 pane")
    #expect(line(.ok, panes: 0) == "Connected, 0 panes")
}

// `cmux rpc surface.input_state '{"surface_id":…}'`: cmux 0.65.2 prints the
// result with sorted keys, pretty-printed (TerminalController+SurfaceInputState).
private func inputStateJSON(_ state: String, agent: Bool = true, terminal: Bool = true, draft: Int? = nil) -> String {
    """
    {
      "agent" : \(agent),
      "blocks_typing" : \(agent && (state == "draft" || state == "dialog")),\(draft.map { "\n  \"draft_length\" : \($0)," } ?? "")
      "lifecycle" : "idle",
      "state" : "\(state)",
      "surface_id" : "5D2F7A10-8E3B-4C6D-A1F2-3B4C5D6E7F01",
      "terminal" : \(terminal),
      "waiting_on_human" : false,
      "workspace_id" : "C3E1A2B4-5D6F-4A1B-8C9D-0E1F2A3B4C01"
    }
    """
}

@Test func cmuxInputStateParsing() {
    #expect(parseCmuxInputState(inputStateJSON("empty")) == CmuxInputState(prompt: .empty, agent: true, terminal: true))
    #expect(parseCmuxInputState(inputStateJSON("draft", draft: 12)) == CmuxInputState(prompt: .draft, agent: true, terminal: true))
    #expect(parseCmuxInputState(inputStateJSON("dialog")) == CmuxInputState(prompt: .dialog, agent: true, terminal: true))
    #expect(parseCmuxInputState(inputStateJSON("unknown", agent: false)) == CmuxInputState(prompt: .unknown, agent: false, terminal: true))
    // A browser surface: no "blocks_typing", terminal false.
    #expect(parseCmuxInputState("{\"agent\":false,\"lifecycle\":\"unknown\",\"state\":\"unknown\",\"terminal\":false}")
            == CmuxInputState(prompt: .unknown, agent: false, terminal: false))
    // A state this version doesn't know reads as unknown; missing flags read as false.
    #expect(parseCmuxInputState("{\"state\":\"thinking\"}") == CmuxInputState(prompt: .unknown, agent: false, terminal: false))
    #expect(parseCmuxInputState("") == nil)
    #expect(parseCmuxInputState("{}") == nil)
    #expect(parseCmuxInputState("{\"state\": 3}") == nil)
    #expect(parseCmuxInputState("Error: not_found: Surface not found") == nil)
    #expect(parseCmuxInputState("[\"empty\"]") == nil)
}

@Test func cmuxTypeDecisions() {
    func st(_ p: CmuxInputState.Prompt, agent: Bool = true, terminal: Bool = true) -> CmuxInputState {
        CmuxInputState(prompt: p, agent: agent, terminal: terminal)
    }
    // "continue": only into an empty Claude Code prompt, never forced.
    #expect(cmuxTypeDecision(state: st(.empty), purpose: .continuePrompt) == .send)
    #expect(cmuxTypeDecision(state: st(.draft), purpose: .continuePrompt) == .skip("someone is typing in its prompt"))
    #expect(cmuxTypeDecision(state: st(.dialog), purpose: .continuePrompt) == .skip("a question or menu is open"))
    #expect(cmuxTypeDecision(state: st(.unknown), purpose: .continuePrompt) == .skip("no Claude Code prompt on its live screen"))
    #expect(cmuxTypeDecision(state: nil, purpose: .continuePrompt) == .skip("couldn't read what its live screen shows"))
    // The limit-menu answer: forced, and only while a menu or question is open.
    #expect(cmuxTypeDecision(state: st(.dialog), purpose: .limitMenuAnswer) == .force)
    #expect(cmuxTypeDecision(state: st(.empty), purpose: .limitMenuAnswer) == .skip("no menu is open on its live screen"))
    #expect(cmuxTypeDecision(state: st(.draft), purpose: .limitMenuAnswer) == .skip("someone is typing in its prompt"))
    #expect(cmuxTypeDecision(state: st(.unknown), purpose: .limitMenuAnswer) == .skip("no Claude Code prompt on its live screen"))
    #expect(cmuxTypeDecision(state: nil, purpose: .limitMenuAnswer) == .skip("couldn't read what its live screen shows"))
    // No agent reported, or not a terminal: never typed into, whatever the screen shows.
    for p in [CmuxInputState.Prompt.empty, .draft, .dialog, .unknown] {
        for purpose in [CmuxTypePurpose.continuePrompt, .limitMenuAnswer] {
            #expect(cmuxTypeDecision(state: st(p, agent: false), purpose: purpose) == .skip("cmux doesn't report Claude Code running in it"))
            #expect(cmuxTypeDecision(state: st(p, terminal: false), purpose: purpose) == .skip("it isn't a terminal"))
        }
    }
}

/// Force switches off cmux's own draft and dialog guard, so it is returned for
/// one combination only: a menu answer while a menu or question is open.
@Test func cmuxForceOnlyForMenuDialog() {
    var forced: [String] = []
    for p in [CmuxInputState.Prompt.empty, .draft, .dialog, .unknown] {
        for agent in [true, false] {
            for terminal in [true, false] {
                for purpose in [CmuxTypePurpose.continuePrompt, .limitMenuAnswer] {
                    let s = CmuxInputState(prompt: p, agent: agent, terminal: terminal)
                    if cmuxTypeDecision(state: s, purpose: purpose) == .force { forced.append("\(purpose) \(p) \(agent) \(terminal)") }
                }
            }
        }
    }
    for purpose in [CmuxTypePurpose.continuePrompt, .limitMenuAnswer] {
        if cmuxTypeDecision(state: nil, purpose: purpose) == .force { forced.append("\(purpose) nil") }
    }
    #expect(forced == ["limitMenuAnswer dialog true true"])
}

// ── The live tail: the bottom of a cmux pane, read right before typing ──

private let limitHeader = "You've hit your session limit · resets 3am (America/Los_Angeles)"
private let permissionDialog = """
╭───────────────────────────────────────────╮
│ Bash command                              │
│   rm -rf build                            │
│ Do you want to proceed?                   │
│ ❯ 1. Yes                                  │
│   2. No, and tell Claude what to do       │
╰───────────────────────────────────────────╯
"""
private let limitMenuLive = """
\(limitHeader)

❯ 1. Stop and wait for limit to reset
  2. Upgrade your plan

Enter to confirm · Esc to cancel
"""
private let idlePrompt = """
⏺ Done. The tests pass.

────────────────────────────────────────
❯\u{00A0}
────────────────────────────────────────
  ? for shortcuts
"""
private let errorAtPrompt = """
⏺ Reading the file
⏺ API Error: 529 {"type":"error","error":{"type":"overloaded_error"}}

────────────────────────────────────────
❯\u{00A0}
────────────────────────────────────────
  ? for shortcuts
"""

@Test func liveTailLimitMenu() {
    let wait = LimitChoice.waitForReset("1")
    // The limit menu at the bottom: proceed, even with blank rows under it.
    #expect(cmuxLiveTailShows(.limitMenu(wait), in: limitMenuLive))
    #expect(cmuxLiveTailShows(.limitMenu(wait), in: limitMenuLive + String(repeating: "\n", count: 40)))
    #expect(cmuxLiveTailShows(.limitMenu(.claudeAutoContinue("2")), in: """
        \(limitHeader)

        ❯ 1. Stop and wait for limit to reset
          2. Wait here, then continue automatically when the limit resets
        """))
    // A different option than the scan chose: skip.
    #expect(!cmuxLiveTailShows(.limitMenu(.waitForReset("2")), in: limitMenuLive))
    // A live permission dialog at the bottom: skip, alone or under an old limit-menu frame.
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: permissionDialog))
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: limitMenuLive + "\n" + permissionDialog))
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: limitHeader + "\n" + permissionDialog))
    // An idle prompt, or the limit text with no menu: skip.
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: idlePrompt))
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: limitHeader + "\n" + idlePrompt))
    // Below the limit menu, a second menu with its own cursor (numbers that don't repeat),
    // a numbered list without a cursor that repeats its numbers, or a question with no options: skip.
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: limitMenuLive + "\nAllow this tool?\n❯ 3. Yes\n  4. No"))
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: limitMenuLive + "\nAllow this tool?\n  1. Yes\n  2. No"))
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: limitMenuLive
                               + "\nWelcome back\nYour session was restored.\nSome settings changed.\nPress enter to continue"))
    // The limit menu drawn inside a box: still the limit menu.
    #expect(cmuxLiveTailShows(.limitMenu(wait), in: """
        \(limitHeader)
        ╭──────────────────────────────────────────╮
        │ ❯ 1. Stop and wait for limit to reset    │
        │   2. Upgrade your plan                   │
        ╰──────────────────────────────────────────╯
        """))
    // The menu with no limit text above it (some other "wait" menu): skip.
    #expect(!cmuxLiveTailShows(.limitMenu(wait), in: "❯ 1. Stop and wait for limit to reset\n  2. Upgrade your plan"))
    #expect(cmuxLiveTrigger(.limitMenu(wait)).purpose == .limitMenuAnswer)
    #expect(CmuxLiveTrigger.limitMenu(wait).missing == "menu on screen isn't the usage-limit menu")
}

@Test func liveTailContinue() {
    // An unanswered API error above an empty prompt: proceed.
    #expect(cmuxLiveTailShows(.apiError, in: errorAtPrompt))
    #expect(cmuxLiveTailShows(.apiError, in: errorAtPrompt + String(repeating: "\n", count: 40)))
    // The live bottom is an idle prompt (the error was only in a scrolled view), or a permission dialog: skip.
    #expect(!cmuxLiveTailShows(.apiError, in: idlePrompt))
    #expect(!cmuxLiveTailShows(.apiError, in: errorAtPrompt + "\n" + permissionDialog))
    // A boxed question whose cursor isn't ❯ (so the shared detectors don't see a prompt or a menu): skip.
    #expect(!cmuxLiveTailShows(.apiError, in: errorAtPrompt + "\n│ Allow this?   │\n│ › 1. Yes      │\n│   2. No       │"))
    #expect(!cmuxLiveTailShows(.apiError, in: ""))
    // After a reset: the limit text and a plain prompt below it.
    #expect(cmuxLiveTailShows(.limitReset, in: limitHeader + "\n" + idlePrompt))
    #expect(!cmuxLiveTailShows(.limitReset, in: idlePrompt))            // limit text gone: someone moved on
    #expect(!cmuxLiveTailShows(.limitReset, in: limitMenuLive))         // the menu is still open
    #expect(!cmuxLiveTailShows(.limitReset, in: limitHeader + "\n" + permissionDialog))
    #expect(cmuxLiveTrigger(.apiError).purpose == .continuePrompt)
    #expect(cmuxLiveTrigger(.limitReset).purpose == .continuePrompt)
}

private func cmuxLiveTrigger(_ t: CmuxLiveTrigger) -> CmuxLiveTrigger { t }


// Final review R51: the scan's read can be a view the owner scrolled to, so a
// cmux pane counts as Claude working only once its live tail shows it too,
// read at most once a minute per pane.
private let workingAtPrompt = """
✻ Crunching… (12s · ↓ 1.2k tokens · esc to interrupt)

────────────────────────────────────────
❯\u{00A0}
────────────────────────────────────────
  ? for shortcuts
"""

@Test func liveTailWorkingSkipsBlankRows() {
    #expect(cmuxLiveTailWorking(workingAtPrompt))
    // A screen that isn't full: blank rows under the cursor fill the bottom of the read.
    #expect(cmuxLiveTailWorking(workingAtPrompt + String(repeating: "\n", count: 40)))
    #expect(cmuxLiveTailWorking(workingAtPrompt + String(repeating: "\n   ", count: 40)))
    #expect(!cmuxLiveTailWorking(idlePrompt + String(repeating: "\n", count: 40)))
    // Working text far above an idle bottom (old output) doesn't count.
    #expect(!cmuxLiveTailWorking(workingAtPrompt + "\n" + String(repeating: "output line\n", count: 30) + idlePrompt))
    #expect(!cmuxLiveTailWorking(""))
}

@Test func workingCheckConfirmsOnTheLiveTail() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var c = CmuxWorkingCheck()
    var reads: [String] = []
    func run(_ panes: [String], _ t: TimeInterval, _ answer: [String: Bool?]) -> Bool {
        c.anyWorking(panes, now: t0 + t) { key in reads.append(key); return answer[key] ?? nil }
    }
    // No candidates: nothing read, not working.
    #expect(!run([], 0, [:])); #expect(reads.isEmpty)
    // The live tail disagrees: the pane doesn't count, and isn't read again within the minute.
    #expect(!run(["cmux:a"], 0, ["cmux:a": false]))
    #expect(!run(["cmux:a"], 9, ["cmux:a": true]))
    #expect(!run(["cmux:a"], 59.9, ["cmux:a": true]))
    #expect(reads == ["cmux:a"])
    // A minute on, it's read again.
    #expect(run(["cmux:a"], 60, ["cmux:a": true]))
    #expect(reads == ["cmux:a", "cmux:a"])
    // A confirmed pane keeps counting for the minute without another read.
    #expect(run(["cmux:a"], 69, ["cmux:a": false]))
    #expect(reads.count == 2)
}

@Test func workingCheckStopsOnNoAnswer() {
    let t0 = Date(timeIntervalSince1970: 1000)
    var c = CmuxWorkingCheck()
    var reads: [String] = []
    func run(_ panes: [String], _ t: TimeInterval, _ answer: [String: Bool?]) -> Bool {
        c.anyWorking(panes, now: t0 + t) { key in reads.append(key); return answer[key] ?? nil }
    }
    // No answer from the first pane: not working, and the rest wait for the next scan.
    #expect(!run(["cmux:a", "cmux:b"], 0, ["cmux:a": nil, "cmux:b": true]))
    #expect(reads == ["cmux:a"])
    // Next scan: the silent pane isn't asked again within the minute, the other is.
    #expect(run(["cmux:a", "cmux:b"], 9, ["cmux:a": true, "cmux:b": true]))
    #expect(reads == ["cmux:a", "cmux:b"])
    // A pane already confirmed is enough: nothing else is read.
    #expect(run(["cmux:c", "cmux:b"], 18, ["cmux:c": true]))
    #expect(reads == ["cmux:a", "cmux:b"])
    // forget() drops every answer.
    c.forget()
    #expect(run(["cmux:b"], 20, ["cmux:b": false]) == false)
    #expect(reads == ["cmux:a", "cmux:b", "cmux:b"])
}
