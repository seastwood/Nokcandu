import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

/// November 13, 2026: drift took too long to be corrected (a measurement needed the controller put down, at most
/// every 30 s), a good calibration was sometimes replaced by a worse one (a calm hand passed for "put down" and
/// its 1.5 s average is about a degree per second off), and every measurement showed on screen. Now: 5 s without
/// movement, in the hand or not, gives the new resting reading, silently unless it corrected a clear drift.
final class GyroQuietCalibrationTests: XCTestCase {
    private final class Rig {
        var engine: OpaquePointer?, mouse = (x: 0, y: 0), shown: [Float] = []
        init(_ profile: String = "gyro out=mouse min=10 max=10 smooth=0 tight=0 cal=auto") {
            var sink = pe_sink()
            sink.ctx = Unmanaged.passUnretained(self).toOpaque()
            sink.mouse_move = { c, x, y in let r = Unmanaged<Rig>.fromOpaque(c!).takeUnretainedValue(); r.mouse.x += Int(x); r.mouse.y += Int(y) }
            sink.calibration = { c, p in Unmanaged<Rig>.fromOpaque(c!).takeUnretainedValue().shown.append(p) }
            engine = pe_create("nokpad 1\n" + profile, sink)
        }
        deinit { pe_destroy(engine) }
        var seed: UInt64 = 5
        func noise(_ amount: Double) -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 2 * amount }
        /// A hand holding the controller: the drift plus a tremor and sensor noise, degrees/s, 110 reports a second.
        func hold(from t0: Double, seconds: Double, drift: (Double, Double, Double), tremor: Double = 1.2, turn: Double = 0, jitter: Double = 1) {
            let rad = Double.pi / 180
            var t = t0
            while t < t0 + seconds {
                let w = tremor * sin(t * 2 * .pi * 3.1)
                pe_gyro(engine, Float((drift.0 + w + noise(0.5 * jitter)) * rad), Float((drift.1 + turn + w * 0.5 + noise(0.5 * jitter)) * rad), Float((drift.2 + noise(0.3 * jitter)) * rad), t)
                t += 0.009
            }
        }
        var bias: [Double]? { var b = [0.0, 0.0, 0.0]; return pe_calibration_get(engine, &b) ? b : nil }
    }

    func testFiveQuietSecondsInTheHandCorrectTheDriftSilently() {
        let r = Rig()
        pe_calibration_set(r.engine, [0, 0, 0])                    // calibrated earlier; the drift has since changed
        r.hold(from: 10, seconds: 5.3, drift: (1.5, -0.8, 0.3))
        let b = try! XCTUnwrap(r.bias)
        XCTAssertEqual(b[0], 1.5, accuracy: 0.25); XCTAssertEqual(b[1], -0.8, accuracy: 0.25); XCTAssertEqual(b[2], 0.3, accuracy: 0.25)
        XCTAssertEqual(r.shown.filter { $0 != 1 }, [], "no progress bar and no 'keep it still'")
        XCTAssertEqual(r.shown, [1], "a drift this large (1.7 degrees/s) is announced once")
        // A small correction is not announced at all.
        r.shown = []
        r.hold(from: 15.31, seconds: 5.3, drift: (1.8, -0.8, 0.3))
        XCTAssertEqual(try XCTUnwrap(r.bias)[0], 1.8, accuracy: 0.25)
        XCTAssertEqual(r.shown, [])
        // And the pointer no longer drifts.
        r.mouse = (0, 0)
        r.hold(from: 20.62, seconds: 2, drift: (1.8, -0.8, 0.3), tremor: 0)
        XCTAssertLessThan(abs(r.mouse.x) + abs(r.mouse.y), 12)
    }

    func testACalmHandForASecondOrTwoDoesNotReplaceTheCalibration() {
        let r = Rig()
        pe_calibration_set(r.engine, [0.4, -0.6, 0.2])
        // Very calm (as still as put down by the old test) for 3.5 s, while the hand slowly turns: the old quick
        // measurement took this. A hand's readings still span more than a table's.
        r.hold(from: 10, seconds: 3.5, drift: (0.4, -0.6, 0.2), tremor: 0.6, turn: 1.2, jitter: 0.1)
        XCTAssertEqual(try XCTUnwrap(r.bias), [0.4, -0.6, 0.2])
        XCTAssertEqual(r.shown, [])
    }

    func testASlowTurnIsNotTakenForDrift() {
        // Uneven: the half-second averages disagree.
        let r = Rig()
        pe_calibration_set(r.engine, [0, 0, 0])
        let rad = Double.pi / 180
        var t = 10.0
        while t < 22 { pe_gyro(r.engine, 0, Float((2 + 1.5 * sin(t * 1.3)) * rad), 0, t); t += 0.009 }
        XCTAssertEqual(try XCTUnwrap(r.bias), [0, 0, 0])
        // Perfectly even, but gravity moves across the controller (it is being tipped at 3 degrees/s).
        let tip = Rig()
        pe_calibration_set(tip.engine, [0, 0, 0])
        t = 10
        while t < 22 {
            let a = (t - 10) * 3 * rad
            pe_accel(tip.engine, 0, Float(cos(a)), Float(sin(a)), t)
            pe_gyro(tip.engine, Float(3 * rad), 0, 0, t); t += 0.009
        }
        XCTAssertEqual(try XCTUnwrap(tip.bias), [0, 0, 0])
        // The same reading with gravity steady is drift.
        let still = Rig()
        pe_calibration_set(still.engine, [0, 0, 0])
        t = 10
        while t < 16 { pe_accel(still.engine, 0, 1, 0, t); pe_gyro(still.engine, Float(3 * rad), 0, 0, t); t += 0.009 }
        XCTAssertEqual(try XCTUnwrap(still.bias)[0], 3, accuracy: 0.05)
    }

    func testTheFirstMeasurementIsStillQuickAndCarriesOverToANewEngine() {
        let r = Rig()
        XCTAssertNil(r.bias)
        r.hold(from: 10, seconds: 2.3, drift: (0.7, 0.2, -0.4), tremor: 0, jitter: 0.1)      // put down
        let b = try! XCTUnwrap(r.bias)
        XCTAssertEqual(b[0], 0.7, accuracy: 0.2)
        XCTAssertEqual(r.shown, [1])
        let next = Rig("gyro out=mouse min=4 max=4 cal=auto")
        pe_calibration_set(next.engine, b)
        XCTAssertEqual(next.bias, b)
        next.hold(from: 20, seconds: 3, drift: (0.7, 0.2, -0.4), tremor: 0, jitter: 0.1)
        XCTAssertEqual(next.shown, [], "nothing to show again")
        // Put down with a changed drift: corrected within three seconds, without waiting for the five.
        pe_gyro(next.engine, 1, 1, 1, 29.9)                                   // picked up and
        next.hold(from: 30, seconds: 3, drift: (0.2, 0.2, -0.4), tremor: 0, jitter: 0.1)
        XCTAssertEqual(try XCTUnwrap(next.bias)[0], 0.2, accuracy: 0.1)
    }

    func testWithAutomaticCalibrationOffNothingChanges() {
        let r = Rig("gyro out=mouse min=10 max=10 cal=off")
        r.hold(from: 10, seconds: 12, drift: (1.5, 0, 0))
        XCTAssertNil(r.bias)
    }
}

/// November 13, 2026: "why does my controller's layer change when I switch windows?" A change of the app in
/// front released everything, including the layer the player had switched on and the gyro's on/off toggle.
final class PadFocusKeepsLayerTests: XCTestCase {
    func testAToggledLayerAndGyroSurviveAWindowSwitchWhileHeldKeysAreLetGo() {
        let r = PadRecorder("gyro out=mouse\nbind 0 back press=layer:toggle:1\nbind 0 start press=gyro:toggle\nbind 0 a press=key:1\nbind 1 a press=key:2\nbind 0 b press=keytoggle:3")
        r.press("back", true, 1); r.press("back", false, 1.05)
        r.press("start", true, 1.1); r.press("start", false, 1.15)
        XCTAssertEqual(pe_active_layer(r.engine), 1)
        let gyro = pe_active_gyro(r.engine)
        r.press("b", true, 1.2); r.press("b", false, 1.25); r.press("a", true, 1.3)
        XCTAssertEqual(r.take(), ["key 3 down", "key 2 down"])
        pe_release_outputs(r.engine, 2)                              // another window comes to the front
        XCTAssertEqual(Set(r.take()), Set(["key 3 up", "key 2 up"]), "nothing stays held in the old app")
        XCTAssertEqual(pe_active_layer(r.engine), 1, "the layer stays on")
        XCTAssertEqual(pe_active_gyro(r.engine), gyro, "and so does the gyro's switch")
        r.press("a", true, 2.1)
        XCTAssertEqual(r.take(), ["key 2 down"], "the layer's binding, in the new app")
        r.press("a", false, 2.2); _ = r.take()
        r.press("back", true, 3); r.press("back", false, 3.05)
        XCTAssertEqual(pe_active_layer(r.engine), 0, "and the toggle still turns it off")
        // Releasing everything (sleep, the controller gone) still resets it.
        r.press("back", true, 4); r.press("back", false, 4.05)
        pe_release_all(r.engine, 5)
        XCTAssertEqual(pe_active_layer(r.engine), 0)
    }
}
