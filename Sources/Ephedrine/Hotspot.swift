import Cocoa
import CoreWLAN
import CoreLocation
import UserNotifications
import EphedrineCore

// ── Joining the owner's iPhone hotspot when Wi-Fi drops (Settings › Lid) ──
// The name is a plain setting; the password is a keychain item that is read
// without ever showing a dialog, and is never logged or put in a notification.

/// The hotspot password: a generic password in the login keychain, account = the network name.
enum HotspotKeychain {
    static let service = "ephedrine-hotspot"

    static func save(ssid: String, password: String) -> OSStatus {
        Keychain.save(service: service, account: ssid, label: "Ephedrine iPhone hotspot password", password: password)
    }

    static func delete(ssid: String) -> OSStatus { Keychain.delete(service: service, account: ssid) }

    /// Never shows a dialog. errSecItemNotFound (or an empty value) is `missing`;
    /// an item macOS would ask about, or any other failure, is `unreadable`.
    static func read(ssid: String) -> (String?, HotspotPasswordState) {
        switch Keychain.read(service: service, account: ssid) {
        case .missing: return (nil, .missing)
        case .unreadable: return (nil, .unreadable)
        case .found(let pw): return pw.isEmpty ? (nil, .missing) : (pw, .ok)
        }
    }
}

struct HotspotError: Error, CustomStringConvertible { let description: String }

/// Scan for the network by name and join it. Blocks for seconds: never on the main thread.
/// False when the scan doesn't see it (the phone is out of range, or its hotspot is off).
func joinHotspot(ssid: String, password: String) throws -> Bool {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let iface = CWWiFiClient.shared().interface() else { throw HotspotError(description: "no Wi-Fi interface") }
    guard iface.powerOn() else { throw HotspotError(description: "Wi-Fi is switched off") }
    guard let network = try iface.scanForNetworks(withSSID: Data(ssid.utf8)).first else { return false }
    try iface.associate(to: network, password: password)
    return true
}

/// Location permission, which macOS requires before it shows apps Wi-Fi network names.
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    override init() { super.init(); manager.delegate = self }

    var status: CLAuthorizationStatus { manager.authorizationStatus }
    var allowed: Bool { status == .authorizedAlways }

    /// Ask, once; after an answer only System Settings can change it.
    func request() { if status == .notDetermined { manager.requestWhenInUseAuthorization() } }
}

let locationServicesURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"

extension AppController {
    /// The saved network name, trimmed; "" when none.
    var hotspotName: String { settings.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Main thread, every tick. Starts a join when the gate says so; the attempt runs on hotspotQueue.
    func hotspotTick(holding: Bool) {
        let up = networkWatch.wifiSatisfied
        if up { hotspotNotified = false; hotspotNoted = false }
        guard !hotspotJoining else { return }
        let ssid = hotspotName
        guard hotspotGate.step(wifiUp: up, holding: holding, fullyAwake: fullyAwake, configured: !ssid.isEmpty, now: Date()) else { return }
        hotspotJoining = true
        if !location.allowed && !hotspotNoted {
            hotspotNoted = true
            logLine("hotspot join: Location isn't allowed, so macOS may hide network names from the scan; trying \(ssid) anyway")
        }
        hotspotQueue.async { [weak self] in
            let (pw, state) = HotspotKeychain.read(ssid: ssid)
            var result: String?
            if let pw {
                // Re-checked here: the Mac may have started to nap since the tick.
                if systemFullyAwake(fallback: true) {
                    do { result = try joinHotspot(ssid: ssid, password: pw) ? "joined" : "not found" }
                    catch { result = "failed (\(error))" }
                }
            } else if state == .missing {
                result = "failed (no password saved)"
            }
            DispatchQueue.main.async { self?.hotspotJoinDone(ssid: ssid, state: state, result: result) }
        }
    }

    /// Main thread. Logs the attempt; an unreadable password skips the join and tells the owner once per outage.
    private func hotspotJoinDone(ssid: String, state: HotspotPasswordState, result: String?) {
        hotspotJoining = false
        if ssid == hotspotName { hotspotPassword = state }
        if state == .unreadable {
            logLine("hotspot join \(ssid): skipped, the saved password can't be read without asking")
            if !hotspotNotified {
                hotspotNotified = true
                let c = UNMutableNotificationContent()
                c.title = "Couldn't join your hotspot"
                c.body = "Ephedrine can't read the saved password. Enter it again in Settings, Lid closed."
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka_hotspot", content: c, trigger: nil))
            }
        } else if let result {
            logLine("hotspot join \(ssid): \(result)")
        }
    }

    /// Settings › Lid, when it opens: look at the saved password again, off the main thread.
    func refreshHotspot() {
        let ssid = hotspotName
        guard !ssid.isEmpty else { hotspotPassword = .ok; return }
        hotspotQueue.async { [weak self] in
            let state = HotspotKeychain.read(ssid: ssid).1
            DispatchQueue.main.async { if ssid == self?.hotspotName { self?.hotspotPassword = state } }
        }
    }

    /// Save from Settings (main thread, where a keychain question can't stall a join). An empty name
    /// removes the hotspot; an empty password keeps the one saved. The first save asks for Location.
    func saveHotspot(ssid rawSSID: String, password: String) {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = hotspotName
        if ssid.isEmpty {
            if !old.isEmpty {
                let s = HotspotKeychain.delete(ssid: old)
                logLine(s == errSecSuccess ? "hotspot removed" : "couldn't remove the hotspot password (OSStatus \(s))")
            }
            settings.hotspotSSID = ""
            hotspotPassword = .ok
            return
        }
        if !password.isEmpty {
            let s = HotspotKeychain.save(ssid: ssid, password: password)
            logLine(s == errSecSuccess ? "hotspot \(ssid) saved" : "couldn't save the hotspot password (OSStatus \(s))")
        }
        if !old.isEmpty && old != ssid { _ = HotspotKeychain.delete(ssid: old) }
        settings.hotspotSSID = ssid
        location.request()
        refreshHotspot()
    }

    /// The hotspot line in Settings › Lid.
    var hotspotStatus: String {
        guard !hotspotName.isEmpty else { return "Not set" }
        switch hotspotPassword {
        case .ok: return "Saved: \(hotspotName)"
        case .missing: return "\(hotspotName), no password saved"
        case .unreadable: return "\(hotspotName), password needs re-entering"
        }
    }

    var locationStatus: String {
        switch location.status {
        case .authorizedAlways: return "Allowed"
        case .notDetermined: return "Not asked yet (asked when you save)"
        default: return "Off, so macOS may hide network names"
        }
    }
}
