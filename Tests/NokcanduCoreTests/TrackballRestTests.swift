import XCTest
@testable import NokcanduCore

/// November 13, 2026: with the right pad as a trackball, a still thumb sometimes kept the cursor jiggling and the
/// movement haptics buzzing until the controller was replugged. A haptic pulse shakes the pad, the shake read as
/// movement, and the trackball never counted the finger as resting again, so each buzz caused the next.
final class TrackballRestTests: XCTestCase {
    private func settings(_ mode: PadSteamTrackpadSettings.Mode) -> PadSteamTrackpadSettings {
        var s = PadSteamTrackpadSettings(mode: mode); s.smoothing = 0.4; s.sensitivity = 1500; return s
    }

    /// A real swipe, then the thumb stays put while the pad shakes slightly (as under a pulse).
    private func moved(after swipe: Bool, mode: PadSteamTrackpadSettings.Mode) -> (during: Int, late: Int) {
        var pad = PadSteamTrackpad(); let s = settings(mode)
        var t = 0.0, x = 0.5, y = 0.5
        _ = pad.touch(down: true, x: x, y: y, at: t, settings: s)
        if swipe {
            for _ in 0..<40 { t += 0.004; x += 0.004; _ = pad.touch(down: true, x: x, y: y, at: t, settings: s) }
        }
        var during = 0, late = 0
        for i in 0..<500 {                       // 2 s of a resting thumb, wobbling ±0.003 at 40 Hz
            t += 0.004
            let wobble = 0.003 * sin(Double(i) * 0.004 * 2 * Double.pi * 40)
            let m = pad.touch(down: true, x: x + wobble, y: y + wobble * 0.5, at: t, settings: s)
            let n = abs(m.x) + abs(m.y)
            during += n
            if i >= 100 { late += n }               // after the first 0.4 s
        }
        return (during, late)
    }

    func testAResttingThumbStopsTheTrackballAfterASwipe() {
        XCTAssertEqual(moved(after: true, mode: .trackball).late, 0, "the wobble must not keep moving the cursor")
    }
    func testTheSameHoldsForTheTrackpadMouse() {
        XCTAssertEqual(moved(after: true, mode: .mouse).late, 0)
    }
    func testASlowDeliberateDragStillMovesTheTrackball() {
        var pad = PadSteamTrackpad(); let s = settings(.trackball)
        var t = 0.0, x = 0.3, total = 0
        _ = pad.touch(down: true, x: x, y: 0.5, at: t, settings: s)
        for _ in 0..<250 { t += 0.004; x += 0.0006; total += abs(pad.touch(down: true, x: x, y: 0.5, at: t, settings: s).x) }   // 0.15 pad/s
        XCTAssertGreaterThan(total, 100)
    }
}

/// The recorded resting thumb, through the reporting user's own pad settings (trackball, no smoothing, no
/// steadiness, sensitivity about 1,300).
final class RecordedRestingThumbTests: XCTestCase {
    private func run(_ s: PadSteamTrackpadSettings) -> (late: Int, perReport: Double) {
        var pad = PadSteamTrackpad(); var late = 0, n = 0
        for (t, x, y) in RestingThumbRecording.samples {
            let m = pad.touch(down: true, x: (Double(x) / 32767 + 1) / 2, y: (1 - Double(y) / 32767) / 2, at: t, settings: s)
            if t > 0.4 { late += abs(m.x) + abs(m.y); n += 1 }
        }
        return (late, Double(late) / Double(max(1, n)))
    }
    func testTheRecordedRestingThumbHoldsTheCursorStill() {
        var s = PadSteamTrackpadSettings(mode: .trackball)
        s.sensitivity = 647; s.sensitivityX = 1335; s.sensitivityY = 1404; s.smoothing = 0; s.steadiness = 0; s.rotation = -22
        let r = run(s)
        XCTAssertLessThan(r.perReport, 0.2, "pixels per report while resting: \(r.perReport) (total \(r.late))")
    }
    func testWithTheDefaultSmoothingToo() {
        var s = PadSteamTrackpadSettings(mode: .trackball); s.sensitivity = 1335; s.smoothing = 0.4
        XCTAssertLessThan(run(s).perReport, 0.2)
    }
}

final class TrackballStartTests: XCTestCase {
    /// Starting to move from rest isn't held back much by the averaging: a slow start (0.3 pad/s) moves within 50 ms.
    func testMovementFromRestStartsPromptly() {
        var pad = PadSteamTrackpad(); var s = PadSteamTrackpadSettings(mode: .trackball); s.sensitivity = 1335; s.smoothing = 0
        var t = 0.0, x = 0.5
        _ = pad.touch(down: true, x: x, y: 0.5, at: t, settings: s)
        for _ in 0..<60 { t += 0.008; _ = pad.touch(down: true, x: x, y: 0.5, at: t, settings: s) }   // rest
        let start = t; var firstMove: Double?
        for _ in 0..<30 {
            t += 0.008; x += 0.3 * 0.008
            if pad.touch(down: true, x: x, y: 0.5, at: t, settings: s).x != 0, firstMove == nil { firstMove = t }
        }
        XCTAssertNotNil(firstMove)
        XCTAssertLessThan((firstMove ?? 1) - start, 0.05)
    }
}
