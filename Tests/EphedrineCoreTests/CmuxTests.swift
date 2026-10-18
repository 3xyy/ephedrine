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
    // Anything else that failed (socket off, cmux quitting) isn't a connection.
    #expect(cmuxAccess(exitCode: 1, output: "Error: Socket not found at /Users/me/.local/state/cmux/cmux.sock") == .denied)
    #expect(cmuxAccess(exitCode: 1, output: "") == .denied)
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
    // The text goes after "--", so it can never be read as a flag.
    #expect(cmuxSendArgs(id, "continue", force: false) == ["send", "--surface", id, "--", "continue"])
    #expect(cmuxSendArgs(id, "1", force: true) == ["send", "--surface", id, "--force", "--", "1"])
    #expect(cmuxEnterArgs(id, force: false) == ["send-key", "--surface", id, "enter"])
    #expect(cmuxEnterArgs(id, force: true) == ["send-key", "--surface", id, "--force", "enter"])
}

@Test func cmuxStatusLines() {
    let notConnected = "Not connected: in cmux, open Settings › Automation, choose Password and set one, then enter it here"
    #expect(cmuxStatusText(installed: false, running: false, passwordSaved: true, access: .ok, panes: 2) == "Not installed")
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: false, access: nil, panes: 0) == notConnected)
    #expect(cmuxStatusText(installed: true, running: false, passwordSaved: false, access: nil, panes: 0) == notConnected)
    #expect(cmuxStatusText(installed: true, running: false, passwordSaved: true, access: .ok, panes: 2)
            == "Password saved. Connects when cmux is open")
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: nil, panes: 0) == "Checking…")
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: .denied, panes: 0) == notConnected)
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: .needsPassword, panes: 0) == notConnected)
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: .badPassword, panes: 0)
            == "Password not accepted")
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: .notInstalled, panes: 0) == "Not installed")
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: .ok, panes: 3) == "Connected, 3 panes")
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: .ok, panes: 1) == "Connected, 1 pane")
    #expect(cmuxStatusText(installed: true, running: true, passwordSaved: true, access: .ok, panes: 0) == "Connected, 0 panes")
}
