import Foundation
import ObjectiveC
import EphedrineCore

// ───────────────────────────── Keyboard light ─────────────────────────────
//
// With the lid shut and the Mac held awake, the built-in keyboard's light can
// stay lit under the lid. macOS has no public call for it, so this uses the
// private CoreBrightness class `KeyboardBrightnessClient`, and only when every
// method it calls has the type encoding Insomnia measured
// (keyboardClientRefusal). A call through a changed signature reads garbage
// or crashes, so any refusal means the light is left alone and Settings says why.
// Levels are written to keyboard-backlight.json before the light goes off, so
// a crash leaves them for the next launch to put back.

let keyboardBacklightPath = "\(home)/.claude/ephedrine/keyboard-backlight.json"

/// The class never declares this protocol; an instance is cast to it only
/// after keyboardClientRefusal has passed, so each call matches the method's
/// real signature.
@objc private protocol KeyboardBrightnessClientBridge {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray?
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ keyboard: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func brightness(forKeyboard keyboard: UInt64) -> Float
    @objc(setBrightness:forKeyboard:) func setBrightness(_ level: Float, forKeyboard keyboard: UInt64) -> Bool
}

final class KeyboardBacklight {
    static let shared = KeyboardBacklight()

    /// Why the keyboard light is left alone on this Mac, or nil when it can be switched.
    let refusal: String?
    private let clientClass: NSObject.Type?
    /// Made on first use, not for Settings asking about `refusal`, and kept
    /// (a plain strong reference, so its lifetime doesn't hang on the cast below).
    private lazy var instance: NSObject? = clientClass?.init()
    private var client: KeyboardBrightnessClientBridge? {
        instance.map { unsafeBitCast($0, to: KeyboardBrightnessClientBridge.self) }   // `as!` fails: no declared conformance
    }

    private init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil else {
            refusal = "CoreBrightness couldn't be loaded"; clientClass = nil; return
        }
        guard let cls = NSClassFromString("KeyboardBrightnessClient") else {
            refusal = "KeyboardBrightnessClient is missing"; clientClass = nil; return
        }
        if let why = keyboardClientRefusal(encodingFor: { name in
            class_getInstanceMethod(cls, NSSelectorFromString(name)).flatMap(method_getTypeEncoding).map { String(cString: $0) }
        }) {
            refusal = why; clientClass = nil; return
        }
        guard let type = cls as? NSObject.Type else {
            refusal = "KeyboardBrightnessClient isn't an NSObject"; clientClass = nil; return
        }
        refusal = nil
        clientClass = type
    }

    private func builtInKeyboards(_ c: KeyboardBrightnessClientBridge) -> [UInt64] {
        ((c.copyKeyboardBacklightIDs() as? [NSNumber]) ?? []).map(\.uint64Value).filter { c.isKeyboardBuiltIn($0) }
    }

    /// The levels keyboard-backlight.json holds (keyboard id → level), empty when there's none.
    func savedLevels() -> [UInt64: Float] {
        guard let d = fm.contents(atPath: keyboardBacklightPath),
              let raw = try? JSONDecoder().decode([String: Float].self, from: d) else { return [:] }
        var out: [UInt64: Float] = [:]
        for (k, v) in raw { if let id = UInt64(k) { out[id] = v } }
        return out
    }

    private func save(_ levels: [UInt64: Float]) -> Bool {
        if levels.isEmpty { try? fm.removeItem(atPath: keyboardBacklightPath); return true }
        let raw = Dictionary(uniqueKeysWithValues: levels.map { (String($0.key), $0.value) })
        do {
            try JSONEncoder().encode(raw).write(to: URL(fileURLWithPath: keyboardBacklightPath), options: .atomic)
            return true
        } catch {
            logLine("couldn't write \(keyboardBacklightPath): \(error.localizedDescription)")
            return false
        }
    }

    /// Turn the built-in keyboards' light off, after writing down each lit
    /// one's level. Levels saved already (a hold a crash cut short) win: the
    /// light reads 0 now because of us. Returns the saved levels, empty if
    /// nothing was switched off.
    func dim() -> [UInt64: Float] {
        guard refusal == nil, let c = client else { return [:] }
        var levels = savedLevels()
        for id in builtInKeyboards(c) where levels[id] == nil {
            let level = c.brightness(forKeyboard: id)
            if level > 0 { levels[id] = level }
        }
        guard !levels.isEmpty else { return [:] }
        guard save(levels) else { return [:] }   // no record, no change
        for id in levels.keys { _ = c.setBrightness(0, forKeyboard: id) }
        return levels
    }

    /// Put each saved level back, then forget them. Once only, even if a
    /// keyboard says no: nothing tells a retry whether the owner has set the
    /// light since, and a retry would override them. With a refusal (macOS
    /// changed since the levels were saved) nothing is touched and the file stays.
    /// Returns how many keyboards took their level back.
    @discardableResult
    func restore(_ levels: [UInt64: Float]) -> Int {
        guard refusal == nil, let c = client, !levels.isEmpty else { return 0 }
        var failed = 0
        for (id, level) in levels {
            if !c.setBrightness(level, forKeyboard: id) { failed += 1 }
        }
        if failed > 0 { logLine("the keyboard light didn't take its level back on \(failed) keyboard(s), press the brightness key") }
        _ = save([:])
        return levels.count - failed
    }
}
