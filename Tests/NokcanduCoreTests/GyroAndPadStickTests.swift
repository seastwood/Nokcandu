import XCTest
@testable import NokcanduCore
import NokcanduPadEngine

/// Gyro turning about gravity, gyro scrolling and real-world sensitivity; a trackpad as an analog stick; pad taps.
final class GyroAndPadStickTests: XCTestCase {
    private let rad = Float.pi / 180
    /// 100 gyro reports at 100 Hz turning at `degrees` per second about each axis given.
    private func turn(_ r: PadRecorder, x: Float = 0, y: Float = 0, z: Float = 0, from t0: Double = 10) {
        for i in 0...100 { pe_gyro(r.engine, x * rad, y * rad, z * rad, t0 + Double(i) * 0.01) }
    }

    func testTurningAboutGravityFollowsHowTheControllerIsHeld() {
        // Held upright (gravity along the controller's z): turning about the vertical reads on z.
        let world = PadRecorder("gyro out=mouse on=1 min=10 max=10 cal=off world=1")
        for i in 0..<60 { pe_accel(world.engine, 0, 0, 1, 9 + Double(i) * 0.01) }
        turn(world, z: 30)
        let plain = PadRecorder("gyro out=mouse on=1 min=10 max=10 cal=off yaw=yaw")
        turn(plain, z: 30)
        XCTAssertEqual(plain.mouse.x, 0, "controller-space yaw ignores that axis")
        XCTAssertEqual(abs(world.mouse.x), 300, accuracy: 15, "about 30 °/s × 1 s × 10")
        // Held flat (gravity along y): the same as ordinary yaw.
        let flat = PadRecorder("gyro out=mouse on=1 min=10 max=10 cal=off world=1")
        for i in 0..<60 { pe_accel(flat.engine, 0, 1, 0, 9 + Double(i) * 0.01) }
        turn(flat, y: 30)
        let flatPlain = PadRecorder("gyro out=mouse on=1 min=10 max=10 cal=off yaw=yaw")
        turn(flatPlain, y: 30)
        XCTAssertEqual(flat.mouse.x, flatPlain.mouse.x, accuracy: 3)
        XCTAssertTrue(pe_uses_tilt(world.engine), "turning about gravity asks for the accelerometer")
        XCTAssertFalse(pe_uses_tilt(plain.engine))
    }

    func testGyroCanScroll() {
        let r = PadRecorder("gyro out=scroll on=1 cal=off scrollrate=0.5")
        turn(r, x: 20)
        let ticks = r.take().compactMap { $0.hasPrefix("wheel ") ? Int($0.dropFirst(6)) : nil }
        XCTAssertEqual(abs(ticks.reduce(0, +)), 10, accuracy: 1, "20 °/s for a second at half a step per degree")
        XCTAssertTrue(Set(ticks.map { $0 > 0 }).count == 1, "one direction only")
        XCTAssertEqual(r.mouse.x, 0); XCTAssertEqual(r.mouse.y, 0)
        let back = PadRecorder("gyro out=scroll on=1 cal=off scrollrate=0.5")
        turn(back, x: -20)
        let other = back.take().compactMap { $0.hasPrefix("wheel ") ? Int($0.dropFirst(6)) : nil }
        XCTAssertEqual(ticks.first.map { $0 > 0 }, other.first.map { $0 < 0 }, "tipping the other way scrolls the other way")
    }

    func testRealWorldSensitivityComesFromTheGamesFullTurn() {
        var g = PadProfiles.Gyro(output: .mouse); g.realWorld = 1; g.countsPerTurn = 3600
        XCTAssertEqual(g.effectiveSensitivity.slow, 10); XCTAssertEqual(g.effectiveSensitivity.fast, 10)
        var p = PadProfiles.Profile(name: "RW"); p.gyro = g
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.contains("min=10 max=10"), text)
        g.realWorld = nil; g.sensitivity = 7
        XCTAssertEqual(g.effectiveSensitivity.slow, 7)
        let old = try? JSONDecoder().decode(PadProfiles.Gyro.self, from: JSONEncoder().encode(PadProfiles.Gyro(output: .mouse)))
        XCTAssertNil(old?.worldSpace); XCTAssertNil(old?.realWorld)
    }

    func testAPadAsAnAnalogStick() {
        var s = PadSteamTrackpadSettings(mode: .stick); s.rotation = 0
        XCTAssertEqual(PadSteamPadStick.vector(x: 0.05, y: 0, settings: s).x, 0, "inside the dead zone")
        XCTAssertEqual(PadSteamPadStick.vector(x: 0.95, y: 0, settings: s).x, 1, "full just inside the rim")
        let half = PadSteamPadStick.vector(x: 0.49, y: 0, settings: s).x
        XCTAssertGreaterThan(half, 0.45); XCTAssertLessThan(half, 0.55)
        var state = SteamControllerReport.State(counter: 1, buttons: [], stick: .init(0.1, 0), leftPad: .init(0, 0.95), rightPad: .init(0.5, 0),
                                                leftTouch: true, rightTouch: true, leftTrigger: 0, rightTrigger: 0, gyro: [0, 0, 0], acceleration: [0, 1, 0])
        let axes = state.mappingAxes(left: s, right: PadSteamTrackpadSettings(mode: .trackball))
        XCTAssertEqual(axes[1], -32767, "left pad pushed up drives the left stick up (y down axis)")
        XCTAssertEqual(axes[0], 0)
        XCTAssertEqual(axes[2], 0, "a mouse-mode right pad stays off the right stick")
        state.leftTouch = false
        XCTAssertEqual(state.mappingAxes(left: s, right: PadSteamTrackpadSettings(mode: .trackball))[0], state.axes[0], "the joystick when the pad isn't touched")
        state.stick = .init(1, 0); state.leftTouch = true
        XCTAssertEqual(state.mappingAxes(left: s, right: PadSteamTrackpadSettings())[0], 32767, "whichever is pushed further wins")
        XCTAssertEqual(state.mappingAxes(left: PadSteamTrackpadSettings(), right: PadSteamTrackpadSettings()), state.axes, "older settings unchanged")
        var r = PadSteamTrackpadSettings(mode: .stick); r.rotation = 0
        XCTAssertEqual(state.mappingAxes(left: PadSteamTrackpadSettings(), right: r)[2], Int(Float(PadSteamPadStick.vector(x: 0.5, y: 0, settings: r).x) * 32767))
        var move = PadSteamTrackpad()
        _ = move.touch(down: true, x: 0.2, y: 0.5, at: 1, settings: s)
        XCTAssertEqual(move.touch(down: true, x: 0.8, y: 0.5, at: 1.004, settings: s), PadSteamTrackpad.Motion(), "a stick pad doesn't move the pointer")
    }

    func testTapsAreQuickTouchesHeldForAMoment() {
        var t = PadSteamTap()
        XCTAssertEqual(t.update(down: true, x: 0, y: 0, at: 1), .none)
        XCTAssertEqual(t.update(down: true, x: 0.02, y: 0, at: 1.05), .none)
        XCTAssertEqual(t.update(down: false, x: 0, y: 0, at: 1.1), .press)
        XCTAssertFalse(t.tick(at: 1.12))
        XCTAssertTrue(t.tick(at: 1.16), "released after a moment")
        XCTAssertFalse(t.tick(at: 1.2))
        XCTAssertEqual(t.update(down: true, x: 0, y: 0, at: 2), .none)
        XCTAssertEqual(t.update(down: false, x: 0, y: 0, at: 2.5), .none, "held too long: not a tap")
        XCTAssertEqual(t.update(down: true, x: -0.5, y: 0, at: 3), .none)
        XCTAssertEqual(t.update(down: true, x: 0.2, y: 0, at: 3.05), .none)
        XCTAssertEqual(t.update(down: false, x: 0.2, y: 0, at: 3.1), .none, "a swipe is not a tap")
        // Without ticks, the next report releases it.
        _ = t.update(down: true, x: 0, y: 0, at: 4); XCTAssertEqual(t.update(down: false, x: 0, y: 0, at: 4.05), .press)
        XCTAssertEqual(t.update(down: false, x: 0, y: 0, at: 4.2), .release)
    }

    func testEngineDoubleTapOnAPad() {
        let r = PadRecorder("bind 0 lptap tap=key:49 double=key:36")
        let tap = pe_input_named("lptap")
        XCTAssertGreaterThanOrEqual(tap, 0)
        for (i, t) in [1.0, 1.15].enumerated() {
            pe_pad_zone(r.engine, tap, true, t); pe_pad_zone(r.engine, tap, false, t + 0.05)
            _ = i
        }
        for i in 0..<80 { r.tick(1.3 + Double(i) * 0.01) }
        let events = r.take()
        XCTAssertTrue(events.contains("key 36 down"), "\(events)")
        XCTAssertFalse(events.contains("key 49 down"), "\(events)")
    }
}

final class GyroDriftRecoveryTests: XCTestCase {
    func testABadFirstMeasurementIsCorrectedByTheNextRest() {
        let rad = Float.pi / 180
        let r = PadRecorder("gyro out=mouse on=1 min=10 max=10 cal=auto")
        // First rest measured while the hand was turning slowly at 4 °/s (the bad measurement).
        for n in 0...250 { pe_gyro(r.engine, 0, 4 * rad, 0, 1 + Double(n) * 0.01) }
        // Then put down: the gyro's real resting reading is 0.
        for n in 0...500 { pe_gyro(r.engine, 0, 0, 0, 40 + Double(n) * 0.01) }
        r.mouse = (0, 0)
        for n in 0...100 { pe_gyro(r.engine, 0, 0, 0, 50 + Double(n) * 0.01) }
        XCTAssertEqual(r.mouse.x, 0, "no drift once it has rested again")
    }
}
