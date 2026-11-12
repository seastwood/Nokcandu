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
        XCTAssertEqual(raw.x, 400, accuracy: 6)
    }

    func testSmoothingQuietsARestingFingerWithoutADeadBand() {
        let noise = 0.002          // about ±65 of the pad's ±32767 counts
        let raw = run(settings(), seconds: 1, noise: noise) { _ in (0.5, 0.5) }
        let smooth = run(settings(smoothing: 0.4), seconds: 1, noise: noise) { _ in (0.5, 0.5) }
        XCTAssertGreaterThan(raw.travel, 100)
        XCTAssertLessThan(smooth.travel * 4, raw.travel, "a resting finger should wander far less")
        // A very slow, tiny reversal is still followed: nothing has to be pushed through.
        let slow = run(settings(smoothing: 0.4), seconds: 1) { t in (0.5 + (t < 0.5 ? t : 1 - t) * 0.01, 0.5) }
        XCTAssertEqual(slow.x, 0, accuracy: 1)
        XCTAssertGreaterThanOrEqual(slow.travel, 6)
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
        XCTAssertGreaterThanOrEqual(raw.x, 5)
        XCTAssertLessThan(smooth.travel, raw.travel)
    }

    func testPadAngleTurnsAxesTheWayValveDoes() {
        // A raw swipe along the right pad's physical x axis, at Valve's +15°: mostly across, and slightly up.
        let turned = run(settings(rotation: 15), seconds: 0.4) { t in (0.3 + t, 0.5) }
        XCTAssertEqual(Double(turned.x), 400 * cos(15 * Double.pi / 180), accuracy: 6)
        XCTAssertEqual(Double(turned.y), -400 * sin(15 * Double.pi / 180), accuracy: 4)
        // The thumb's sweep that the angle is for comes out level.
        let sweep = run(settings(rotation: 15), seconds: 0.4) { t in (0.3 + t * cos(15 * Double.pi / 180), 0.5 + t * sin(15 * Double.pi / 180)) }
        XCTAssertEqual(sweep.x, 400, accuracy: 6); XCTAssertEqual(sweep.y, 0, accuracy: 2)
    }

    func testProfilesGetTheRecommendedFeelUnlessTheySayOtherwise() throws {
        var p = PadProfiles.Profile(name: "Steam")
        p.steamRightTrackpad = PadSteamTrackpadSettings(mode: .trackball)
        var left = PadSteamTrackpadSettings(mode: .mouse); left.smoothing = 0; left.rotation = 0
        p.steamLeftTrackpad = left
        let right = PadProfiles.steamTrackpad(1, profile: p, all: [p])
        XCTAssertEqual(right.smoothing, PadSteamTrackpadSettings.defaultSmoothing); XCTAssertEqual(right.rotation, 15)
        let explicit = PadProfiles.steamTrackpad(0, profile: p, all: [p])
        XCTAssertEqual(explicit.smoothing, 0); XCTAssertEqual(explicit.rotation, 0)
        // Saved profiles are not rewritten: the stored settings still have no value of their own.
        let stored = try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: JSONEncoder().encode(p.steamRightTrackpad!))
        XCTAssertNil(stored.smoothing); XCTAssertNil(stored.rotation)
    }
}
