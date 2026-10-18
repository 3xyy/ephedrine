import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import EphedrineCore

/// Live controller state; `now` changes every second, which re-renders it.
struct NowPane: View {
    let controller: AppController
    let now: Date

    enum Stay: Hashable { case off, indefinite, running, custom, minutes(Int) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.now.symbol, headline: controller.statusText(),
                           sentence: [controller.nextText(), controller.lidStatusText(), controller.batteryText()]
                               .compactMap { $0 }.joined(separator: "\n"),
                           action: (title: controller.awayMode ? "I'm back" : "I'm leaving", handler: { controller.toggleAway() }))
            SettingsColumns {
                SettingsCard(symbol: "sun.max", title: "Stay awake") {
                    SettingsRow("Keep it awake",
                                subtitle: "Keeps the Mac and the screen awake no matter what, say for a long chat in the browser or the Claude app."
                                    + (controller.lidSetupOK ? " The lid can be shut too." : "")) {
                        Picker("Stay awake", selection: Binding(get: { stayChoice }, set: setStay)) {
                            Text("Off").tag(Stay.off)
                            Text("For 30 minutes").tag(Stay.minutes(30))
                            Text("For 1 hour").tag(Stay.minutes(60))
                            Text("For 2 hours").tag(Stay.minutes(120))
                            Text("Custom…").tag(Stay.custom)
                            Text("Until I turn it off").tag(Stay.indefinite)
                            if let until = controller.keepAwakeUntil {
                                Text("\(fmtDuration(Int(until.timeIntervalSinceNow))) left").tag(Stay.running)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            } right: {
                SettingsCard(symbol: "checkmark.circle", title: "Claude") {
                    SettingsRow("Claude is done, stop waiting for it",
                                subtitle: "Use after cancelling Claude with Ctrl-C (which sends no signal), so the Mac doesn't stay awake waiting for it.") {
                        Button("Stop waiting") { controller.resetIdle() }.buttonStyle(SettingsButtonStyle())
                    }
                }
                SettingsCard(symbol: "figure.walk", title: "I'm leaving") {
                    SettingsNote("Pauses other apps and turns the screen off. Claude keeps working, then the Mac sleeps a minute after it's done. Move the mouse, type or open the lid to come back.")
                }
            }
        }
    }

    private var stayChoice: Stay {
        controller.manualKeepAwake ? .indefinite : (controller.keepAwakeUntil != nil ? .running : .off)
    }
    private func setStay(_ c: Stay) {
        switch c {
        case .off: controller.stopStayAwake()
        case .indefinite: controller.stayAwakeIndefinitely()
        case .minutes(let m): controller.stayAwake(minutes: m)
        case .custom: controller.startStayAwakeCustom()
        case .running: break
        }
    }
}

struct LidPane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    @ObservedObject var ui: SettingsUI
    let now: Date   // re-renders each second, so setup finishing shows up

    var body: some View {
        let setupOK = controller.lidSetupOK
        let banner = SettingsBanners.lid(setupOK: setupOK, lowPowerSetupNeeded: controller.lowPowerSetupNeeded,
                                         whileClaude: settings.lidWhileClaude, keepAwakeOn: settings.enabled,
                                         claudeCanHoldLid: controller.claudeCanHoldLid)
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.lid.symbol, headline: banner.headline, sentence: banner.sentence,
                           action: banner.action.map { a in
                               (title: a == .setUp ? "Set up…" : "Re-run setup…", handler: { controller.setupLid() })
                           })
            if !setupOK {
                SettingsColumns {
                    SettingsCard(symbol: "laptopcomputer", title: "Lid-closed mode") {
                        SettingsRow("Set up lid-closed mode",
                                    subtitle: "A MacBook sleeps the moment its lid closes, even while Claude is working. Setup installs a one-line rule (\(lidSudoersPath)) that lets Ephedrine switch macOS's “disable sleep” setting and Low Power Mode on and off without a password. Nothing else gets admin rights. Asks for your password once.") {
                            Button("Set up lid-closed mode…") { controller.setupLid() }
                                .buttonStyle(SettingsButtonStyle(.primary))
                        }
                    }
                } right: {
                    hotspotCard
                }
            } else {
                SettingsColumns {
                    shutCard
                } right: {
                    hotspotCard
                    sleepAnywayCard
                }
                SettingsCard(symbol: "trash", title: "Lid-closed setup") {
                    SettingsRow("Remove lid-closed setup", subtitle: "Deletes \(lidSudoersPath). Asks for your password.") {
                        Button("Remove lid-closed setup…") { controller.removeLidSetup() }
                            .buttonStyle(SettingsButtonStyle(.secondary))
                    }
                }
            }
        }
    }

    private func toggleRow(_ title: String, _ tip: String, _ isOn: Binding<Bool>, warning: Bool = false) -> some View {
        SettingsRow(title, subtitle: tip, warning: warning) {
            Toggle(title, isOn: isOn).toggleStyle(ClayToggleStyle())
        }
    }

    private var shutCard: some View {
        let keyboardRefusal = KeyboardBacklight.shared.refusal != nil   // why goes to the log, at each lid close
        let lowPowerStep = controller.lowPowerSetupNeeded
        return SettingsCard(symbol: "laptopcomputer", title: "While the lid is shut") {
            toggleRow("While Claude is working",
                      "Close the lid and Claude keeps going, error retries and usage-limit waits included. A minute after it finishes, the Mac sleeps. Only while “Keep awake while Claude is working” is on.",
                      $settings.lidWhileClaude)
            SettingsRow("Check for Remote Control messages while asleep",
                        subtitle: "With the lid shut, macOS wakes the Mac for a few seconds every 10 to 20 minutes. Ephedrine turns those into a full wake for 2 minutes, so `claude remote-control` can pick up what you sent from your phone. If Claude starts working, the Mac stays awake until it's done, then sleeps again.") {
                Toggle("Check for Remote Control messages while asleep", isOn: $settings.lidRemoteCheckIn).toggleStyle(ClayToggleStyle())
            }
            .disabled(!settings.lidWhileClaude)
            toggleRow("Lock the screen when the lid closes",
                      "The Mac stays awake with the lid shut, so macOS doesn't lock it by itself. Opening the lid shows the lock screen; Claude keeps working behind it.",
                      $settings.lidLockOnClose)
            toggleRow("Pause other apps while it's shut",
                      "Like “I'm leaving”. They resume when you open the lid, or once the Mac is no longer kept awake. Not with an external display attached.",
                      $settings.lidPauseApps)
            toggleRow("Mute the sound while it's shut",
                      "The sound comes back when you open the lid. If you unmute it yourself before then, it stays the way you set it. With the lid shut the built-in mic is cut off, so calls need AirPods or an external mic.",
                      $settings.lidMute)
            SettingsRow("Turn the keyboard light off while it's shut",
                        subtitle: "It comes back on at the same level when you open the lid."
                            + (keyboardRefusal ? " Turning the keyboard light off isn't supported on this macOS version." : "")) {
                Toggle("Turn the keyboard light off while it's shut", isOn: $settings.lidKeyboardOff).toggleStyle(ClayToggleStyle())
            }
            .disabled(keyboardRefusal)
            toggleRow("Pause Docker while it's shut",
                      "Only when no container is running. Docker is asked twice, and if it doesn't answer it keeps running. It resumes when you open the lid. A docker command Claude starts after the lid shuts waits until you open it.",
                      $settings.lidDockerRule)
            toggleRow("Low Power Mode while the lid is shut",
                      (lowPowerStep ? "Needs the setup re-run above. " : "")
                          + "On battery, turns Low Power Mode on while the Mac stays awake with the lid shut, and off again when the lid opens. If you turned it on yourself, it stays on.",
                      $settings.lowPowerOnLidShut, warning: lowPowerStep)
            toggleRow("Warn when a browser would slow down with the lid shut",
                      "Chrome, Edge, Brave, Arc, Comet and Chromium slow down hidden windows, which stalls Claude working in the browser. The menu then offers to relaunch the browser with two flags that stop that. It asks before quitting anything.",
                      $settings.browserThrottleWarning)
        }
    }

    private var sleepAnywayCard: some View {
        SettingsCard(symbol: "thermometer.medium", title: "Sleep anyway, even mid-task") {
            SettingsRow("Too hot at",
                        subtitle: "Right now: \(thermalStateText()). macOS doesn't give apps a temperature, so this is its own heat level, the one it slows the Mac down at. Warm can come from a long build; Hot usually means it's shut in a bag.") {
                Picker("Too hot at", selection: $settings.lidHeatLimit) {
                    Text("Warm").tag(LidHeatLimit.warm)
                    Text("Hot").tag(LidHeatLimit.hot)
                    Text("Very hot").tag(LidHeatLimit.veryHot)
                }
                .pickerStyle(.menu)
            }
            SettingsRow("Lid shut longer than",
                        subtitle: "A backstop in case Claude looks busy for ages, say a stuck session. Stay awake runs as chosen. When either of these hits with the lid shut, the Mac goes to sleep. The battery limit is under Sleep and covers the lid too.") {
                Picker("Lid shut longer than", selection: $settings.lidClosedCapHours) {
                    Text("No limit").tag(0)
                    ForEach([1, 2, 4, 8, 12], id: \.self) { Text($0 == 1 ? "1 hour" : "\($0) hours").tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    /// Shown with or without lid setup: joins run whenever Ephedrine holds the Mac awake.
    private var hotspotCard: some View {
        let saved = controller.hotspotSavedState
        let badge = SettingsBanners.hotspotBadge(name: controller.hotspotName, saved: saved)
        let tone: SettingsBadge.Tone = badge.tone == .ok ? .ok : badge.tone == .warn ? .warn : .dim
        return SettingsCard(symbol: "iphone", title: "iPhone hotspot", badge: SettingsBadge(badge.text, tone: tone)) {
            SettingsRow("Status", subtitle: controller.hotspotStatus)
            SettingsFieldRow("Network name") {
                TextField("Network name", text: $ui.hotspotSSID).settingsField()
            }
            SettingsFieldRow("Password") {
                SecureField(passwordFieldPlaceholder(saved, empty: "Password"), text: $ui.hotspotPassword)
                    .settingsField()
                    .onSubmit(saveHotspot)
            }
            SettingsActionBar(note: savedPasswordLine(saved), warning: saved == .unreadable) {
                SavedLabel(visible: savedLabelVisible(savedAt: ui.hotspotSavedAt, now: now))
                if !controller.hotspotName.isEmpty {
                    Button("Remove hotspot") {
                        controller.removeHotspot()
                        ui.hotspotSSID = ""; ui.hotspotPassword = ""; ui.hotspotMessage = ""
                    }
                    .buttonStyle(SettingsButtonStyle(.secondary))
                }
                Button("Save", action: saveHotspot).buttonStyle(SettingsButtonStyle(.primary))
            }
            if !ui.hotspotMessage.isEmpty { SettingsNote(ui.hotspotMessage, warning: true) }
            SettingsNote("While Ephedrine is keeping the Mac awake and Wi-Fi has been down for 5 seconds, the Mac tries to join this hotspot: the first try after 5 seconds, then after 10, 20 and 30 seconds, then every 30 seconds. It doesn't try while Wi-Fi is switched off or another connection, such as Ethernet, is working. The password is kept in your keychain. Leave it empty to keep the saved one.")
            SettingsRow("Location",
                        subtitle: controller.locationStatus + ". macOS only shows apps Wi-Fi network names when Location is allowed. Ephedrine never reads your location. Set System Settings › Wi-Fi › Ask to join hotspots to Automatically.") {
                if !controller.location.allowed && !controller.location.restricted {
                    Button("Open Location Services") {
                        if let url = URL(string: locationServicesURL) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(SettingsButtonStyle(.secondary))
                }
            }
        }
        .task {
            if ui.hotspotSSID.isEmpty { ui.hotspotSSID = settings.hotspotSSID }
            controller.refreshHotspot()
        }
    }

    private func saveHotspot() {
        ui.hotspotMessage = controller.saveHotspot(ssid: ui.hotspotSSID, password: ui.hotspotPassword) ?? ""
        ui.hotspotPassword = ""
        if ui.hotspotMessage.isEmpty { ui.hotspotSavedAt = Date() }
    }
}

/// "Spotify" for com.spotify.client, else the bundle id.
func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

struct AwayPane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController

    var body: some View {
        let banner = SettingsBanners.away(isAway: controller.awayMode)
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.away.symbol, headline: banner.headline, sentence: banner.sentence,
                           action: (title: controller.awayMode ? "I'm back" : "I'm leaving", handler: { controller.toggleAway() }))
            SettingsColumns {
                SettingsCard(symbol: "play.circle", title: "Always kept running") {
                    SettingsRow(AppController.awayKeepRunning.map(appName).filter { !$0.contains(".") }.sorted().joined(separator: ", "),
                                subtitle: "Plus any browser, terminals and editors that can host Claude Code, and call apps.")
                }
                SettingsCard(symbol: "plus.circle", title: "Also keep running") {
                    appRows(settings.awayKeepRunning, remove: { id in settings.awayKeepRunning.removeAll { $0 == id } },
                            add: settings.addKeepRunning, tip: nil)
                }
            } right: {
                SettingsCard(symbol: "pause.circle", title: "Always pause") {
                    appRows(settings.alwaysPause, remove: { id in settings.alwaysPause.removeAll { $0 == id } },
                            add: settings.addAlwaysPause,
                            tip: "Paused even if it's on the keep-running list. Used by I'm leaving and when the lid shuts.")
                }
            }
        }
    }

    /// The rows of an app list, then the Add button and the tip.
    @ViewBuilder private func appRows(_ ids: [String], remove: @escaping (String) -> Void,
                                      add: @escaping (String) -> Void, tip: String?) -> some View {
        if ids.isEmpty { SettingsRow("Nothing added.") }
        ForEach(ids, id: \.self) { id in
            let name = appName(id)
            SettingsRow(name) {
                Button { remove(id) } label: { Image(systemName: "minus.circle").foregroundStyle(SettingsColors.secondaryText) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(name)")
                    .help("Remove \(name)")
            }
        }
        SettingsRow("Add an app") {
            Button("Add app…") { chooseApps(add) }.buttonStyle(SettingsButtonStyle(.secondary))
        }
        if let tip { SettingsNote(tip) }
    }

    /// Pick apps in /Applications and hand each one's bundle id to `add`.
    private func chooseApps(_ add: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { add(id) } }
    }
}

struct AboutPane: View {
    @ObservedObject var settings: AppSettings
    let controller: AppController
    @ObservedObject var ui: SettingsUI
    let now: Date   // re-renders each second (terminal tab count, lid setup)

    var body: some View {
        let latest = controller.latestRelease
        let banner = SettingsBanners.about(version: appVersion, latest: latest?.version, checksForUpdates: settings.checkForUpdates)
        VStack(alignment: .leading, spacing: 16) {
            SettingsBanner(symbol: SettingsPane.about.symbol, headline: banner.headline, sentence: banner.sentence,
                           action: latest == nil ? nil : (title: "See what's new…", handler: { controller.openLatestRelease() }))
            SettingsColumns {
                SettingsCard(symbol: "lock.shield", title: "Permissions") {
                    SettingsRow("Notifications") { statusText(ui.notifications) }
                    SettingsRow("Terminal control") {
                        statusText(terminalControlStatus(tabs: controller.terminalTabsSeen, error: controller.terminalScanError))
                    }
                    SettingsRow("Lid-closed mode") { statusText(controller.lidSetupOK ? "Set up" : "Not set up") }
                }
                .task {
                    let s = await UNUserNotificationCenter.current().notificationSettings()
                    ui.notifications = s.authorizationStatus == .authorized ? "Allowed" : "Off, so the pre-sleep warning won't show"
                }
                SettingsCard(symbol: "questionmark.circle", title: "Help") {
                    SettingsRow("Setup & permissions") {
                        Button("Setup & permissions…") { controller.openSetup() }.buttonStyle(SettingsButtonStyle(.secondary))
                    }
                    SettingsRow("Log") {
                        Button("Open log…") { controller.openLogs() }.buttonStyle(SettingsButtonStyle(.secondary))
                    }
                }
            } right: {
                SettingsCard(symbol: "arrow.down.circle", title: "Updates") {
                    SettingsRow("Version") { statusText(appVersion) }
                    if let latest {
                        SettingsRow("Update available", subtitle: "Upgrade with “brew upgrade 3xyy/tap/ephedrine”, then “ephedrine setup”.") {
                            HStack(spacing: 10) {
                                statusText(latest.version)
                                Button("See what's new…") { controller.openLatestRelease() }.buttonStyle(SettingsButtonStyle(.secondary))
                            }
                        }
                    }
                    SettingsRow("Check for new versions", subtitle: "Asks GitHub every 6 hours. A newer version shows at the top of the menu.") {
                        Toggle("Check for new versions", isOn: $settings.checkForUpdates).toggleStyle(ClayToggleStyle())
                    }
                }
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(SettingsColors.secondaryText)
    }
}
