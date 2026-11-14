import XCTest
@testable import NokcanduCore

/// November 13, 2026: with a trackpad and gyro aiming both moving the Mac pointer, the pointer jumped forward
/// with each trackpad report and straight back 0.6 ms later (recorded), because the second move started from a
/// position macOS hadn't updated yet. Streams, which take plain relative steps, were smooth.
final class PadPointerContinuityTests: XCTestCase {
    /// macOS as recorded: a posted move shows up `delay` seconds later.
    private struct Screen {
        var shown = CGPoint(x: 400, y: 500), queue: [(at: Double, p: CGPoint)] = []
        mutating func actual(_ now: Double) -> CGPoint {
            while let f = queue.first, f.at <= now { shown = f.p; queue.removeFirst() }
            return shown
        }
        mutating func post(_ p: CGPoint, _ now: Double, delay: Double = 0.0006) { queue.append((now + delay, p)) }
    }
    private func move(_ c: inout PadPointerContinuity, _ s: inout Screen, _ dx: Double, _ dy: Double, at now: Double, real: Bool = false) {
        var p = c.base(actual: s.actual(now), at: now, realMouseRecently: real)
        p.x += dx; p.y += dy
        c.posted(p, at: now); s.post(p, now)
    }

    func testTwoSourcesInOneReportBothCount() {
        var c = PadPointerContinuity(), s = Screen(), t = 10.0
        for _ in 0..<100 {
            move(&c, &s, 20.3, -1.2, at: t)            // the trackpad
            move(&c, &s, -1, -3, at: t + 0.0001)       // gyro aiming, before macOS has shown the first
            t += 0.008
        }
        let end = s.actual(t + 1)
        XCTAssertEqual(end.x, 400 + 100 * 19.3, accuracy: 0.01); XCTAssertEqual(end.y, 500 - 100 * 4.2, accuracy: 0.01)
    }

    func testSmallExactStepsAddUp() {
        var c = PadPointerContinuity(), s = Screen(), t = 10.0
        for _ in 0..<200 { move(&c, &s, 0.3, 0, at: t); t += 0.008 }
        XCTAssertEqual(s.actual(t + 1).x, 460, accuracy: 0.01)
    }

    func testAnythingElseMovingThePointerStartsAfresh() {
        var c = PadPointerContinuity(), s = Screen(), t = 10.0
        for _ in 0..<10 { move(&c, &s, 5, 0, at: t); t += 0.008 }
        _ = s.actual(t); s.shown = CGPoint(x: 900, y: 100)          // an app warps the pointer
        move(&c, &s, 5, 0, at: t)
        XCTAssertEqual(s.actual(t + 1), CGPoint(x: 905, y: 100))
        // The real mouse, even back where the controller left it.
        t += 0.008
        move(&c, &s, 5, 0.4, at: t); t += 0.008
        _ = s.actual(t); s.shown = CGPoint(x: 910, y: 100)
        move(&c, &s, 5, 0, at: t, real: true)
        XCTAssertEqual(s.actual(t + 1), CGPoint(x: 915, y: 100))
        // After a pause the pointer is taken from where macOS has it.
        t += 1; s.shown = CGPoint(x: 300.5, y: 300)
        move(&c, &s, 1, 0, at: t)
        XCTAssertEqual(s.actual(t + 1), CGPoint(x: 301.5, y: 300))
    }

    func testAPointerHeldAtAScreenEdgeIsNotPushedBeyondIt() {
        // macOS keeps the pointer at x = 1000 (an edge Nokcandu doesn't know about) whatever is posted.
        var c = PadPointerContinuity(), t = 10.0, held = CGPoint(x: 1000, y: 500), furthest = 0.0
        for _ in 0..<100 {
            var p = c.base(actual: held, at: t, realMouseRecently: false)
            p.x += 10; c.posted(p, at: t); furthest = max(furthest, p.x); t += 0.008
        }
        XCTAssertLessThan(furthest, 1100, "only what was posted within the catch-up time is assumed pending")
        var back = c.base(actual: held, at: t, realMouseRecently: false); back.x -= 10
        XCTAssertLessThan(back.x, 1060)
    }
}
