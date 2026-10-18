import Foundation
import Security

/// Generic passwords in the login keychain, shared by the cmux socket password
/// and the iPhone hotspot password.
enum Keychain {
    enum Read: Equatable {
        case found(String)
        case missing                 // nothing saved (errSecItemNotFound)
        case unreadable(OSStatus)    // there, but macOS would have to ask (or failed): never shown
    }

    private static func item(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    // SecKeychainSetUserInteractionAllowed is deprecated, so it's looked up at
    // run time. It's a process-wide switch: reads take the lock so two threads
    // can't restore it under each other.
    private typealias GetAllowed = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    private typealias SetAllowed = @convention(c) (Bool) -> OSStatus
    private static let interactionLock = NSLock()
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    private static let getAllowed = dlsym(rtldDefault, "SecKeychainGetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: GetAllowed.self) }
    private static let setAllowed = dlsym(rtldDefault, "SecKeychainSetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: SetAllowed.self) }

    /// Never shows a dialog: with interaction off, an item macOS would ask about
    /// fails with errSecInteractionNotAllowed or errSecAuthFailed, which comes
    /// back as `unreadable` (not as "not found"). If the switch can't be found,
    /// the read isn't made at all.
    static func read(service: String, account: String) -> Read {
        guard let setAllowed else { return .unreadable(errSecUnimplemented) }
        interactionLock.lock(); defer { interactionLock.unlock() }
        var was = DarwinBoolean(true)
        _ = getAllowed?(&was)
        _ = setAllowed(false)
        defer { _ = setAllowed(was.boolValue) }
        var q = item(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unreadable(status) }
        guard let data = out as? Data, let pw = String(data: data, encoding: .utf8) else { return .unreadable(errSecDecode) }
        return .found(pw)
    }

    /// Add the password, or update it when the item exists. Main thread only:
    /// updating an item can make macOS ask, and nothing may wait on that answer.
    static func save(service: String, account: String, label: String, password: String) -> OSStatus {
        dispatchPrecondition(condition: .onQueue(.main))
        let data = Data(password.utf8)
        func attempt() -> OSStatus {
            var add = item(service, account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecDuplicateItem else { return s }
            return SecItemUpdate(item(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        let s = attempt()
        // A read on another thread had interaction switched off at that moment:
        // wait for it to finish (reads are quick), then try once more.
        guard s == errSecInteractionNotAllowed else { return s }
        interactionLock.lock(); interactionLock.unlock()
        return attempt()
    }

    /// Remove the item; already gone counts as done. Main thread only, like save.
    static func delete(service: String, account: String) -> OSStatus {
        dispatchPrecondition(condition: .onQueue(.main))
        let s = SecItemDelete(item(service, account) as CFDictionary)
        return s == errSecItemNotFound ? errSecSuccess : s
    }
}
