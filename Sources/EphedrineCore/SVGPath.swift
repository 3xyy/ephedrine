import Foundation
import CoreGraphics

/// One absolute-coordinate path segment.
public enum PathOp: Equatable {
    case move(CGPoint), line(CGPoint), quad(CGPoint, CGPoint), cubic(CGPoint, CGPoint, CGPoint), close
}

/// The Claude mark, 24-unit viewBox. From Simple Icons (`claude.svg`).
public let claudeSparkPath = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

/// Parses SVG path data into absolute ops. Handles M m L l H h V v C c Q q Z z,
/// implicit repeats and compact numbers (`.079-.2307`, `1.5.5`). Anything else
/// (arcs, smooth curves, malformed data) returns nil.
public func parseSVGPath(_ d: String) -> [PathOp]? {
    let s = Array(d.utf8)
    var i = 0
    func skipSep() { while i < s.count, s[i] == 32 || s[i] == 44 || s[i] == 9 || s[i] == 10 || s[i] == 13 { i += 1 } }
    func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    func number() -> Double? {
        skipSep()
        let start = i
        if i < s.count, s[i] == 43 || s[i] == 45 { i += 1 }
        var digits = 0
        while i < s.count, isDigit(s[i]) { i += 1; digits += 1 }
        if i < s.count, s[i] == 46 {
            i += 1
            while i < s.count, isDigit(s[i]) { i += 1; digits += 1 }
        }
        guard digits > 0 else { i = start; return nil }
        if i < s.count, s[i] == 101 || s[i] == 69 {
            let save = i
            i += 1
            if i < s.count, s[i] == 43 || s[i] == 45 { i += 1 }
            var e = 0
            while i < s.count, isDigit(s[i]) { i += 1; e += 1 }
            if e == 0 { i = save }
        }
        return Double(String(decoding: s[start..<i], as: UTF8.self))
    }
    func numbers(_ n: Int) -> [Double]? {
        var out: [Double] = []
        for _ in 0..<n { guard let v = number() else { return nil }; out.append(v) }
        return out
    }

    var ops: [PathOp] = []
    var cur = CGPoint.zero, start = CGPoint.zero
    var cmd: UInt8 = 0
    skipSep()
    guard i < s.count else { return nil }
    while true {
        skipSep()
        if i >= s.count { break }
        let c = s[i]
        let isLetter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
        if isLetter {
            guard "MmLlHhVvCcQqZz".utf8.contains(c) else { return nil }
            cmd = c
            i += 1
            if c == 90 || c == 122 {
                ops.append(.close); cur = start
                continue
            }
        } else if cmd == 0 || cmd == 90 || cmd == 122 {
            return nil
        }
        let rel = cmd >= 97
        let ox = rel ? cur.x : 0, oy = rel ? cur.y : 0
        switch cmd {
        case 77, 109:   // M m: extra pairs are linetos
            guard let v = numbers(2) else { return nil }
            let p = CGPoint(x: ox + v[0], y: oy + v[1])
            ops.append(.move(p)); cur = p; start = p
            cmd = rel ? 108 : 76
        case 76, 108:
            guard let v = numbers(2) else { return nil }
            cur = CGPoint(x: ox + v[0], y: oy + v[1]); ops.append(.line(cur))
        case 72, 104:
            guard let v = numbers(1) else { return nil }
            cur = CGPoint(x: ox + v[0], y: cur.y); ops.append(.line(cur))
        case 86, 118:
            guard let v = numbers(1) else { return nil }
            cur = CGPoint(x: cur.x, y: oy + v[0]); ops.append(.line(cur))
        case 67, 99:
            guard let v = numbers(6) else { return nil }
            let p = CGPoint(x: ox + v[4], y: oy + v[5])
            ops.append(.cubic(CGPoint(x: ox + v[0], y: oy + v[1]), CGPoint(x: ox + v[2], y: oy + v[3]), p)); cur = p
        case 81, 113:
            guard let v = numbers(4) else { return nil }
            let p = CGPoint(x: ox + v[2], y: oy + v[3])
            ops.append(.quad(CGPoint(x: ox + v[0], y: oy + v[1]), p)); cur = p
        default:
            return nil
        }
    }
    guard case .move? = ops.first else { return nil }
    return ops
}
