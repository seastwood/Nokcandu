import XCTest
import simd
@testable import NokcanduCore

final class ControllerOverlayTests: XCTestCase {
    /// Flat on a table: gravity reads +1 g out of the face.
    private let flat: [Float] = [0, 1, 0]

    private func angle(_ q: simd_quatf) -> Float { 2 * acos(min(1, abs(q.real))) * 180 / .pi }

    func testStartsAtRestFacingTheFront() {
        var m = ControllerOverlayMotion()
        m.update(gyro: [0, 0, 0], acceleration: flat, at: 0)
        for i in 1...100 { m.update(gyro: [0, 0, 0], acceleration: flat, at: Double(i) / 250) }
        XCTAssertLessThan(angle(m.orientation()), 0.1)
    }

    /// Turning left (counter-clockwise from above, +y) at 90°/s for half a second: about 45° about up, leaving the
    /// tilt alone. The heading's slow return takes off a little.
    func testTurningIsIntegrated() {
        var m = ControllerOverlayMotion()
        m.update(gyro: [0, 0, 0], acceleration: flat, at: 0)
        let rate = Float.pi / 2
        for i in 1...125 { m.update(gyro: [0, rate, 0], acceleration: flat, at: Double(i) / 250) }
        let q = m.orientation()
        XCTAssertEqual(angle(q), 45, accuracy: 4)
        XCTAssertEqual(q.axis.y, 1, accuracy: 0.01, "about up")
        XCTAssertEqual(ControllerOverlayMotion.heading(q) * 180 / .pi, 45, accuracy: 4)
        // Strength scales what's drawn.
        XCTAssertEqual(angle(m.orientation(strength: 0.5)), 22.5, accuracy: 2)
        XCTAssertLessThan(angle(m.orientation(strength: 0)), 0.01)
    }

    /// The heading drifts back to the front; there's no compass to say where the front is otherwise.
    func testHeadingReturnsToTheFront() {
        var m = ControllerOverlayMotion()
        m.update(gyro: [0, 0, 0], acceleration: flat, at: 0)
        for i in 1...125 { m.update(gyro: [0, .pi / 2, 0], acceleration: flat, at: Double(i) / 250) }
        for i in 126...(126 + 250 * 20) { m.update(gyro: [0, 0, 0], acceleration: flat, at: Double(i) / 250) }
        XCTAssertLessThan(angle(m.orientation()), 1)
    }

    /// Tilting forward 30° with the gyro reading nothing (a gyro that missed it): gravity brings the drawing to 30°.
    func testGravityCorrectsTheTilt() {
        var m = ControllerOverlayMotion()
        m.headingReturn = 0; m.neutralReturn = 0
        m.update(gyro: [0, 0, 0], acceleration: flat, at: 0)
        let t: Float = 30 * .pi / 180
        // Pitched about x: up, in the controller's terms, leans towards −z.
        let tilted: [Float] = [0, cos(t), -sin(t)]
        for i in 1...(250 * 5) { m.update(gyro: [0, 0, 0], acceleration: tilted, at: Double(i) / 250) }
        XCTAssertEqual(angle(m.orientation()), 30, accuracy: 1)
        XCTAssertEqual(abs(m.orientation().axis.x), 1, accuracy: 0.02, "about x")
    }

    /// Held the usual way, tipped up 60° (as a held Steam Controller was measured): drawn level; turning about the
    /// room's up turns the drawing about its up; rolling about its own length rolls the drawing about its length.
    func testHeldTippedIsLevelAndEachMovementShowsAsItself() {
        func run(_ axis: (simd_quatf) -> SIMD3<Float>) -> simd_quatf {
            var m = ControllerOverlayMotion()
            m.headingReturn = 0; m.neutralReturn = 0
            let t: Float = 60 * .pi / 180
            let tipped: [Float] = [0, cos(t), -sin(t)]          // the front raised: up leans towards −z
            m.update(gyro: [0, 0, 0], acceleration: tipped, at: 0)
            XCTAssertLessThan(angle(m.orientation()), 0.5, "the usual hold is drawn level")
            var attitude = simd_quatf(angle: t, axis: SIMD3(1, 0, 0))   // controller → room
            let rate: Float = .pi / 2, dt: Float = 1 / 250
            for i in 1...125 {
                let w = attitude.inverse.act(axis(attitude)) * rate          // in the controller's terms
                attitude = simd_normalize(attitude * simd_quatf(angle: rate * dt, axis: simd_normalize(w)))
                let g = attitude.inverse.act(SIMD3<Float>(0, 1, 0))
                m.update(gyro: [w.x, w.y, w.z], acceleration: [g.x, g.y, g.z], at: Double(i) / 250)
            }
            return m.orientation()
        }
        let turned = run { _ in SIMD3(0, 1, 0) }                             // about the room's up
        XCTAssertEqual(angle(turned), 45, accuracy: 3)
        XCTAssertEqual(abs(turned.axis.y), 1, accuracy: 0.03, "turning shows as turning")
        let rolled = run { $0.act(SIMD3(0, 0, 1)) }                          // about its own length
        XCTAssertEqual(angle(rolled), 45, accuracy: 3)
        XCTAssertEqual(abs(rolled.axis.z), 1, accuracy: 0.03, "rolling shows as rolling")
    }

    /// Put down or held differently, it settles back to level by itself once it's still.
    func testUsualHoldIsLearnedWhileStill() {
        var m = ControllerOverlayMotion()
        m.update(gyro: [0, 0, 0], acceleration: [0, 1, 0], at: 0)
        let t: Float = 25 * .pi / 180
        let tipped: [Float] = [0, cos(t), -sin(t)]
        for i in 1...(250 * 10) { m.update(gyro: [0, 0, 0], acceleration: tipped, at: Double(i) / 250) }
        XCTAssertLessThan(angle(m.orientation()), 1)
    }

    /// Shaking (far from 1 g) isn't taken as gravity.
    func testShakesAreIgnored() {
        var m = ControllerOverlayMotion()
        m.update(gyro: [0, 0, 0], acceleration: flat, at: 0)
        for i in 1...250 { m.update(gyro: [0, 0, 0], acceleration: [2.5, 0.2, 0], at: Double(i) / 250) }
        XCTAssertLessThan(angle(m.orientation()), 0.1)
    }

    /// A resting gyro that reads a little isn't drawn as turning.
    func testSmallBiasDoesNotTurnIt() {
        var m = ControllerOverlayMotion()
        m.update(gyro: [0, 0, 0], acceleration: flat, at: 0)
        for i in 1...(250 * 30) { m.update(gyro: [0.004, -0.003, 0.002], acceleration: flat, at: Double(i) / 250) }
        XCTAssertLessThan(angle(m.orientation()), 1)
    }

    func testRecenterMakesNowTheRest() {
        var m = ControllerOverlayMotion()
        m.headingReturn = 0
        m.update(gyro: [0, 0, 0], acceleration: flat, at: 0)
        for i in 1...125 { m.update(gyro: [0, .pi / 2, 0], acceleration: flat, at: Double(i) / 250) }
        XCTAssertGreaterThan(angle(m.orientation()), 40)
        m.recenter()
        XCTAssertLessThan(angle(m.orientation()), 0.01)
    }

    func testSettingsDecodeTolerantlyAndClamp() throws {
        let s = try JSONDecoder().decode(ControllerOverlaySettings.self, from: Data(#"{"mode":"window","size":5000,"opacity":-1,"model":"future"}"#.utf8))
        XCTAssertEqual(s.mode, .window)
        XCTAssertEqual(s.size, ControllerOverlaySettings.sizes.upperBound)
        XCTAssertEqual(s.opacity, 0.1)
        XCTAssertEqual(s.model, .automatic, "an unknown model falls back")
        let first = try JSONDecoder().decode(ControllerOverlaySettings.self, from: Data(#"{"model":"steam2015"}"#.utf8))
        XCTAssertEqual(first.model, .automatic, "the first version's only choice becomes the controller in use")
        XCTAssertEqual(try JSONDecoder().decode(ControllerOverlaySettings.self, from: Data("{}".utf8)), ControllerOverlaySettings())
        XCTAssertEqual(ControllerOverlaySettings().mode, .off)
        XCTAssertTrue(s.hideWithoutController, "hidden without a controller unless turned off")
    }

    func testColours() {
        let c = ControllerOverlaySettings.rgb("#3FA9FF")!
        XCTAssertEqual(ControllerOverlaySettings.hex(r: c.r, g: c.g, b: c.b), "#3FA9FF")
        XCTAssertNil(ControllerOverlaySettings.rgb("blue"))
    }

    func testModelsByName() {
        typealias M = ControllerOverlaySettings.Model
        XCTAssertEqual(M.forName("Steam Controller (2026 · USB)"), .steam2026)
        XCTAssertEqual(M.forName("Steam Controller (2015 · Wireless)"), .steam2015)
        XCTAssertEqual(M.forName("Pro Controller"), .switchPro)
        XCTAssertEqual(M.forName("DualShock 4"), .dualShock4)
        XCTAssertEqual(M.forName("Wireless Controller"), .dualShock4)
        XCTAssertEqual(M.forName("Xbox Wireless Controller"), .xbox)
        XCTAssertEqual(M.forName("8BitDo Ultimate"), .xbox)
    }

    func testInputFromAxes() {
        let i = ControllerOverlayInput(buttons: [.a], axes: [0: 32767, 1: -32767, 3: 16384, 4: 32767, 5: -100])
        XCTAssertEqual(i.leftStick.x, 1); XCTAssertEqual(i.leftStick.y, 1, "y up")
        XCTAssertEqual(i.rightStick.y, -0.5, accuracy: 0.01)
        XCTAssertEqual(i.leftTrigger, 1); XCTAssertEqual(i.rightTrigger, 0)
        XCTAssertEqual(i.buttons, [.a])
    }

    /// Reports that change nothing visible aren't redrawn.
    func testOnlyVisibleChangesCount() {
        var a = ControllerOverlayInput(), b = a
        b.leftStick.x = 0.004
        XCTAssertTrue(a.looksLike(b))
        b.leftStick.x = 0.2
        XCTAssertFalse(a.looksLike(b))
        b = a; b.leftPad = .init(0.5, 0.5)
        XCTAssertTrue(a.looksLike(b), "a pad that isn't touched isn't drawn")
        b.leftTouch = true
        XCTAssertFalse(a.looksLike(b))
        a = b; b.buttons = [.a]
        XCTAssertFalse(a.looksLike(b))
    }
}

private extension SIMD3 where Scalar == Float { var array: [Float] { [x, y, z] } }
