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
// or crashes, so any refusal means the light is left alone, Settings says so
// and the log says why. Levels are written to keyboard-backlight.json before
// the light goes off, so a crash leaves them for the next launch to put back.
// A level goes back only on a keyboard that still reads off
// (backlightRestorePlan); one that can't be put back yet stays in the file.

let keyboardBacklightPath = "\(home)/.claude/ephedrine/keyboard-backlight.json"

/// The class never declares this protocol; an instance is cast to it only
/// after keyboardClientRefusal has passed, so each call matches the method's
/// real signature.
@objc private protocol KeyboardBrightnessClientBridge {
    // AnyObject, checked with `as? [NSNumber]`: typed NSArray, another class would crash the call site.
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> AnyObject?
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

    private func listedKeyboards(_ c: KeyboardBrightnessClientBridge) -> [UInt64] {
        ((c.copyKeyboardBacklightIDs() as? [NSNumber]) ?? []).map(\.uint64Value)
    }

    private func builtInKeyboards(_ c: KeyboardBrightnessClientBridge) -> [UInt64] {
        listedKeyboards(c).filter { c.isKeyboardBuiltIn($0) }
    }

    private var unreadableLogged = false
    private var keepLogged = false

    /// The levels keyboard-backlight.json holds (keyboard id → level): empty
    /// when there's none, nil (logged once) when it's there but can't be read.
    /// An unreadable file is left as it is, never overwritten or deleted.
    func savedLevels() -> [UInt64: Float]? {
        guard let levels = decodeBacklightLevels(fm.contents(atPath: keyboardBacklightPath)) else {
            if !unreadableLogged { unreadableLogged = true; logLine("\(keyboardBacklightPath) can't be read, leaving it as it is") }
            return nil
        }
        unreadableLogged = false
        return levels
    }

    private func save(_ levels: [UInt64: Float]) -> Bool {
        if levels.isEmpty { try? fm.removeItem(atPath: keyboardBacklightPath); return true }
        do {
            guard let d = encodeBacklightLevels(levels) else { throw CocoaError(.coderInvalidValue) }
            try d.write(to: URL(fileURLWithPath: keyboardBacklightPath), options: .atomic)
            return true
        } catch {
            logLine("couldn't write \(keyboardBacklightPath): \(error.localizedDescription)")
            return false
        }
    }

    /// Turn the built-in keyboards' light off, after writing down each lit
    /// one's level. Levels saved already (a hold a crash cut short) win: the
    /// light reads 0 now because of us. Returns the keyboards whose light
    /// actually went off, with the level saved for each.
    func dim() -> [UInt64: Float] {
        guard refusal == nil, let c = client else { return [:] }
        guard var levels = savedLevels() else { return [:] }   // can't record without overwriting it
        var lit: [UInt64] = []
        for id in builtInKeyboards(c) {
            let level = c.brightness(forKeyboard: id)
            guard level > 0 else { continue }
            lit.append(id)
            if levels[id] == nil { levels[id] = level }
        }
        guard !lit.isEmpty else { return [:] }
        guard save(levels) else { return [:] }   // no record, no change
        var off: [UInt64: Float] = [:]
        for id in lit {
            guard c.setBrightness(0, forKeyboard: id) else { continue }
            off[id] = levels[id]
            // Restoring needs it to read off: say so if it doesn't.
            let back = c.brightness(forKeyboard: id)
            if back > 0.001 { logLine("lid shut: the keyboard light was set to 0 but reads \(back)") }
        }
        if off.count < lit.count { logLine("lid shut: the keyboard light didn't switch off on \(lit.count - off.count) keyboard(s)") }
        return off
    }

    /// Put saved levels back where backlightRestorePlan says: only on a
    /// keyboard that still reads off (one lit since was set by its owner or by
    /// macOS, and its entry goes). One that can't be read, or whose setter says
    /// no, stays saved for evaluate's retry; the file goes only when nothing
    /// is left. With a refusal (macOS changed since) nothing is touched.
    /// Returns how many keyboards took their level back.
    @discardableResult
    func restore(_ levels: [UInt64: Float]) -> Int {
        guard refusal == nil, let c = client else { return 0 }
        guard !levels.isEmpty else { _ = save([:]); return 0 }
        let listed = listedKeyboards(c)
        let plan = backlightRestorePlan(saved: levels, listed: listed, builtIn: listed.first { c.isKeyboardBuiltIn($0) },
                                        levelNow: { listed.contains($0) ? c.brightness(forKeyboard: $0) : nil })
        var keep = plan.keep
        var restored = 0
        for (id, level) in plan.restore {
            if c.setBrightness(level, forKeyboard: id) { restored += 1 } else { keep[id] = level }
        }
        if !plan.drop.isEmpty { logLine("the keyboard light was changed while the lid was shut, left it as it is") }
        if keep.isEmpty { keepLogged = false } else if !keepLogged {
            keepLogged = true
            logLine("couldn't put the keyboard light back on \(keep.count) keyboard(s) yet, trying again later")
        }
        _ = save(keep)
        return restored
    }

    /// restore(_:) from keyboard-backlight.json; an unreadable file is left alone.
    @discardableResult
    func restoreSaved() -> Int {
        guard let levels = savedLevels() else { return 0 }
        return restore(levels)
    }
}
