import SwiftUI
import ServiceManagement
import EphedrineCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case now, general, sleep, lid, claude, away, shortcuts, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: return "Now"
        case .general: return "General"
        case .sleep: return "Sleep"
        case .lid: return "Lid closed"
        case .claude: return "Claude Code"
        case .away: return "Away"
        case .shortcuts: return "Shortcuts"
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
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

extension AppController {
    /// The Settings tabs with something to fix or see (SettingsAttention has the rules).
    var settingsAttention: Set<SettingsPane> {
        let a = SettingsAttention.evaluate(lidSetupOK: lidSetupOK, lowPowerSetupNeeded: lowPowerSetupNeeded,
                                           cmux: cmuxRowState, updateAvailable: latestRelease != nil)
        var out: Set<SettingsPane> = []
        if a.lid { out.insert(.lid) }
        if a.claude { out.insert(.claude) }
        if a.about { out.insert(.about) }
        return out
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

    func show(settings: AppSettings, controller: AppController, pane: SettingsPane? = nil) {
        if let pane { ui.pane = pane }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, controller: controller, clock: clock, ui: ui))
            host.sizingOptions = []   // the window's sizes below rule, not the view's (it would add the title bar to the minimum)
            let w = NSWindow(contentViewController: host)
            w.title = "Ephedrine Settings"   // not drawn (the tab bar shows the pane), but Mission Control and VoiceOver use it
            // The content runs under the title bar, so the traffic lights sit on the tab bar.
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.setContentSize(NSSize(width: 900, height: 700))
            // The smallest size. AppKit takes the window's limits from the content's
            // constraints (it resets contentMinSize to them on layout), so say it there.
            host.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 820).isActive = true
            host.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 620).isActive = true
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
        // The safe area's top is the title bar: the tab bar's title row takes
        // that height, so the title lines up with the traffic lights.
        GeometryReader { geo in
            VStack(spacing: 0) {
                SettingsTabBar(ui: ui, attention: controller.settingsAttention, titleHeight: max(geo.safeAreaInsets.top, 28))
                paneArea(ui.pane ?? .now)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(SettingsColors.window.ignoresSafeArea())
    }

    @ViewBuilder private func paneArea(_ p: SettingsPane) -> some View {
        ScrollView {
            paneContent(p)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .id(p)   // each pane opens at its top
    }

    @ViewBuilder func paneContent(_ p: SettingsPane) -> some View {
        switch p {
        case .general: GeneralPane(settings: settings, controller: controller, ui: ui, now: now)
        case .sleep: SleepPane(settings: settings, controller: controller, now: now)
        case .claude: ClaudePane(settings: settings, controller: controller, ui: ui, now: now)
        case .now: NowPane(controller: controller, now: now)
        case .lid: LidPane(settings: settings, controller: controller, ui: ui, now: now)
        case .away: AwayPane(settings: settings, controller: controller)
        case .shortcuts: ShortcutsPane(settings: settings, controller: controller, now: now)
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
        let banner = SettingsBanners.general(enabled: settings.enabled)
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.general.symbol, headline: banner.headline, sentence: banner.sentence)
            SettingsColumns {
                SettingsCard(symbol: "cup.and.saucer", title: "Keep awake") {
                    SettingsRow("Keep awake while Claude is working",
                                subtitle: "Keeps the Mac awake while Claude Code, or anything ticked below, is working, then sleeps the way you set under Sleep. Off means normal macOS sleep. Stay awake, I'm leaving and lid sessions work either way.") {
                        Toggle("Keep awake while Claude is working", isOn: $settings.enabled).toggleStyle(ClayToggleStyle())
                    }
                }
                SettingsCard(symbol: "plus.circle", title: "Also keep awake while…") {
                    ForEach(controller.detectors, id: \.key) { d in
                        SettingsRow(d.label, subtitle: d.tip) {
                            Toggle(d.label, isOn: Binding(
                                get: { settings.detectors.contains(d.key) },
                                set: { on in if on { settings.detectors.insert(d.key) } else { settings.detectors.remove(d.key) } }))
                                .toggleStyle(ClayToggleStyle())
                        }
                    }
                    SettingsRow("Claude Code is busy in Terminal",
                                subtitle: "Reads Terminal.app's screen, so it also catches background workflows the hooks can't see.") {
                        Toggle("Claude Code is busy in Terminal", isOn: $settings.keepAwakeClaudeWorking).toggleStyle(ClayToggleStyle())
                    }
                    SettingsNote("On battery, the ones above keep the Mac awake for an hour at most, so a server left running can't hold it all night.")
                }
            } right: {
                SettingsCard(symbol: "display", title: "Screen and login") {
                    SettingsRow("Let the screen sleep during background tasks",
                                subtitle: "When only a background task or a usage-limit wait is keeping the Mac awake, the display may still turn off. The screen stays on while Claude is working or while you've chosen to stay awake.") {
                        Toggle("Let the screen sleep during background tasks", isOn: $settings.allowDisplaySleep).toggleStyle(ClayToggleStyle())
                    }
                    SettingsRow("Open at login") {
                        Toggle("Open at login", isOn: Binding(get: { _ = ui.loginChanged; return SMAppService.mainApp.status == .enabled },
                                                              set: { on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { logLine("login item toggle failed: \(error)") }
                            ui.loginChanged += 1
                        }))
                        .toggleStyle(ClayToggleStyle())
                    }
                }
                SettingsCard(symbol: "zzz", title: "App Nap") {
                    SettingsRow("Never let App Nap slow down terminals, editors and Claude",
                                subtitle: "Writes NSAppSleepDisabled into those apps' settings and puts the old value back when you turn this off. Each app picks it up the next time it opens.") {
                        Toggle("Never let App Nap slow down terminals, editors and Claude", isOn: $settings.appNapOffForAgents)
                            .toggleStyle(ClayToggleStyle())
                    }
                    if settings.appNapOffForAgents, !appNapInstalledNames.isEmpty {
                        SettingsNote("Applies to: " + appNapInstalledNames.joined(separator: ", ") + ".")
                    }
                }
                SettingsCard(symbol: "menubar.rectangle", title: "Menu bar icon") {
                    SettingsRow("Colors") {
                        Picker("Colors", selection: $settings.menuBarIconStyle) {
                            ForEach(MenuBarIconStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    SettingsRow("Preview") {
                        HStack(spacing: 14) {
                            let s = settings.menuBarIconStyle
                            ForEach([("Awake", menuBarAwakeIcon(style: s)),
                                     ("Lid session", menuBarSymbolIcon("laptopcomputer", tint: menuBarStateTint(style: s, away: false, lidSession: true))),
                                     ("Away", menuBarSymbolIcon("figure.walk", tint: menuBarStateTint(style: s, away: true, lidSession: false))),
                                     ("Idle", menuBarSymbolIcon("moon.zzz", tint: nil))], id: \.0) { name, img in
                                if let img = img { Image(nsImage: img).help(name).accessibilityLabel(name) }
                            }
                        }
                    }
                    SettingsNote("Color by state: orange while it keeps the Mac awake, blue during a lid session you started, purple while you're away. Idle stays plain.")
                }
            }
        }
    }
}

struct SleepPane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    let now: Date   // re-renders each second, so the display-off time from System Settings shows up

    var body: some View {
        let banner = SettingsBanners.sleep(enabled: settings.enabled, finishMode: settings.finishMode,
                                           waitSeconds: Int(controller.effectiveGraceSeconds()), powerMode: settings.powerMode)
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.sleep.symbol, headline: banner.headline, sentence: banner.sentence)
            SettingsColumns {
                SettingsCard(symbol: "checkmark.circle", title: "When Claude finishes") {
                    SettingsRow("Then", subtitle: settings.finishMode.tip) {
                        Picker("Then", selection: $settings.finishMode) {
                            ForEach(FinishMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                SettingsCard(symbol: "timer", title: "Auto-sleep") {
                    let mins = controller.displaySleepMins
                    SettingsRow("Wait before sleeping", subtitle: "How long you must be away from the keyboard and mouse before the Mac sleeps.") {
                        Picker("Wait before sleeping", selection: Binding(
                            get: { settings.graceUseSystem ? -1 : Int(settings.gracePeriod) },
                            set: { v in
                                if v < 0 { settings.graceUseSystem = true }
                                else { settings.graceUseSystem = false; settings.gracePeriod = Double(v) }
                            })) {
                            Text(mins > 0 ? "Same as “Turn display off” (\(mins) min)" : "Same as “Turn display off” (Never → \(Int(settings.gracePeriod / 60)) min)").tag(-1)
                            ForEach(controller.graceChoices, id: \.secs) { c in Text(c.long).tag(c.secs) }
                        }
                        .pickerStyle(.menu)
                    }
                    SettingsRow("Auto-sleep on", subtitle: settings.powerMode.tip) {
                        Picker("Auto-sleep on", selection: $settings.powerMode) {
                            ForEach(PowerMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            } right: {
                SettingsCard(symbol: "battery.50", title: "On battery") {
                    SettingsRow("Keep it awake",
                                subtitle: "Covers everything Ephedrine keeps awake for: Claude, “I'm leaving”, Stay awake and the lid. At the limit it lets the Mac sleep until you plug it in, so the battery never runs flat. Above it, “Also keep awake while…” gets an hour at most on battery, and so does a usage-limit wait while the lid is open. Close the lid while you're at the Mac and the wait is held until the reset.") {
                        Picker("Keep it awake", selection: $settings.batteryFloor) {
                            ForEach([30, 20, 10], id: \.self) { Text("Down to \($0)%").tag($0) }
                            Text("Only on the charger").tag(lidOnlyPluggedIn)
                        }
                        .pickerStyle(.menu)
                    }
                    SettingsRow("Pause Claude at the limit when you're away",
                                subtitle: "Claude Code keeps the Mac awake by itself, so at the limit Ephedrine pauses it once you're away (the lid shut, “I'm leaving”, or the screen gone to sleep by itself while Claude works, after a 10-second heads-up; a video or a call keeps the screen on, so they never count) and puts the Mac to sleep. It picks up where it was when you plug in or come back. While you're at the Mac you get a notification instead.") {
                        Toggle("Pause Claude at the limit when you're away", isOn: $settings.batteryPauseClaude).toggleStyle(ClayToggleStyle())
                    }
                    .disabled(settings.batteryFloor >= lidOnlyPluggedIn)
                    SettingsRow("Low Power Mode below",
                                subtitle: "While Ephedrine keeps the Mac awake on battery, it turns Low Power Mode on below this level or when the Mac runs hot, and off again once that's over. If you turned it on yourself, it stays on. Needs lid-closed setup.") {
                        Picker("Low Power Mode below", selection: $settings.lowPowerFloor) {
                            ForEach([50, 40, 30], id: \.self) { Text("\($0)%").tag($0) }
                            Text("Off").tag(0)
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        }
    }
}

struct ClaudePane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    @ObservedObject var ui: SettingsUI
    let now: Date   // re-renders each second, so the cmux line follows cmux opening and quitting

    var body: some View {
        let banner = SettingsBanners.claude(autoContinue: settings.autoContinueMode, autoResumeLimit: settings.autoResumeLimit,
                                            cmux: controller.cmuxRowState)
        let badge = SettingsBanners.cmuxBadge(controller.cmuxRowState)
        let cmuxSaved = controller.cmuxSavedState
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.claude.symbol, headline: banner.headline, sentence: banner.sentence)
            SettingsColumns {
                SettingsCard(symbol: "arrow.clockwise", title: "Retry after API errors") {
                    SettingsRow("Retry",
                                subtitle: settings.autoContinueMode.tip + " Types “continue” only when Claude Code's own screen is showing, so a plain shell is never typed into. Terminal.app, and cmux once connected.") {
                        Picker("Retry", selection: $settings.autoContinueMode) {
                            ForEach(AutoContinueMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                SettingsCard(symbol: "gauge.with.dots.needle.50percent", title: "Usage limits") {
                    SettingsRow("Continue after a usage limit resets",
                                subtitle: "When Claude Code hits a limit that resets within 6 hours: choose its “wait” option (never upgrade or paid credits), keep the Mac awake, and continue once it resets. On battery it only stays awake for the last hour before the reset. Weekly waits are left alone.") {
                        Toggle("Continue after a usage limit resets", isOn: $settings.autoResumeLimit).toggleStyle(ClayToggleStyle())
                    }
                    SettingsRow("Usage alert", subtitle: "Get a notification when any limit (session, weekly, or per-model) reaches this level.") {
                        Picker("Usage alert", selection: $settings.usageAlert) {
                            Text("Off").tag(0)
                            ForEach([70, 80, 90, 95], id: \.self) { Text("At \($0)%").tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            } right: {
                SettingsCard(symbol: "terminal", title: "cmux", badge: SettingsBadge(badge.text, tone: tone(badge.tone))) {
                    SettingsRow("Status", subtitle: controller.cmuxStatus)
                    SettingsFieldRow("Socket password") {
                        SecureField(passwordFieldPlaceholder(cmuxSaved, empty: "Socket password"), text: $ui.cmuxPassword)
                            .settingsField()
                            .onSubmit { if !ui.cmuxPassword.isEmpty { saveCmuxPassword() } }   // only Save removes one
                    }
                    SettingsActionBar(note: savedPasswordLine(cmuxSaved), warning: cmuxSaved == .unreadable) {
                        SavedLabel(visible: savedLabelVisible(savedAt: ui.cmuxSavedAt, now: now))
                        Button("Save", action: saveCmuxPassword).buttonStyle(SettingsButtonStyle(.primary))
                    }
                    SettingsNote("Lets Ephedrine read cmux's panes and type there with the same rules as in Terminal, and only into an empty Claude Code prompt or its limit menu. Use the password you set in cmux. It's kept in your keychain. Saving an empty field removes it.")
                }
                .task { controller.refreshCmux() }
            }
            tmuxCard
        }
    }

    private func tone(_ t: SettingsBanners.Tone) -> SettingsBadge.Tone {
        switch t { case .ok: return .ok; case .warn: return .warn; case .dim: return .dim }
    }

    private var tmuxCard: some View {
        let typed = ui.tmuxTarget.trimmingCharacters(in: .whitespaces)
        return SettingsCard(symbol: "rectangle.split.2x1", title: "tmux panes") {
            SettingsRow("After a network outage, type continue in these tmux panes",
                        subtitle: settings.tmuxTargets.isEmpty ? "No panes added." : nil)
            ForEach(settings.tmuxTargets, id: \.self) { target in
                VStack(spacing: 0) {
                    SettingsHairline()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(target).font(.system(size: 13)).foregroundStyle(SettingsColors.text)
                            Spacer()
                            Button("Remove") { settings.tmuxTargets.removeAll { $0 == target } }
                                .buttonStyle(SettingsButtonStyle(.secondary))
                        }
                        Text(tmuxMarkCommand(target))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SettingsColors.tertiaryText)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 8)
                }
            }
            VStack(spacing: 0) {
                SettingsHairline()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Pane, like %3 or work:1.0", text: $ui.tmuxTarget)
                            .settingsField()
                            .onSubmit(addTmuxTarget)
                        Button("Add", action: addTmuxTarget).buttonStyle(SettingsButtonStyle(.primary))
                    }
                    Text(tmuxMarkCommand(typed.isEmpty ? "<pane>" : typed))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SettingsColors.tertiaryText)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 8)
            }
            SettingsNote("Only after an outage of \(Int(settings.outageNudgeSeconds)) seconds or more, and only in a pane you mark by running the command above in tmux. Dead panes, copy mode and panes with input off are skipped.")
            SettingsRow("Press Enter after typing", subtitle: "Enter also sends anything already typed in that pane.") {
                Toggle("Press Enter after typing", isOn: $settings.tmuxPressEnter).toggleStyle(ClayToggleStyle())
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
        if visible {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text("Saved").font(.system(size: 11.5))
            }
            .foregroundStyle(SettingsColors.ok)
            .accessibilityElement(children: .combine)
        }
    }
}
