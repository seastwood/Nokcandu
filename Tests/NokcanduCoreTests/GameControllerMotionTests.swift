import XCTest
import simd
@testable import NokcanduCore

final class GameControllerMotionTests: XCTestCase {
    /// Lying flat, face up: GameController's gravity points down its z (out of the face); SDL reads +1 g on y.
    func testFlatGravityReadsUpOnY() {
        XCTAssertEqual(GameControllerMotion.acceleration(0, 0, -1), [0, 1, 0])
    }

    /// Turning (about the axis out of the face, GameController's z) is SDL's yaw (y); tilting the triggers up
    /// (about x) stays on x; rolling (about GameController's y, along the controller) is SDL's z.
    func testTurningIsYaw() {
        XCTAssertEqual(GameControllerMotion.gyro(0, 0, 2), [0, 2, 0])
        XCTAssertEqual(GameControllerMotion.gyro(1.5, 0, 0), [1.5, 0, 0])
        XCTAssertEqual(GameControllerMotion.gyro(0, 1, 0), [0, 0, -1])
    }

    /// The gyro and the accelerometer are turned the same way, so the overlay's gravity correction agrees with
    /// the gyro: turning the converted gravity by the converted rate matches converting the turned gravity.
    func testGyroAndGravityAgree() {
        let rate = SIMD3<Double>(0.3, -0.7, 0.5), gravity = simd_normalize(SIMD3<Double>(0.2, -0.4, -0.9))
        let turn = simd_quatd(angle: simd_length(rate), axis: simd_normalize(rate))
        let after = turn.inverse.act(gravity)
        func f(_ v: [Float]) -> SIMD3<Double> { SIMD3(Double(v[0]), Double(v[1]), Double(v[2])) }
        let r = f(GameControllerMotion.gyro(rate.x, rate.y, rate.z))
        let g = f(GameControllerMotion.acceleration(gravity.x, gravity.y, gravity.z))
        let expected = simd_quatd(angle: simd_length(r), axis: simd_normalize(r)).inverse.act(g)
        let got = f(GameControllerMotion.acceleration(after.x, after.y, after.z))
        XCTAssertLessThan(simd_distance(expected, got), 1e-5)
    }

    func testHeldNotificationsKeepTheLatestWithoutRepeats() {
        var h = HeldNotifications<String>(limit: 3)
        for n in ["a", "b", "a", "c", "d"] { h.hold(n) }
        XCTAssertEqual(h.release(), ["a", "c", "d"])
        XCTAssertEqual(h.release(), [])
    }

    func testHoldingIsOnUnlessTurnedOff() {
        let d = UserDefaults(suiteName: "hold-\(UUID().uuidString)")!
        XCTAssertTrue(PadNotificationPreferences.holdWhilePlaying(d))
        PadNotificationPreferences.setHoldWhilePlaying(false, defaults: d)
        XCTAssertFalse(PadNotificationPreferences.holdWhilePlaying(d))
    }

    func testNokcanduAxesReachListenersAsSDLs() {
        // A Switch Pro lying still and turned left: Nokcandu's axes (SDL's x, z, y) to SDL's (yaw on y, gravity up on y).
        let (g, a) = MotionAxes.sdl(gyro: [0, 0, 2], acceleration: [0, 0, 1])
        XCTAssertEqual(g, [0, 2, 0]); XCTAssertEqual(a, [0, 1, 0])
    }
}
