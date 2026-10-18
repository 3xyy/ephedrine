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
    #expect(cmuxInputStateArgs(id) == ["rpc", "surface.input_state", "{\"surface_id\":\"\(id)\"}"])
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
