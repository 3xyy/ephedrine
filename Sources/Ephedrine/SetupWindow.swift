import SwiftUI
import ServiceManagement
import UserNotifications
import EphedrineCore

// ───────────────────────────── First-run setup ─────────────────────────────
//
// Every permission Ephedrine can use, why, and a button to grant it. Shown on
// first launch (until closed once) and from Settings → About. Nothing here
// asks macOS for anything until its button is clicked, including the keychain
// read for the usage meter, which waits for this screen.

/// What macOS says about Ephedrine controlling Terminal. `ask` shows macOS's
/// prompt if it hasn't been answered. That blocks, so never ask on the main thread.
func terminalAutomation(ask: Bool) -> AutomationPermission {
    guard let desc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal").aeDesc else { return .unknown }
    return automationPermission(AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask))
}

private func openSystemSettings(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}

/// The setup window's view state (no @State: see SettingsUI).
final class SetupState: ObservableObject {
    @Published var notifications: UNAuthorizationStatus?
    @Published var terminal: AutomationPermission?
    @Published var askingTerminal = false
    @Published var hooks = false
    @Published var loginChanged = 0
}

final class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let clock = SettingsClock()
    private let state = SetupState()
    var onClose: (() -> Void)?

    func show(settings: AppSettings, controller: AppController) {
        if window == nil {
            let view = SetupView(settings: settings, controller: controller, clock: clock, state: state,
                                 done: { [weak self] in self?.window?.performClose(nil) })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Set up Ephedrine"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        clock.start()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Only for Done or the close button. Quitting the app doesn't count as
    /// finishing setup (windowWillClose also fires then).
    func windowShouldClose(_ sender: NSWindow) -> Bool { onClose?(); return true }
    func windowWillClose(_ notification: Notification) { clock.stop() }
}

struct SetupView: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    @ObservedObject var clock: SettingsClock
    @ObservedObject var state: SetupState
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Ephedrine").font(.title2.bold())
                    Text("It keeps your Mac awake while Claude Code works and lets it sleep when Claude's done. Turn on what you want below. You can come back here any time from Settings → About.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section("The basics") {
                    SetupRow(symbol: "link", title: "Claude Code hooks",
                             detail: "How Ephedrine knows Claude is working. Running “ephedrine setup” in Terminal adds them to ~/.claude/settings.json. Sessions that were already open need a restart.") {
                        if state.hooks { Allowed("Installed") }
                        else {
                            Button("Copy command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("ephedrine setup", forType: .string)
                            }
                            .help("Copies “ephedrine setup” to run in Terminal")
                        }
                    }
                    SetupRow(symbol: "bell.badge", title: "Notifications",
                             detail: "A 10-second heads-up before it puts the Mac to sleep, with a button to cancel.") {
                        switch state.notifications {
                        case .authorized?, .provisional?: Allowed()
                        case .denied?: Button("Open Settings") {
                            openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
                        }
                        default: Button("Allow") {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                        }
                    }
                }
                Section("For the Terminal features") {
                    SetupRow(symbol: "terminal", title: "Control Terminal",
                             detail: "Reads Terminal.app tabs to tell when Claude is busy, and types “continue” when it stops on an API error or a usage limit. Only used if you turn those on under Settings → Claude Code.") {
                        switch state.terminal {
                        case .granted?: Allowed()
                        case .denied?: Button("Open Settings") {
                            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                        }
                        default:
                            Button(state.askingTerminal ? "Asking…" : "Allow") { askTerminal() }.disabled(state.askingTerminal)
                        }
                    }
                }
                Section("Optional") {
                    SetupRow(symbol: "chart.bar", title: "Claude usage in the menu",
                             detail: "Shows your session and weekly limits. Reads Claude Code's sign-in from the keychain; click Always Allow when macOS asks.") {
                        if !controller.usageLimits.isEmpty { Allowed("Showing") }
                        else if controller.usageFetching { Text("Checking…").foregroundStyle(.secondary) }
                        else { Button(controller.lastUsageFetch == nil ? "Allow" : "Try again") { controller.fetchUsage() } }
                    }
                    SetupRow(symbol: "laptopcomputer", title: "Lid-closed mode",
                             detail: "Lets Claude keep working with the lid shut. Adds a one-line sudo rule that only allows “pmset disablesleep”. Asks for your password once.") {
                        if controller.lidSetupOK { Allowed("Set up") }
                        else { Button("Set up…") { controller.setupLid() } }
                    }
                    SetupRow(symbol: "power", title: "Open at login", detail: "Start Ephedrine when you log in.") {
                        Toggle("", isOn: Binding(get: { _ = state.loginChanged; return SMAppService.mainApp.status == .enabled },
                                                 set: { on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { logLine("login item toggle failed: \(error)") }
                            state.loginChanged += 1
                        })).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 600, height: 790)
        .task(id: clock.now) { await refresh() }   // re-checks every second, so changes made in System Settings show up
    }

    private func refresh() async {
        state.notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if !state.askingTerminal { state.terminal = terminalAutomation(ask: false) }
        state.hooks = claudeHooksInstalled(settingsJSON: try? String(contentsOfFile: "\(home)/.claude/settings.json", encoding: .utf8))
    }

    /// macOS can only ask about an app that's running, so open Terminal first if needed.
    private func askTerminal() {
        state.askingTerminal = true
        let state = self.state
        DispatchQueue.global(qos: .userInitiated).async {
            if terminalAutomation(ask: false) == .appNotRunning,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                for _ in 0..<20 where terminalAutomation(ask: false) == .appNotRunning { Thread.sleep(forTimeInterval: 0.25) }
            }
            let result = terminalAutomation(ask: true)
            DispatchQueue.main.async { state.terminal = result; state.askingTerminal = false }
        }
    }
}

private struct SetupRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Tip(detail)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

private struct Allowed: View {
    var text = "Allowed"
    init(_ text: String = "Allowed") { self.text = text }
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize()
    }
}
