import XCTest
@testable import NokcanduCore

final class PadVelocityStickTests: XCTestCase {
    var settings: PadSteamTrackpadSettings { PadSteamTrackpadSettings(mode: .velocityStick) }

    func testStillFingerLeavesTheStickCentred() {
        var s = PadVelocityStick()
        s.touch(down: true, x: 0.6, y: -0.3, at: 0, settings: settings)
        for i in 1...20 { s.touch(down: true, x: 0.6, y: -0.3, at: Double(i) * 0.004, settings: settings) }
        XCTAssertEqual(s.vector(settings).x, 0); XCTAssertEqual(s.vector(settings).y, 0)
    }

    func testSpeedSetsTiltAndDirection() {
        var s = PadVelocityStick()
        // 0.75 pad widths a second to the right: half of the default full speed.
        s.touch(down: true, x: -0.5, y: 0, at: 0, settings: settings)
        var x = -0.5
        for i in 1...50 { x += 1.5 * 0.004; s.touch(down: true, x: x, y: 0, at: Double(i) * 0.004, settings: settings) }
        XCTAssertEqual(s.vector(settings).x, 0.5, accuracy: 0.02)
        XCTAssertEqual(s.vector(settings).y, 0, accuracy: 0.001)
    }

    func testRestingFingerReturnsToCentreWithoutNewReports() {
        var s = PadVelocityStick()
        s.touch(down: true, x: -0.5, y: 0, at: 0, settings: settings)
        s.touch(down: true, x: -0.4, y: 0, at: 0.004, settings: settings)
        XCTAssertGreaterThan(s.vector(settings).x, 0)
        var t = 0.004
        for _ in 0..<60 { t += 0.004; _ = s.tick(at: t, settings: settings) }
        XCTAssertEqual(s.vector(settings).x, 0)
    }

    func testLiftStopsUnlessInertia() {
        var s = PadVelocityStick()
        s.touch(down: true, x: -0.5, y: 0, at: 0, settings: settings)
        s.touch(down: true, x: -0.4, y: 0, at: 0.004, settings: settings)
        s.touch(down: false, x: 0, y: 0, at: 0.008, settings: settings)
        XCTAssertEqual(s.vector(settings).x, 0)

        var coast = settings; coast.velocityInertia = true; coast.halfLife = 0.1
        var c = PadVelocityStick()
        c.touch(down: true, x: -0.5, y: 0, at: 0, settings: coast)
        c.touch(down: true, x: -0.49, y: 0, at: 0.004, settings: coast)
        c.touch(down: false, x: 0, y: 0, at: 0.008, settings: coast)
        let start = c.vector(coast).x
        XCTAssertGreaterThan(start, 0)
        _ = c.tick(at: 0.008, settings: coast); _ = c.tick(at: 0.108, settings: coast)
        XCTAssertEqual(c.vector(coast).x, start / 2, accuracy: 0.05)
        // Touching again stops the coast at once.
        c.touch(down: true, x: 0, y: 0, at: 0.11, settings: coast)
        XCTAssertEqual(c.vector(coast).x, 0)
    }

    func testRealStickPushedFurtherWins() {
        var state = SteamControllerReport.State(counter: 0, buttons: [], stick: .init(0.9, 0), leftPad: .init(), rightPad: .init(),
                                                leftTouch: true, rightTouch: false, leftTrigger: 0, rightTrigger: 0, gyro: [0,0,0], acceleration: [0,0,0])
        var axes = [0: 29490, 1: 0]
        PadVelocityStick.apply((x: 0.3, y: 0), side: 0, to: &axes, state: state)
        XCTAssertEqual(axes[0], 29490)
        state.stick = .init()
        PadVelocityStick.apply((x: 0.3, y: 0.5), side: 0, to: &axes, state: state)
        XCTAssertEqual(axes[0], Int(0.3 * 32767)); XCTAssertEqual(axes[1], Int(-0.5 * 32767))
    }
}
