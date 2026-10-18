import Testing
import Foundation
@testable import EphedrineCore

/// Compares ops with a small tolerance, since relative commands accumulate floats.
private func same(_ a: [PathOp]?, _ b: [PathOp]) -> Bool {
    guard let a = a, a.count == b.count else { return false }
    func eq(_ p: CGPoint, _ q: CGPoint) -> Bool { abs(p.x - q.x) < 1e-9 && abs(p.y - q.y) < 1e-9 }
    for (x, y) in zip(a, b) {
        switch (x, y) {
        case (.move(let p), .move(let q)), (.line(let p), .line(let q)): if !eq(p, q) { return false }
        case (.quad(let p1, let p2), .quad(let q1, let q2)): if !(eq(p1, q1) && eq(p2, q2)) { return false }
        case (.cubic(let p1, let p2, let p3), .cubic(let q1, let q2, let q3)): if !(eq(p1, q1) && eq(p2, q2) && eq(p3, q3)) { return false }
        case (.close, .close): break
        default: return false
        }
    }
    return true
}

@Test func absoluteCommands() {
    #expect(same(parseSVGPath("M3 5.6H13L12.4 12.9Q12.2 15.2 9.9 15.2Z"), [
        .move(CGPoint(x: 3, y: 5.6)), .line(CGPoint(x: 13, y: 5.6)), .line(CGPoint(x: 12.4, y: 12.9)),
        .quad(CGPoint(x: 12.2, y: 15.2), CGPoint(x: 9.9, y: 15.2)), .close]))
}
@Test func relativeAndImplicit() {
    #expect(same(parseSVGPath("m1 1 2 0v2h-2z"), [
        .move(CGPoint(x: 1, y: 1)), .line(CGPoint(x: 3, y: 1)), .line(CGPoint(x: 3, y: 3)), .line(CGPoint(x: 1, y: 3)), .close]))
    #expect(same(parseSVGPath("M0 0c1 1 2 2 3 3 1 1 2 2 3 3"), [
        .move(CGPoint(x: 0, y: 0)), .cubic(CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 3, y: 3)),
        .cubic(CGPoint(x: 4, y: 4), CGPoint(x: 5, y: 5), CGPoint(x: 6, y: 6))]))
}
@Test func compactNumbers() {
    #expect(same(parseSVGPath("M0 0l.079-.2307.5.5"), [
        .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 0.079, y: -0.2307)), .line(CGPoint(x: 0.579, y: 0.2693))]))
}
@Test func rejectsUnsupported() {
    #expect(parseSVGPath("M0 0A1 1 0 0 1 2 2") == nil)
    #expect(parseSVGPath("M0") == nil)
    #expect(parseSVGPath("") == nil)
}
@Test func sparkParsesInsideItsBox() {
    let ops = parseSVGPath(claudeSparkPath)
    #expect(ops != nil)
    let pts = (ops ?? []).flatMap { op -> [CGPoint] in
        switch op { case .move(let p), .line(let p): return [p]; case .quad(_, let p): return [p]
                    case .cubic(_, _, let p): return [p]; case .close: return [] } }
    #expect(pts.count > 100)
    #expect(pts.allSatisfy { $0.x >= -0.01 && $0.x <= 24.01 && $0.y >= -0.01 && $0.y <= 24.01 })
}

@Test func drawingAfterCloseRestartsFromSubpathStart() {
    #expect(same(parseSVGPath("M0 0L1 0Z L2 2"), [
        .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 1, y: 0)), .close,
        .move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 2, y: 2))]))
    #expect(same(parseSVGPath("M1 1L2 1zm1 1l1 0"), [
        .move(CGPoint(x: 1, y: 1)), .line(CGPoint(x: 2, y: 1)), .close,
        .move(CGPoint(x: 2, y: 2)), .line(CGPoint(x: 3, y: 2))]))
}
@Test func relativeQuadAndCommas() {
    #expect(same(parseSVGPath("M1 1q1 0 1 1"), [
        .move(CGPoint(x: 1, y: 1)), .quad(CGPoint(x: 2, y: 1), CGPoint(x: 2, y: 2))]))
    #expect(same(parseSVGPath("M0,0L1,1"), [.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 1, y: 1))]))
}
@Test func rejectsHalfFinishedCommand() {
    #expect(parseSVGPath("M0 0 L1") == nil)
    #expect(parseSVGPath("M0 0 C1 1 2 2 3") == nil)
}
