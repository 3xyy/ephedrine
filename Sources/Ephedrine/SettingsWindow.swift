import SwiftUI
import ServiceManagement
import EphedrineCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case now, general, sleep, lid, claude, away, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: return "Now"
        case .general: return "General"
        case .sleep: return "Sleep"
        case .lid: return "Lid closed"
        case .claude: return "Claude Code"
        case .away: return "Away"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .now: return "bolt.circle"
        case .general: return "gearshape"
        case .sleep: return "moon.zzz"
        case .lid: return "laptopcomputer"
        case .claude: return "terminal"
        case .away: return "figure.walk"
        case .about: return "info.circle"
        }
    }
}

/// View state for the settings window. SwiftUI's @State is a compiler macro
/// whose plugin ships with Xcode only, so with just the Command Line Tools
/// (how Homebrew builds Ephedrine) it doesn't compile. Keep view state in an
/// object the window controller owns instead; CI rejects @State in Sources.
final class SettingsUI: ObservableObject {
    @Published var pane: SettingsPane? = .now
    @Published var loginChanged = 0           // bumped after a toggle so it redraws right away
    @Published var notifications = "Checking…"
    @Published var cmuxPassword = ""          // typed in Claude Code › cmux, cleared once saved to the keychain
    @Published var hotspotSSID = ""           // typed in Lid › iPhone hotspot, filled from the saved name when the pane opens
    @Published var hotspotPassword = ""       // cleared once saved to the keychain
    @Published var hotspotMessage = ""        // why the last Save did nothing
    @Published var cmuxSavedAt: Date?         // when Save last worked, for the 4-second "Saved" label
    @Published var hotspotSavedAt: Date?
    @Published var tmuxTarget = ""            // typed in Claude Code › tmux panes, cleared once added
}

/// One window, created on first use and reused.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let clock = SettingsClock()
    private let ui = SettingsUI()

    func show(settings: AppSettings, controller: AppController) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, controller: controller, clock: clock, ui: ui))
            let w = NSWindow(contentViewController: host)
            w.title = "Ephedrine Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 700, height: 500))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        clock.start()
        NSApp.activate()   // accessory app: bring it forward so the window isn't behind the active app
        window?.makeKeyAndOrderFront(nil)
    }

    // The window is only hidden on close (reused next time), so stop the live
    // refresh so nothing re-reads controller state while nobody's looking.
    func windowWillClose(_ notification: Notification) {
        clock.stop()
        ui.cmuxPassword = ""   // a typed but unsaved password doesn't wait in memory for the next open
        ui.hotspotPassword = ""
    }
}

/// Ticks once a second while the settings window is open so the live panes
/// re-read controller state. A plain scheduled Timer runs in the default
/// run-loop mode, so it also pauses while a picker's menu is open.
final class SettingsClock: ObservableObject {
    @Published var now = Date()
    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        now = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.now = Date() }
    }
    func stop() { timer?.invalidate(); timer = nil }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    @ObservedObject var clock: SettingsClock
    @ObservedObject var ui: SettingsUI
    private var now: Date { clock.now }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $ui.pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Form { paneContent(ui.pane ?? .now) }
                .formStyle(.grouped)
                .navigationTitle((ui.pane ?? .now).title)
        }
        .frame(minWidth: 640, minHeight: 440)
    }

    @ViewBuilder func paneContent(_ p: SettingsPane) -> some View {
        switch p {
        case .general: GeneralPane(settings: settings, controller: controller, ui: ui, now: now)
        case .sleep: SleepPane(settings: settings, controller: controller)
        case .claude: ClaudePane(settings: settings, controller: controller, ui: ui, now: now)
        case .now: NowPane(controller: controller, now: now)
        case .lid: LidPane(settings: settings, controller: controller, ui: ui, now: now)
        case .away: AwayPane(settings: settings)
        case .about: AboutPane(settings: settings, controller: controller, ui: ui, now: now)
        }
    }
}

/// Small grey explanation under a control.
struct Tip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    @ObservedObject var ui: SettingsUI
    let now: Date   // re-renders each second, so a change made in System Settings shows up

    var body: some View {
        Section {
            Toggle("Keep awake while Claude is working", isOn: $settings.enabled)
            Tip("Keeps the Mac awake while Claude Code, or anything ticked below, is working, then sleeps the way you set under Sleep. Off means normal macOS sleep. Stay awake, I'm leaving and lid sessions work either way.")
        }
        Section("Also keep awake while…") {
            ForEach(controller.detectors, id: \.key) { d in
                Toggle(isOn: Binding(
                    get: { settings.detectors.contains(d.key) },
                    set: { on in if on { settings.detectors.insert(d.key) } else { settings.detectors.remove(d.key) } })) {
                    Text(d.label); Tip(d.tip)
                }
            }
            Toggle(isOn: $settings.keepAwakeClaudeWorking) {
                Text("Claude Code is busy in Terminal")
                Tip("Reads Terminal.app's screen, so it also catches background workflows the hooks can't see.")
            }
            Tip("On battery, the ones above keep the Mac awake for an hour at most, so a server left running can't hold it all night.")
        }
        Section {
            Toggle(isOn: $settings.allowDisplaySleep) {
                Text("Let the screen sleep during background tasks")
                Tip("When only a background task or a usage-limit wait is keeping the Mac awake, the display may still turn off. The screen stays on while Claude is working or while you've chosen to stay awake.")
            }
            Toggle("Open at login", isOn: Binding(get: { _ = ui.loginChanged; return SMAppService.mainApp.status == .enabled },
                                                  set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { logLine("login item toggle failed: \(error)") }
                ui.loginChanged += 1
            }))
        }
        Section {
            Toggle(isOn: $settings.appNapOffForAgents) {
                Text("Never let App Nap slow down terminals, editors and Claude")
                Tip("Writes NSAppSleepDisabled into those apps' settings and puts the old value back when you turn this off. Each app picks it up the next time it opens.")
            }
            if settings.appNapOffForAgents, !appNapInstalledNames.isEmpty {
                Tip("Applies to: " + appNapInstalledNames.joined(separator: ", ") + ".")
            }
        }
        Section("Menu bar icon") {
            Picker("Colors", selection: $settings.menuBarIconStyle) {
                ForEach(MenuBarIconStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            LabeledContent("Preview") {
                HStack(spacing: 14) {
                    let s = settings.menuBarIconStyle
                    ForEach([("Awake", menuBarAwakeIcon(style: s)),
                             ("Lid session", menuBarSymbolIcon("laptopcomputer", tint: menuBarStateTint(style: s, away: false, lidSession: true))),
                             ("Away", menuBarSymbolIcon("figure.walk", tint: menuBarStateTint(style: s, away: true, lidSession: false))),
                             ("Idle", menuBarSymbolIcon("moon.zzz", tint: nil))], id: \.0) { name, img in
                        if let img = img { Image(nsImage: img).help(name) }
                    }
                }
            }
            Tip("Color by state: orange while it keeps the Mac awake, blue during a lid session you started, purple while you're away. Idle stays plain.")
        }
    }
}

struct SleepPane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController

    var body: some View {
        Section("When Claude finishes") {
            Picker("Then", selection: $settings.finishMode) {
                ForEach(FinishMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Tip(settings.finishMode.tip)
        }
        Section {
            let mins = controller.displaySleepMins
            Picker("Wait before sleeping", selection: Binding(
                get: { settings.graceUseSystem ? -1 : Int(settings.gracePeriod) },
                set: { v in
                    if v < 0 { settings.graceUseSystem = true }
                    else { settings.graceUseSystem = false; settings.gracePeriod = Double(v) }
                })) {
                Text(mins > 0 ? "Same as “Turn display off” (\(mins) min)" : "Same as “Turn display off” (Never → \(Int(settings.gracePeriod / 60)) min)").tag(-1)
                ForEach(controller.graceChoices, id: \.secs) { c in Text(c.long).tag(c.secs) }
            }
            Tip("How long you must be away from the keyboard and mouse before the Mac sleeps.")
            Picker("Auto-sleep on", selection: $settings.powerMode) {
                ForEach(PowerMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Tip(settings.powerMode.tip)
        }
        Section("On battery") {
            Picker("Keep it awake", selection: $settings.batteryFloor) {
                ForEach([30, 20, 10], id: \.self) { Text("Down to \($0)%").tag($0) }
                Text("Only on the charger").tag(lidOnlyPluggedIn)
            }
            Tip("Covers everything Ephedrine keeps awake for: Claude, “I'm leaving”, Stay awake and the lid. At the limit it lets the Mac sleep until you plug it in, so the battery never runs flat. Above it, usage-limit waits and “Also keep awake while…” get an hour at most on battery.")
            Picker("Low Power Mode below", selection: $settings.lowPowerFloor) {
                ForEach([50, 40, 30], id: \.self) { Text("\($0)%").tag($0) }
                Text("Off").tag(0)
            }
            Tip("While Ephedrine keeps the Mac awake on battery, it turns Low Power Mode on below this level or when the Mac runs hot, and off again once that's over. If you turned it on yourself, it stays on. Needs lid-closed setup.")
        }
    }
}

struct ClaudePane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    @ObservedObject var ui: SettingsUI
    let now: Date   // re-renders each second, so the cmux line follows cmux opening and quitting

    var body: some View {
        Group {
            Section("Retry after API errors") {
                Picker("Retry", selection: $settings.autoContinueMode) {
                    ForEach(AutoContinueMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Tip(settings.autoContinueMode.tip + " Types “continue” only when Claude Code's own screen is showing, so a plain shell is never typed into. Terminal.app, and cmux once connected.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("After a network outage, type continue in these tmux panes")
                    ForEach(settings.tmuxTargets, id: \.self) { target in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(target)
                                Spacer()
                                Button("Remove") { settings.tmuxTargets.removeAll { $0 == target } }
                            }
                            Text(tmuxMarkCommand(target))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    HStack {
                        TextField("Pane, like %3 or work:1.0", text: $ui.tmuxTarget)
                            .onSubmit(addTmuxTarget)
                        Button("Add", action: addTmuxTarget)
                    }
                    Text(tmuxMarkCommand(ui.tmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty ? "<pane>" : ui.tmuxTarget.trimmingCharacters(in: .whitespaces)))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Tip("Only after an outage of \(Int(settings.outageNudgeSeconds)) seconds or more, and only in a pane you mark by running the command above in tmux. Dead panes, copy mode and panes with input off are skipped.")
                }
                Toggle(isOn: $settings.tmuxPressEnter) {
                    Text("Press Enter after typing")
                    Tip("Enter also sends anything already typed in that pane.")
                }
            }
            Section("cmux") {
                LabeledContent("Status", value: controller.cmuxStatus)
                HStack {
                    SecureField(passwordFieldPlaceholder(controller.cmuxSavedState, empty: "Socket password"), text: $ui.cmuxPassword)
                        .onSubmit { if !ui.cmuxPassword.isEmpty { saveCmuxPassword() } }   // only Save removes one
                    Button("Save", action: saveCmuxPassword)
                    SavedLabel(visible: savedLabelVisible(savedAt: ui.cmuxSavedAt, now: now))
                }
                Text(savedPasswordLine(controller.cmuxSavedState)).font(.caption).foregroundStyle(.secondary)
                Tip("Lets Ephedrine read cmux's panes and type there with the same rules as in Terminal, and only into an empty Claude Code prompt or its limit menu. Use the password you set in cmux. It's kept in your keychain. Saving an empty field removes it.")
            }
            .task { controller.refreshCmux() }   // on one section: on the Group it would run once per child
            Section {
                Toggle(isOn: $settings.autoResumeLimit) {
                    Text("Continue after a usage limit resets")
                    Tip("When Claude Code hits a limit that resets within 6 hours: choose its “wait” option (never upgrade or paid credits), keep the Mac awake, and continue once it resets. On battery it only stays awake for the last hour before the reset. Weekly waits are left alone.")
                }
            }
            Section {
                Picker("Usage alert", selection: $settings.usageAlert) {
                    Text("Off").tag(0)
                    ForEach([70, 80, 90, 95], id: \.self) { Text("At \($0)%").tag($0) }
                }
                Tip("Get a notification when any limit (session, weekly, or per-model) reaches this level.")
            }
        }
    }

    private func addTmuxTarget() {
        settings.addTmuxTarget(ui.tmuxTarget)
        ui.tmuxTarget = ""
    }

    private func saveCmuxPassword() {
        let typed = !ui.cmuxPassword.isEmpty
        let ok = controller.saveCmuxPassword(ui.cmuxPassword)
        ui.cmuxPassword = ""
        if ok && typed { ui.cmuxSavedAt = Date() }
    }
}

/// "Saved" with a checkmark, shown next to a Save button for a few seconds.
struct SavedLabel: View {
    let visible: Bool
    var body: some View {
        if visible { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
    }
}
