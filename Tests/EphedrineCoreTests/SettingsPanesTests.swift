import Testing
import Foundation
@testable import EphedrineCore

private func attention(lidSetupOK: Bool = true, lowPowerSetupNeeded: Bool = false, keepAwakeOn: Bool = true,
                       lidWhileClaude: Bool = true, cmux: CmuxRowState = .connected(1),
                       updateAvailable: Bool = false) -> SettingsAttention {
    SettingsAttention.evaluate(lidSetupOK: lidSetupOK, lowPowerSetupNeeded: lowPowerSetupNeeded, keepAwakeOn: keepAwakeOn,
                               lidWhileClaude: lidWhileClaude, cmux: cmux, updateAvailable: updateAvailable)
}

@Test func attentionNoneWhenAllIsWell() {
    #expect(attention() == SettingsAttention(lid: false, claude: false, about: false))
}

@Test func attentionLid() {
    #expect(attention(lowPowerSetupNeeded: true) == SettingsAttention(lid: true))
    #expect(attention(lidSetupOK: false) == SettingsAttention(lid: true))
    // No setup, but nothing would use it: "While Claude is working" off, or keep-awake off.
    #expect(attention(lidSetupOK: false, lidWhileClaude: false) == SettingsAttention())
    #expect(attention(lidSetupOK: false, keepAwakeOn: false) == SettingsAttention())
    // The re-run is needed whatever those switches say.
    #expect(attention(lowPowerSetupNeeded: true, keepAwakeOn: false, lidWhileClaude: false) == SettingsAttention(lid: true))
}

@Test func attentionClaude() {
    #expect(attention(cmux: .unreadablePassword) == SettingsAttention(claude: true))
    #expect(attention(cmux: .badPassword) == SettingsAttention(claude: true))
    for quiet: CmuxRowState in [.notInstalled, .notRunning, .noPassword, .checking, .failed, .connected(0), .connected(3)] {
        #expect(attention(cmux: quiet) == SettingsAttention(), "\(quiet)")
    }
}

@Test func attentionAbout() {
    #expect(attention(updateAvailable: true) == SettingsAttention(about: true))
    #expect(attention(lidSetupOK: false, cmux: .badPassword, updateAvailable: true)
            == SettingsAttention(lid: true, claude: true, about: true))
}

@Test func generalBanner() {
    let on = SettingsBanners.general(enabled: true)
    #expect(on.headline == "Keeping the Mac awake while Claude works")
    #expect(on.sentence == "Once Claude is done it sleeps the way you set under Sleep. Stay awake, I'm leaving and lid sessions work either way.")
    let off = SettingsBanners.general(enabled: false)
    #expect(off.headline == "Off, macOS sleeps as usual")
    #expect(off.sentence == "Ephedrine won't keep the Mac awake for Claude. Stay awake, I'm leaving and lid sessions still work.")
}

@Test func sleepBannerModes() {
    let idle = SettingsBanners.sleep(finishMode: .sleepIfIdle, waitSeconds: 300, powerMode: .always)
    #expect(idle.headline == "After Claude finishes, the Mac sleeps once you're away")
    #expect(idle.sentence == "It waits until the keyboard and mouse have been idle for 5 minutes.")
    let always = SettingsBanners.sleep(finishMode: .alwaysSleep, waitSeconds: 300, powerMode: .always)
    #expect(always.headline == "After Claude finishes, the Mac sleeps even if you're using it")
    #expect(always.sentence == "It sleeps 5 minutes after Claude is done, even while you're typing.")
    let normal = SettingsBanners.sleep(finishMode: .stayNormal, waitSeconds: 300, powerMode: .always)
    #expect(normal.headline == "After Claude finishes, macOS handles sleep")
    #expect(normal.sentence == "Ephedrine only keeps the Mac awake while Claude works.")
}

@Test func sleepBannerWait() {
    func wait(_ s: Int) -> String { SettingsBanners.sleep(finishMode: .alwaysSleep, waitSeconds: s, powerMode: .always).sentence }
    #expect(wait(15) == "It sleeps 15 seconds after Claude is done, even while you're typing.")
    #expect(wait(1) == "It sleeps 1 second after Claude is done, even while you're typing.")
    #expect(wait(60) == "It sleeps 1 minute after Claude is done, even while you're typing.")
    #expect(wait(120) == "It sleeps 2 minutes after Claude is done, even while you're typing.")
    #expect(wait(600) == "It sleeps 10 minutes after Claude is done, even while you're typing.")
}

@Test func sleepBannerPowerSource() {
    let battery = SettingsBanners.sleep(finishMode: .sleepIfIdle, waitSeconds: 30, powerMode: .batteryOnly)
    #expect(battery.sentence == "It waits until the keyboard and mouse have been idle for 30 seconds. Plugged in, your normal macOS settings apply.")
    let ac = SettingsBanners.sleep(finishMode: .alwaysSleep, waitSeconds: 30, powerMode: .acOnly)
    #expect(ac.sentence == "It sleeps 30 seconds after Claude is done, even while you're typing. On battery, your normal macOS settings apply.")
    // Nothing auto-sleeps, so the power source doesn't matter.
    let normal = SettingsBanners.sleep(finishMode: .stayNormal, waitSeconds: 30, powerMode: .batteryOnly)
    #expect(normal.sentence == "Ephedrine only keeps the Mac awake while Claude works.")
}

@Test func lidBanner() {
    let notSetUp = SettingsBanners.lid(setupOK: false, lowPowerSetupNeeded: false, whileClaude: true)
    #expect(notSetUp.headline == "Lid-closed mode isn't set up")
    #expect(notSetUp.action == .setUp)
    // The stamp rule only counts once setup is installed.
    #expect(SettingsBanners.lid(setupOK: false, lowPowerSetupNeeded: true, whileClaude: true).action == .setUp)

    let ready = SettingsBanners.lid(setupOK: true, lowPowerSetupNeeded: false, whileClaude: true)
    #expect(ready.headline == "Lid-closed mode is ready")
    #expect(ready.action == nil)
    #expect(ready.sentence.contains("keeps going"))
    #expect(!ready.sentence.contains("Low Power"))

    let step = SettingsBanners.lid(setupOK: true, lowPowerSetupNeeded: true, whileClaude: true)
    #expect(step.headline == "Lid-closed mode needs one more step")
    #expect(step.action == .rerunSetup)
    #expect(step.sentence.contains("Low Power Mode needs the setup re-run"))

    let off = SettingsBanners.lid(setupOK: true, lowPowerSetupNeeded: false, whileClaude: false)
    #expect(off.sentence.contains("“While Claude is working” is off"))
    #expect(!off.sentence.contains("keeps going"))
}

@Test func claudeBanner() {
    let off = SettingsBanners.claude(autoContinue: .off, autoResumeLimit: false, cmux: .notInstalled)
    #expect(off.headline == "Not retrying API errors")
    #expect(off.sentence == "Doesn't continue after a usage limit.")

    let terminal = SettingsBanners.claude(autoContinue: .fast, autoResumeLimit: true, cmux: .noPassword)
    #expect(terminal.headline == "Retrying API errors in Terminal")
    #expect(terminal.sentence.contains("every 15s, 5 tries"))
    #expect(terminal.sentence.contains("Waits out usage limits"))
    #expect(terminal.sentence.contains("no socket password"))

    #expect(SettingsBanners.claude(autoContinue: .backoff, autoResumeLimit: true, cmux: .connected(2)).headline
            == "Retrying API errors in Terminal and cmux")
    #expect(SettingsBanners.claude(autoContinue: .backoff, autoResumeLimit: true, cmux: .connected(2)).sentence
            .hasSuffix("cmux is connected, 2 panes."))
    #expect(SettingsBanners.claude(autoContinue: .backoff, autoResumeLimit: true, cmux: .connected(1)).sentence
            .hasSuffix("cmux is connected, 1 pane."))
    #expect(SettingsBanners.claude(autoContinue: .persistent, autoResumeLimit: true, cmux: .unreadablePassword).sentence
            .contains("can't read the saved cmux password"))
    #expect(SettingsBanners.claude(autoContinue: .persistent, autoResumeLimit: true, cmux: .badPassword).sentence
            .contains("turned the saved password down"))
    // cmux off or checking adds nothing and doesn't claim cmux.
    for quiet: CmuxRowState in [.notInstalled, .notRunning, .checking, .failed] {
        let b = SettingsBanners.claude(autoContinue: .fast, autoResumeLimit: true, cmux: quiet)
        #expect(b.headline == "Retrying API errors in Terminal", "\(quiet)")
        #expect(!b.sentence.contains("cmux"), "\(quiet)")
    }
}

@Test func awayBanner() {
    let here = SettingsBanners.away(isAway: false)
    let gone = SettingsBanners.away(isAway: true)
    #expect(here.headline == "I'm leaving pauses your apps and turns the screen off")
    #expect(gone.headline == here.headline)
    #expect(gone.sentence.hasPrefix("You're away now."))
    #expect(here.sentence.hasPrefix("Other apps are paused"))
    #expect(here.sentence.hasSuffix("open the lid to come back."))
}

@Test func aboutBanner() {
    let ok = SettingsBanners.about(version: "1.4.0", latest: nil, checksForUpdates: true)
    #expect(ok.headline == "Ephedrine 1.4.0")
    #expect(ok.sentence.contains("up to date"))
    let off = SettingsBanners.about(version: "1.4.0", latest: nil, checksForUpdates: false)
    #expect(off.sentence.contains("Update checks are off"))
    let newer = SettingsBanners.about(version: "1.4.0", latest: "1.5.0", checksForUpdates: false)
    #expect(newer.headline == "Ephedrine 1.4.0, 1.5.0 is out")
    #expect(newer.sentence.contains("brew upgrade 3xyy/tap/ephedrine"))
}

@Test func hotspotBadge() {
    #expect(SettingsBanners.hotspotBadge(name: "", saved: .found) == ("Not set up", .dim))
    #expect(SettingsBanners.hotspotBadge(name: "Pixel", saved: .found) == ("Ready", .ok))
    #expect(SettingsBanners.hotspotBadge(name: "Pixel", saved: .missing) == ("Needs password", .warn))
    #expect(SettingsBanners.hotspotBadge(name: "Pixel", saved: .unreadable) == ("Needs password", .warn))
}

@Test func cmuxBadge() {
    #expect(SettingsBanners.cmuxBadge(.connected(3)) == ("Connected", .ok))
    #expect(SettingsBanners.cmuxBadge(.checking) == ("Checking", .dim))
    #expect(SettingsBanners.cmuxBadge(.notInstalled) == ("Not installed", .dim))
    #expect(SettingsBanners.cmuxBadge(.notRunning) == ("Not running", .dim))
    #expect(SettingsBanners.cmuxBadge(.noPassword) == ("No password", .dim))
    #expect(SettingsBanners.cmuxBadge(.unreadablePassword) == ("Needs password", .warn))
    #expect(SettingsBanners.cmuxBadge(.badPassword) == ("Wrong password", .warn))
    #expect(SettingsBanners.cmuxBadge(.failed) == ("Can't connect", .warn))
}
