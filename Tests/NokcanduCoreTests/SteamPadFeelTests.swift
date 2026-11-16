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

    /// Straight flicks: a quick swipe a few degrees off an axis comes out straight, with the same distance
    /// along the axis on every report; slow movement and diagonals are left exactly as they were.
    func testStraightFlicksStraightenQuickNearAxisSwipesOnly() {
        func settings(_ cone: Double?) -> PadSteamTrackpadSettings {
            var s = PadSteamTrackpadSettings(mode: .trackball); s.sensitivity = 1000; s.smoothing = 0; s.rotation = 0; s.straighten = cone; return s
        }
        func swipe(_ s: PadSteamTrackpadSettings, speed: Double, degrees: Double, seconds: Double) -> (x: Double, y: Double, steps: [Double]) {
            var pad = PadSteamTrackpad(), x = 0.0, y = 0.0, steps: [Double] = [], t = 0.0
            let r = degrees * Double.pi / 180
            while t <= seconds {
                let m = pad.touch(down: true, x: 0.5 + sin(r) * speed * t, y: 0.8 - cos(r) * speed * t, at: 10 + t, settings: s)
                x += m.fx; y += m.fy; steps.append(m.fy); t += 0.008
            }
            return (x, y, steps)
        }
        // A flick up, 8° off, at 2 pad-widths a second.
        let off = swipe(settings(nil), speed: 2, degrees: 8, seconds: 0.12), straight = swipe(settings(30), speed: 2, degrees: 8, seconds: 0.12)
        XCTAssertGreaterThan(off.x, 25, "as it was: the flick drifts sideways")
        XCTAssertLessThan(abs(straight.x), 4, "straightened")
        XCTAssertEqual(straight.y, off.y, accuracy: 0.001, "the movement along the flick is untouched")
        XCTAssertEqual(straight.steps, off.steps, "on every report: nothing is delayed")
        // The same 8° off, slowly: untouched.
        let slow = swipe(settings(nil), speed: 0.3, degrees: 8, seconds: 0.5), slowOn = swipe(settings(30), speed: 0.3, degrees: 8, seconds: 0.5)
        XCTAssertEqual(slowOn.x, slow.x, accuracy: 0.001); XCTAssertEqual(slowOn.y, slow.y, accuracy: 0.001)
        // A quick diagonal: untouched.
        let diagonal = swipe(settings(nil), speed: 2, degrees: 40, seconds: 0.12), diagonalOn = swipe(settings(30), speed: 2, degrees: 40, seconds: 0.12)
        XCTAssertEqual(diagonalOn.x, diagonal.x, accuracy: 0.001); XCTAssertEqual(diagonalOn.y, diagonal.y, accuracy: 0.001)
        // Across works the same way.
        let across = swipe(settings(30), speed: 2, degrees: 97, seconds: 0.12)
        XCTAssertLessThan(abs(across.y), 4); XCTAssertGreaterThan(across.x, 150)
        // A quick turn from up to across: the movement across is not mistaken for the flick's sideways part.
        var pad = PadSteamTrackpad(), t = 0.0, x = 0.5, y = 0.8, turned = 0.0, turnedSteps = 0
        while t <= 0.2 {
            if t < 0.1 { y -= 0.016 } else { x += 0.016 }
            let m = pad.touch(down: true, x: x, y: y, at: 10 + t, settings: settings(30))
            if t >= 0.1 { turned += m.fx; turnedSteps += 1 }
            t += 0.008
        }
        XCTAssertEqual(turned, Double(turnedSteps) * 16, accuracy: 0.5, "all of the movement after the turn arrives")
        XCTAssertEqual(PadSteamTrackpad.straighten(vx: 0.2, vy: -2, cone: 0).keep, 1)
        XCTAssertEqual(PadSteamTrackpad.straighten(vx: 0.2, vy: -2, cone: 30).keep, 0)
    }

    /// A finger that slows right down and goes on (a careful aim, a change of direction) keeps the pointer
    /// going with it on a quiet pad: the pointer used to stop below 0.05 pad-widths a second and drop the next
    /// 0.008 of the pad.
    func testASlowFingerOnAQuietPadKeepsThePointerMoving() {
        var s = PadSteamTrackpadSettings(mode: .trackball); s.sensitivity = 1000; s.smoothing = 0; s.rotation = 0
        var pad = PadSteamTrackpad(), t = 0.0, x = 0.3, moved = 0.0, slowSteps = 0, slowStalls = 0
        _ = pad.touch(down: true, x: x, y: 0.5, at: 10, settings: s)
        while t < 0.8 {
            t += 0.008
            let slow = t > 0.2 && t <= 0.6
            x += (slow ? 0.02 : 0.3) * 0.008
            let m = pad.touch(down: true, x: x, y: 0.5, at: 10 + t, settings: s)
            moved += m.fx
            if slow, t > 0.3 { slowSteps += 1; if m.fx == 0 { slowStalls += 1 } }
        }
        XCTAssertEqual(slowStalls, 0, "of \(slowSteps) slow reports")
        XCTAssertGreaterThan(moved, (x - 0.3) * 1000 - 10, "all but the landing distance arrives")
        XCTAssertLessThan(moved, (x - 0.3) * 1000 + 0.5)
    }

    /// Match sideways sensitivity: an up/down movement's sideways wander is drawn at the lower (Y) sensitivity;
    /// a movement across keeps the full X; the movement along the lower axis is identical on every report.
    func testAccelerationLeavesSlowAimAloneAndBoostsFastSwipes() {
        XCTAssertEqual(PadSteamTrackpad.accelerationGain(speed: 0, amount: 1, full: 3), 1)
        XCTAssertEqual(PadSteamTrackpad.accelerationGain(speed: 3, amount: 1, full: 3), 2, accuracy: 1e-9)
        XCTAssertEqual(PadSteamTrackpad.accelerationGain(speed: 30, amount: 1, full: 3), 2, accuracy: 1e-9)
        XCTAssertLessThan(PadSteamTrackpad.accelerationGain(speed: 0.2, amount: 1, full: 3), 1.02, "slow aim stays nearly as set")
        XCTAssertEqual(PadSteamTrackpad.accelerationGain(speed: 5, amount: nil ?? 0, full: 3), 1)
        var accel = settings(); accel.acceleration = 1
        // A slow aim (a fifth of the pad a second) barely changes; a fast swipe (five pads a second) doubles.
        let slowOff = run(settings(), seconds: 1) { t in (0.3 + t * 0.2, 0.5) }
        let slowOn = run(accel, seconds: 1) { t in (0.3 + t * 0.2, 0.5) }
        XCTAssertEqual(Double(slowOn.x), Double(slowOff.x), accuracy: Double(slowOff.x) * 0.03)
        let fastOff = run(settings(), seconds: 0.12) { t in (0.2 + t * 5, 0.5) }
        let fastOn = run(accel, seconds: 0.12) { t in (0.2 + t * 5, 0.5) }
        XCTAssertGreaterThan(Double(fastOn.x), Double(fastOff.x) * 1.7)
        // The same gain on both axes: a diagonal keeps its direction.
        let diagonal = run(accel, seconds: 0.12) { t in (0.2 + t * 4, 0.2 + t * 3) }
        XCTAssertEqual(Double(diagonal.y) / Double(diagonal.x), 0.75, accuracy: 0.03)
    }

    func testMatchSidewaysSensitivityFollowsTheDirection() {
        func settings(_ on: Bool) -> PadSteamTrackpadSettings {
            var s = PadSteamTrackpadSettings(mode: .mouse); s.sensitivityX = 2200; s.sensitivityY = 1100; s.smoothing = 0; s.rotation = 0
            s.matchSideways = on ? nil : false; return s
        }
        func run(_ s: PadSteamTrackpadSettings, path: (Double) -> (Double, Double)) -> (x: Double, y: Double, ySteps: [Double]) {
            var pad = PadSteamTrackpad(), x = 0.0, y = 0.0, steps: [Double] = [], t = 0.0
            while t <= 0.5 {
                let p = path(t)
                let m = pad.touch(down: true, x: p.0, y: p.1, at: 10 + t, settings: s)
                x += m.fx; y += m.fy; steps.append(m.fy); t += 0.008
            }
            return (x, y, steps)
        }
        // Up, at 0.6 pad-widths a second, drifting 0.03 of the pad sideways.
        let up: (Double) -> (Double, Double) = { t in (0.5 + 0.06 * t, 0.8 - 0.6 * t) }
        let off = run(settings(false), path: up), on = run(settings(true), path: up)
        XCTAssertEqual(on.ySteps, off.ySteps, "up and down is untouched, report by report")
        XCTAssertLessThan(on.x, off.x * 0.6, "the sideways drift is drawn at about Y's sensitivity, not X's")
        XCTAssertGreaterThan(on.x, off.x * 0.45)
        // Across: full X.
        let across: (Double) -> (Double, Double) = { t in (0.2 + 0.6 * t, 0.5) }
        let acrossOff = run(settings(false), path: across), acrossOn = run(settings(true), path: across)
        XCTAssertEqual(acrossOn.x, acrossOff.x, accuracy: acrossOff.x * 0.03)
        // Unset is on (the default); only an explicit false turns it off.
        var unset = settings(true); unset.matchSideways = nil
        XCTAssertEqual(run(unset, path: up).x, on.x, accuracy: 0.001)
        // The modes, for X 2,000 and Y 1,000 (the direction's value: Y's straight up, X's straight across).
        typealias Mode = PadSteamTrackpadSettings.DirectionalSensitivity
        func m(_ mode: Mode, _ vx: Double, _ vy: Double) -> (x: Double, y: Double) { PadSteamTrackpad.matchedSensitivity(x: 2000, y: 1000, vx: vx, vy: vy, mode: mode) }
        XCTAssertEqual(m(.x, 0, 1).x, 1000); XCTAssertEqual(m(.x, 0, 1).y, 1000)      // up: X down to Y
        XCTAssertEqual(m(.x, 1, 0).x, 2000); XCTAssertEqual(m(.x, 1, 0).y, 1000)      // across: as set
        XCTAssertEqual(m(.y, 0, 1).x, 2000); XCTAssertEqual(m(.y, 0, 1).y, 1000)      // up: as set
        XCTAssertEqual(m(.y, 1, 0).x, 2000); XCTAssertEqual(m(.y, 1, 0).y, 2000)      // across: Y up to X
        XCTAssertEqual(m(.both, 0, 1).x, 1000); XCTAssertEqual(m(.both, 1, 0).y, 2000)
        XCTAssertEqual(m(.both, 1, 1).x, 1500, accuracy: 0.001); XCTAssertEqual(m(.both, 1, 1).y, 1500, accuracy: 0.001)
        XCTAssertEqual(m(.off, 0, 1).x, 2000); XCTAssertEqual(m(.off, 0, 1).y, 1000)
        // Unset is Highest toward lowest: the higher one varies, whichever axis it is.
        XCTAssertEqual(m(.higher, 0, 1).x, 1000); XCTAssertEqual(m(.higher, 1, 0).x, 2000); XCTAssertEqual(m(.higher, 1, 0).y, 1000)
        var yHigher = PadSteamTrackpadSettings(mode: .mouse); yHigher.sensitivityX = 1000; yHigher.sensitivityY = 2000
        XCTAssertEqual(yHigher.directional, .higher)
        let yAcross = PadSteamTrackpad.matchedSensitivity(x: 1000, y: 2000, vx: 1, vy: 0, mode: yHigher.directional)
        XCTAssertEqual(yAcross.x, 1000); XCTAssertEqual(yAcross.y, 1000)             // across: Y down to X
        // The earlier on/off setting still reads: false is Off; unset follows the higher axis.
        var old = PadSteamTrackpadSettings(mode: .mouse); old.sensitivityX = 2000; old.sensitivityY = 1000
        XCTAssertEqual(old.directional, .higher)
        old.matchSideways = false; XCTAssertEqual(old.directional, .off)
        old.directionalSensitivity = .both; XCTAssertEqual(old.directional, .both)
        // Equal sensitivities: nothing changes.
        XCTAssertEqual(PadSteamTrackpad.matchedSensitivity(x: 1000, y: 1000, vx: 0, vy: 1, mode: .both).x, 1000)
        XCTAssertEqual(PadSteamTrackpad.matchedSensitivity(x: 2000, y: 1000, vx: 1, vy: 1, mode: .x).x, 1500, accuracy: 0.001)
        XCTAssertEqual(PadSteamTrackpad.matchedSensitivity(x: 1000, y: 2000, vx: 1, vy: 0, mode: .y).y, 1000, accuracy: 0.001)
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
