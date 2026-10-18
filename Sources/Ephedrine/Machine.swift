import Cocoa
import CoreWLAN
import IOKit
import EphedrineCore

/// Battery power in watts (negative while discharging), read from the
/// AppleSmartBattery service. Read when the menu opens, never on a timer.
func instantWatts() -> Double? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    func number(_ key: String) -> Int64? {
        (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.int64Value
    }
    guard let amps = number("InstantAmperage"), let volts = number("Voltage") else { return nil }
    return batteryWatts(amperage: amps, voltage: volts)
}

func isCharging() -> Bool { onACPower() }

/// The Wi-Fi network's name, "on" when it's connected but macOS withholds the
/// name, nil when Wi-Fi is off or there's no interface.
func wifiStatusName() -> String? {
    guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { return nil }
    if let ssid = iface.ssid(), !ssid.isEmpty { return ssid }
    return iface.rssiValue() != 0 ? "on" : nil
}
