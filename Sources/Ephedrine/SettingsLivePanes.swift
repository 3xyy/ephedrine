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
        Section {
                Label(controller.statusText(), systemImage: "info.circle")
                if let next = controller.nextText() { Label(next, systemImage: "arrow.forward.circle") }
                if let lid = controller.lidStatusText() { Label(lid, systemImage: "laptopcomputer") }
                if let battery = controller.batteryText() { Label(battery, systemImage: "battery.50") }
            }
        Section {
                Button(controller.awayMode ? "I'm back, restore my apps" : "I'm leaving") { controller.toggleAway() }
                Tip("Pauses other apps and turns the screen off. Claude keeps working, then the Mac sleeps a minute after it's done. Move the mouse, type or open the lid to come back.")
            }
        Section("Stay awake") {
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
                Tip("Keeps the Mac and the screen awake no matter what, say for a long chat in the browser or the Claude app."
                    + (controller.lidSetupOK ? " The lid can be shut too." : ""))
            }
        Section {
                Button("Claude is done, stop waiting for it") { controller.resetIdle() }
                Tip("Use after cancelling Claude with Ctrl-C (which sends no signal), so the Mac doesn't stay awake waiting for it.")
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
    let now: Date   // re-renders each second, so setup finishing shows up

    var body: some View {
        if !controller.lidSetupOK {
                Section {
                    Text("A MacBook sleeps the moment its lid closes, even while Claude is working. Setup installs a one-line rule (\(lidSudoersPath)) that lets Ephedrine switch macOS's “disable sleep” setting and Low Power Mode on and off without a password. Nothing else gets admin rights.")
                    Button("Set up lid-closed mode…") { controller.setupLid() }
                    Tip("Asks for your password once.")
                }
        } else {
                Section {
                    Toggle(isOn: $settings.lidWhileClaude) {
                        Text("While Claude is working")
                        Tip("Close the lid and Claude keeps going, error retries and usage-limit waits included. A minute after it finishes, the Mac sleeps. Only while “Keep awake while Claude is working” is on.")
                    }
                    Toggle(isOn: $settings.lidRemoteCheckIn) {
                        Text("Check for Remote Control messages while asleep")
                        Tip("With the lid shut, macOS wakes the Mac for a few seconds every 10 to 20 minutes. Ephedrine turns those into a full wake for 2 minutes, so `claude remote-control` can pick up what you sent from your phone. If Claude starts working, the Mac stays awake until it's done, then sleeps again.")
                    }
                    .disabled(!settings.lidWhileClaude)
                    Toggle(isOn: $settings.lidLockOnClose) {
                        Text("Lock the screen when the lid closes")
                        Tip("The Mac stays awake with the lid shut, so macOS doesn't lock it by itself. Opening the lid shows the lock screen; Claude keeps working behind it.")
                    }
                    Toggle(isOn: $settings.lidPauseApps) {
                        Text("Pause other apps while it's shut")
                        Tip("Like “I'm leaving”. They resume when you open the lid, or once the Mac is no longer kept awake. Not with an external display attached.")
                    }
                    Toggle(isOn: $settings.lidMute) {
                        Text("Mute the sound while it's shut")
                        Tip("The sound comes back when you open the lid. If you unmute it yourself before then, it stays the way you set it.")
                    }
                    Tip("With the lid shut the built-in mic is cut off, so calls need AirPods or an external mic.")
                    Toggle(isOn: $settings.lidKeyboardOff) {
                        Text("Turn the keyboard light off while it's shut")
                        Tip("It comes back on at the same level when you open the lid.")
                    }
                    .disabled(KeyboardBacklight.shared.refusal != nil)
                    if KeyboardBacklight.shared.refusal != nil {   // why goes to the log, at each lid close
                        Tip("Turning the keyboard light off isn't supported on this macOS version.")
                    }
                    Toggle(isOn: $settings.lidDockerRule) {
                        Text("Pause Docker while it's shut")
                        Tip("Only when no container is running. Docker is asked twice, and if it doesn't answer it keeps running. It resumes when you open the lid. A docker command Claude starts after the lid shuts waits until you open it.")
                    }
                    Toggle(isOn: $settings.lowPowerOnLidShut) {
                        Text("Low Power Mode while the lid is shut")
                        Tip("On battery, turns Low Power Mode on while the Mac stays awake with the lid shut, and off again when the lid opens. If you turned it on yourself, it stays on.")
                    }
                    if controller.lowPowerSetupNeeded {
                        Button("Update lid setup…") { controller.setupLid() }
                        Tip("Adds Low Power Mode to what Ephedrine may switch. Asks for your password once.")
                    }
                }
                Section("Sleep anyway, even mid-task") {
                    Picker("Too hot at", selection: $settings.lidHeatLimit) {
                        Text("Warm").tag(LidHeatLimit.warm)
                        Text("Hot").tag(LidHeatLimit.hot)
                        Text("Very hot").tag(LidHeatLimit.veryHot)
                    }
                    Tip("Right now: \(thermalStateText()). macOS doesn't give apps a temperature, so this is its own heat level, the one it slows the Mac down at. Warm can come from a long build; Hot usually means it's shut in a bag.")
                    Picker("Lid shut longer than", selection: $settings.lidClosedCapHours) {
                        Text("No limit").tag(0)
                        ForEach([1, 2, 4, 8, 12], id: \.self) { Text($0 == 1 ? "1 hour" : "\($0) hours").tag($0) }
                    }
                    Tip("A backstop in case Claude looks busy for ages, say a stuck session. Stay awake runs as chosen. When either of these hits with the lid shut, the Mac goes to sleep. The battery limit is under Sleep and covers the lid too.")
                }
                Section {
                    Button("Remove lid-closed setup…") { controller.removeLidSetup() }
                    Tip("Deletes \(lidSudoersPath). Asks for your password.")
                }
        }
    }
}

/// "Spotify" for com.spotify.client, else the bundle id.
func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

struct AwayPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Text("“I'm leaving” pauses other apps and turns the screen off. Claude keeps working, then the Mac sleeps a minute after it's done. Move the mouse, type or open the lid to come back.")
        }
        Section("Always kept running") {
            Text(AppController.awayKeepRunning.map(appName).filter { !$0.contains(".") }.sorted().joined(separator: ", "))
                .foregroundStyle(.secondary)
            Tip("Plus any browser, terminals and editors that can host Claude Code, and call apps.")
        }
        Section("Also keep running") {
            if settings.awayKeepRunning.isEmpty { Tip("Nothing added.") }
            ForEach(settings.awayKeepRunning, id: \.self) { id in
                HStack {
                    Text(appName(id))
                    Spacer()
                    Button(role: .destructive) { settings.awayKeepRunning.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add app…") { chooseApps(settings.addKeepRunning) }
        }
        Section("Always pause") {
            if settings.alwaysPause.isEmpty { Tip("Nothing added.") }
            ForEach(settings.alwaysPause, id: \.self) { id in
                HStack {
                    Text(appName(id))
                    Spacer()
                    Button(role: .destructive) { settings.alwaysPause.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add app…") { chooseApps(settings.addAlwaysPause) }
            Tip("Paused even if it's on the keep-running list. Used by I'm leaving and when the lid shuts.")
        }
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
        Group {
            Section {
                LabeledContent("Version", value: appVersion)
                if let latest = controller.latestRelease {
                    LabeledContent("Update available", value: latest.version)
                    Button("See what's new…") { controller.openLatestRelease() }
                    Tip("Upgrade with “brew upgrade 3xyy/tap/ephedrine”, then “ephedrine setup”.")
                }
                Toggle(isOn: $settings.checkForUpdates) {
                    Text("Check for new versions")
                    Tip("Asks GitHub every 6 hours. A newer version shows at the top of the menu.")
                }
            }
            Section("Permissions") {
                LabeledContent("Notifications", value: ui.notifications)
                LabeledContent("Terminal control",
                               value: terminalControlStatus(tabs: controller.terminalTabsSeen, error: controller.terminalScanError))
                LabeledContent("Lid-closed mode", value: controller.lidSetupOK ? "Set up" : "Not set up")
            }
            Section {
                Button("Setup & permissions…") { controller.openSetup() }
            }
            Section {
                Button("Open log…") { controller.openLogs() }
            }
        }
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            ui.notifications = s.authorizationStatus == .authorized ? "Allowed" : "Off, so the pre-sleep warning won't show"
        }
    }
}
