import XCTest
@testable import NokcanduCore

/// The pad's feel: adaptive smoothing, the landing ease-in and the thumb-sweep angle.
final class SteamPadFeelTests: XCTestCase {
    private func settings(smoothing: Double? = nil, rotation: Double? = nil) -> PadSteamTrackpadSettings {
        var s = PadSteamTrackpadSettings(mode: .mouse)
        s.sensitivity = 1000; s.smoothing = smoothing; s.rotation = rotation
        return s
    }
    /// Deterministic ±noise around a path, 250 reports a second.
    private func run(_ s: PadSteamTrackpadSettings, seconds: Double, noise: Double = 0, path: (Double) -> (Double, Double)) -> (x: Int, y: Int, travel: Int) {
        var pad = PadSteamTrackpad(), x = 0, y = 0, travel = 0, seed: UInt64 = 7
        func jitter() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 2 * noise }
        var t = 0.0
        while t <= seconds {
            let p = path(t)
            let m = pad.touch(down: true, x: p.0 + jitter(), y: p.1 + jitter(), at: 10 + t, settings: s)
            x += m.x; y += m.y; travel += abs(m.x) + abs(m.y)
            t += 0.004
        }
        return (x, y, travel)
    }

    func testUnsetAndZeroSmoothingKeepRawMovement() {
        let raw = run(settings(), seconds: 0.4) { t in (0.3 + t, 0.5) }
        let zero = run(settings(smoothing: 0), seconds: 0.4) { t in (0.3 + t, 0.5) }
        XCTAssertEqual(raw.x, zero.x); XCTAssertEqual(raw.y, zero.y)
        XCTAssertEqual(raw.x, 388, accuracy: 6, "less the landing guard's 1.2% of the pad")
    }

    func testARestingThumbHoldsThePointerStillAndSlowAimStillMoves() {
        let noise = 0.002          // about ±65 of the pad's ±32767 counts
        for smoothing in [nil, 0.4] as [Double?] {
            let rest = run(settings(smoothing: smoothing), seconds: 2, noise: noise) { _ in (0.5, 0.5) }
            XCTAssertEqual(rest.travel, 0, "a resting thumb doesn't wiggle the pointer (smoothing \(String(describing: smoothing)))")
        }
        // Rest, then a slow deliberate aim (a fifth of the pad per second), then rest again, then aim again.
        let path: (Double) -> (Double, Double) = { t in
            t < 0.3 ? (0.4, 0.5) : t < 0.8 ? (0.4 + (t - 0.3) * 0.2, 0.5) : t < 1.2 ? (0.5, 0.5) : (0.5 + (t - 1.2) * 0.2, 0.5) }
        let aim = run(settings(smoothing: 0.4), seconds: 1.6, noise: 0.0005, path: path)
        XCTAssertGreaterThan(aim.x, 150, "both slow movements come through (about 180 in all)")
        XCTAssertLessThan(abs(aim.y), 6)
    }

    func testAFastSwipeArrivesInFullAndPromptly() {
        // Half the pad in 0.2 s, then held: almost all of the distance, with only the landing ease-in missing.
        let swipe = run(settings(smoothing: 0.4), seconds: 0.3) { t in (0.25 + min(t, 0.2) * 2.5, 0.5) }
        XCTAssertGreaterThan(swipe.x, 455); XCTAssertLessThanOrEqual(swipe.x, 500)
        // While still moving, the pointer trails the finger by a few milliseconds at most.
        let moving = run(settings(smoothing: 0.4), seconds: 0.2) { t in (0.25 + t * 2.5, 0.5) }
        XCTAssertGreaterThan(moving.x, 500 - 45 - 20)
    }

    func testLandingDoesNotKickThePointer() {
        // The contact centre shifts as the finger settles in the first few reports, then stays put.
        func landing(_ t: Double) -> (Double, Double) { (0.5 + min(t, 0.012) * 0.5, 0.5) }
        let raw = run(settings(), seconds: 0.2, path: landing)
        let smooth = run(settings(smoothing: 0.4), seconds: 0.2, path: landing)
        XCTAssertEqual(raw.travel, 0, "a settling finger doesn't move the pointer")
        XCTAssertEqual(smooth.travel, 0)
        // A finger that really moves after landing still does, from where it is (no jump).
        let moving = run(settings(), seconds: 0.2) { t in (0.5 + t * 0.5, 0.5) }
        XCTAssertGreaterThan(moving.x, 80)
    }

    func testPadAngleTurnsAxesTheWayValveDoes() {
        // A raw swipe along the right pad's physical x axis, at Valve's +15°: mostly across, and slightly up.
        let turned = run(settings(rotation: 15), seconds: 0.4) { t in (0.3 + t, 0.5) }
        XCTAssertEqual(Double(turned.x), 388 * cos(15 * Double.pi / 180), accuracy: 8)
        XCTAssertEqual(Double(turned.y), -400 * sin(15 * Double.pi / 180), accuracy: 4)
        // The thumb's sweep that the angle is for comes out level.
        let sweep = run(settings(rotation: 15), seconds: 0.4) { t in (0.3 + t * cos(15 * Double.pi / 180), 0.5 + t * sin(15 * Double.pi / 180)) }
        XCTAssertEqual(sweep.x, 388, accuracy: 8); XCTAssertEqual(sweep.y, 0, accuracy: 2)
    }

    func testAStraightVerticalSwipeStaysStraightByDefault() {
        var s = PadSteamTrackpadSettings(mode: .trackball); s.sensitivity = 1000
        var p = PadProfiles.Profile(name: "P"); p.steamRightTrackpad = s
        let applied = PadProfiles.steamTrackpad(1, profile: p, all: [p])
        let up = run(applied, seconds: 0.3) { t in (0.5, 0.8 - t * 1.5) }
        XCTAssertLessThan(abs(up.x), 3, "no sideways hook on a vertical swipe")
        XCTAssertLessThan(up.y, -300)
    }

    func testProfilesGetTheRecommendedFeelUnlessTheySayOtherwise() throws {
        var p = PadProfiles.Profile(name: "Steam")
        p.steamRightTrackpad = PadSteamTrackpadSettings(mode: .trackball)
        var left = PadSteamTrackpadSettings(mode: .mouse); left.smoothing = 0; left.rotation = 0
        p.steamLeftTrackpad = left
        let right = PadProfiles.steamTrackpad(1, profile: p, all: [p])
        XCTAssertEqual(right.smoothing, PadSteamTrackpadSettings.defaultSmoothing); XCTAssertEqual(right.rotation, 0, "the pad's own directions unless chosen")
        let explicit = PadProfiles.steamTrackpad(0, profile: p, all: [p])
        XCTAssertEqual(explicit.smoothing, 0); XCTAssertEqual(explicit.rotation, 0)
        // Saved profiles are not rewritten: the stored settings still have no value of their own.
        let stored = try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: JSONEncoder().encode(p.steamRightTrackpad!))
        XCTAssertNil(stored.smoothing); XCTAssertNil(stored.rotation)
    }
}

final class SteamPadSteadinessWithSmoothingTests: XCTestCase {
    func testSteadinessStepsAsideWhileSmoothingIsOn() {
        var s = PadSteamTrackpadSettings(mode: .mouse); s.sensitivity = 1000; s.steadiness = 2
        func diagonal(_ s: PadSteamTrackpadSettings) -> (x: Int, y: Int, stalls: Int) {
            var pad = PadSteamTrackpad(), x = 0, y = 0, stalls = 0
            _ = pad.touch(down: true, x: 0.3, y: 0.7, at: 1, settings: s)
            for n in 1...60 {
                // Mostly upward with a slight drift right: the case that hooked.
                let m = pad.touch(down: true, x: 0.3 + Double(n) * 0.0008, y: 0.7 - Double(n) * 0.006, at: 1 + Double(n) * 0.008, settings: s)
                x += m.x; y += m.y; if n > 20, m.x == 0, m.y == 0 { stalls += 1 }
            }
            return (x, y, stalls)
        }
        s.smoothing = 0
        let deadBand = diagonal(s)
        s.smoothing = 0.4
        let smooth = diagonal(s)
        XCTAssertEqual(smooth.stalls, 0, "no mid-swipe stalls")
        XCTAssertGreaterThan(smooth.x, deadBand.x, "the slight sideways drift isn't held back then released")
    }
}

final class SteamPadExactMotionTests: XCTestCase {
    func testEachReportCarriesItsExactMovementForTheMacPointer() {
        var s = PadSteamTrackpadSettings(mode: .mouse); s.sensitivity = 600; s.smoothing = 0; s.rotation = 0
        var pad = PadSteamTrackpad()
        _ = pad.touch(down: true, x: 0.7, y: 0.5, at: 1, settings: s)          // the thumb lands on the circle
        var whole = (x: 0, y: 0), exact = (x: 0.0, y: 0.0), worst = 0.0
        // A slow circle: small steps whose direction changes all the time.
        for n in 1...400 {
            let a = Double(n) / 400 * 2 * .pi
            let m = pad.touch(down: true, x: 0.5 + 0.2 * cos(a), y: 0.5 + 0.2 * sin(a), at: 1 + Double(n) * 0.008, settings: s)
            whole.x += m.x; whole.y += m.y; exact.x += m.fx; exact.y += m.fy
            if m.fx != 0 || m.fy != 0 {
                let want = atan2(cos(a), -sin(a)), got = atan2(m.fy, m.fx)
                var d = abs(want - got) * 180 / .pi; if d > 180 { d = 360 - d }; worst = max(worst, d)
            }
        }
        XCTAssertLessThan(worst, 5, "exact steps follow the circle")
        XCTAssertEqual(Double(whole.x), exact.x, accuracy: 1.01, "games get the same total in whole pixels")
        XCTAssertEqual(Double(whole.y), exact.y, accuracy: 1.01)
    }
}
