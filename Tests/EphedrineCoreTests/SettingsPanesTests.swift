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
