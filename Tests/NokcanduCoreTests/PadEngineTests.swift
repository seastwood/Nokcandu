import XCTest
import NokcanduPadEngine

/// Records what the engine sends.
final class PadRecorder {
    var events: [String] = []
    var mouse = (x: 0, y: 0)
    var axes = [Int](repeating: 0, count: 6)
    var engine: OpaquePointer?

    init(_ profile: String) {
        var sink = pe_sink()
        sink.ctx = Unmanaged.passUnretained(self).toOpaque()
        sink.pad_button = { c, b, d in PadRecorder.of(c).events.append("pad \(String(cString: pe_input_name(b))) \(d ? "down" : "up")") }
        sink.pad_axis = { c, a, v in PadRecorder.of(c).axes[Int(a)] = Int(v) }
        sink.key = { c, k, d in PadRecorder.of(c).events.append("key \(k) \(d ? "down" : "up")") }
        sink.mouse_button = { c, b, d in PadRecorder.of(c).events.append("mouse \(b) \(d ? "down" : "up")") }
        sink.mouse_move = { c, x, y in let r = PadRecorder.of(c); r.mouse.x += Int(x); r.mouse.y += Int(y) }
        sink.wheel = { c, n in PadRecorder.of(c).events.append("wheel \(n)") }
        engine = pe_create("nokpad 1\n" + profile, sink)
    }
    deinit { pe_destroy(engine) }
    static func of(_ c: UnsafeMutableRawPointer?) -> PadRecorder { Unmanaged<PadRecorder>.fromOpaque(c!).takeUnretainedValue() }

    func press(_ name: String, _ down: Bool, _ t: Double) { pe_button(engine, pe_input_named(name), down, t) }
    func tick(_ t: Double) { pe_tick(engine, t) }
    func take() -> [String] { defer { events = [] }; return events }
}

final class PadEngineTests: XCTestCase {
    func testUnboundButtonsStayThemselvesAndBoundOnesRemap() {
        let r = PadRecorder("bind 0 a press=pad:b\nbind 0 x press=key:49")
        r.press("a", true, 1); r.press("a", false, 1.1)
        r.press("y", true, 1.2); r.press("y", false, 1.3)
        r.press("x", true, 1.4); r.press("x", false, 1.5)
        XCTAssertEqual(r.take(), ["pad b down", "pad b up", "pad y down", "pad y up", "key 49 down", "key 49 up"])
    }

    func testHoldLayerAndReleaseKeepsWhatWasPressed() {
        let r = PadRecorder("bind 0 lb press=layer:hold:1\nbind 1 a press=key:12\nbind 0 a press=key:13")
        r.press("a", true, 1); r.press("a", false, 1.1)
        r.press("lb", true, 2)
        r.press("a", true, 2.1)
        r.press("lb", false, 2.2)          // layer ends while a is still down
        r.press("a", false, 2.3)
        r.press("a", true, 3); r.press("a", false, 3.1)
        XCTAssertEqual(r.take(), ["key 13 down", "key 13 up", "key 12 down", "key 12 up", "key 13 down", "key 13 up"])
    }

    func testToggleLayer() {
        let r = PadRecorder("bind 0 back press=layer:toggle:2\nbind 2 a press=mouse:left")
        r.press("back", true, 1); r.press("back", false, 1.05)
        r.press("a", true, 1.2); r.press("a", false, 1.3)
        r.press("back", true, 2); r.press("back", false, 2.05)
        r.press("a", true, 2.2); r.press("a", false, 2.3)
        XCTAssertEqual(r.take(), ["mouse 0 down", "mouse 0 up", "pad a down", "pad a up"])
    }

    func testTapAndHold() {
        let r = PadRecorder("bind 0 b tap=key:8 hold=key:59 holdtime=0.2")
        r.press("b", true, 1); r.press("b", false, 1.1)        // tap
        r.tick(1.2)
        r.press("b", true, 2); r.tick(2.25)                     // hold
        r.press("b", false, 2.5)
        XCTAssertEqual(r.take(), ["key 8 down", "key 8 up", "key 59 down", "key 59 up"])
    }

    func testDoubleTap() {
        let r = PadRecorder("bind 0 y tap=key:1 double=key:2 doubletime=0.2")
        r.press("y", true, 1); r.press("y", false, 1.05)
        r.press("y", true, 1.15); r.press("y", false, 1.2)       // double
        r.press("y", true, 2); r.press("y", false, 2.05); r.tick(2.4)   // single
        r.tick(2.5)
        XCTAssertEqual(r.take(), ["key 2 down", "key 2 up", "key 1 down", "key 1 up"])
    }

    func testSimultaneousPress() {
        let r = PadRecorder("bind 0 lb sim=rb simout=key:48")
        r.press("lb", true, 1); r.press("rb", true, 1.02)
        r.press("lb", false, 1.2); r.press("rb", false, 1.25)
        r.press("lb", true, 2); r.tick(2.1); r.press("lb", false, 2.2)     // alone: itself, a little late
        XCTAssertEqual(r.take(), ["key 48 down", "key 48 up", "pad lb down", "pad lb up"])
    }

    func testChordOutput() {
        let r = PadRecorder("bind 0 start press=key:56,key:15")      // Shift+R
        r.press("start", true, 1); r.press("start", false, 1.1)
        XCTAssertEqual(r.take(), ["key 56 down", "key 15 down", "key 15 up", "key 56 up"])
    }

    func testTurbo() {
        let r = PadRecorder("bind 0 rb press=mouse:left turbo=100")
        r.press("rb", true, 1)
        for i in 1...10 { r.tick(1 + Double(i) * 0.025) }
        r.press("rb", false, 1.26)
        let ev = r.take()
        XCTAssertGreaterThanOrEqual(ev.filter { $0 == "mouse 0 down" }.count, 3)
        XCTAssertEqual(ev.last, "mouse 0 up")
    }

    func testTriggersPassThroughUnlessBound() {
        let r = PadRecorder("bind 0 rt press=mouse:left\nbind 0 rtfull press=mouse:right")
        pe_axis(r.engine, Int32(PE_AXIS_LT), 20000, 1)
        pe_axis(r.engine, Int32(PE_AXIS_RT), 20000, 1)
        XCTAssertEqual(r.axes[4], 20000)
        XCTAssertEqual(r.axes[5], 0)
        pe_axis(r.engine, Int32(PE_AXIS_RT), 32767, 1.1)
        pe_axis(r.engine, Int32(PE_AXIS_RT), 0, 1.2)
        XCTAssertEqual(r.take(), ["mouse 0 down", "mouse 1 down", "mouse 1 up", "mouse 0 up"])
    }

    func testStickSwapAndMouseStick() {
        let r = PadRecorder("stick 0 mode=pad to=1\nstick 1 mode=mouse sens=1000 power=1 dz=0 outer=1")
        pe_axis(r.engine, Int32(PE_AXIS_LX), 32767, 1)
        XCTAssertEqual(r.axes[2], 32767)        // left stick drives the right stick
        XCTAssertEqual(r.axes[0], 0)
        pe_axis(r.engine, Int32(PE_AXIS_RX), 32767, 1)
        for i in 1...25 { r.tick(1 + Double(i) * 0.004) }
        XCTAssertEqual(Double(r.mouse.x), 100, accuracy: 3)     // 1000/s for 0.1 s
        XCTAssertEqual(r.axes[2], 32767)
    }

    func testStickAsKeys() {
        let r = PadRecorder("stick 0 mode=keys keys=13,1,0,2")
        pe_axis(r.engine, Int32(PE_AXIS_LY), -32768, 1)      // up
        pe_axis(r.engine, Int32(PE_AXIS_LX), 32767, 1.1)     // up-right
        pe_axis(r.engine, Int32(PE_AXIS_LY), 0, 1.2)         // right
        pe_axis(r.engine, Int32(PE_AXIS_LX), 0, 1.3)
        XCTAssertEqual(r.take(), ["key 13 down", "key 2 down", "key 13 up", "key 2 up"])
    }

    func testFlickStick() {
        let r = PadRecorder("stick 1 mode=flick flick360=3600 flicktime=0.1")
        pe_axis(r.engine, Int32(PE_AXIS_RX), 32767, 1)        // right: a 90° flick
        for i in 1...40 { r.tick(1 + Double(i) * 0.004) }
        XCTAssertEqual(r.mouse.x, 900)
        pe_axis(r.engine, Int32(PE_AXIS_RY), 32767, 1.2)      // rotate to down-right: +45°
        XCTAssertEqual(Double(r.mouse.x), 1350, accuracy: 2)
    }

    func testGyroMouseAndOffButton() {
        let r = PadRecorder("gyro out=mouse min=10 cal=off\nbind 0 ls press=gyro:off")
        let yaw = Float(-30 * Double.pi / 180)            // turning right at 30°/s
        for i in 0...100 { pe_gyro(r.engine, 0, yaw, 0, 1 + Double(i) * 0.01) }
        XCTAssertEqual(Double(r.mouse.x), 300, accuracy: 4)   // 10 per degree for 1 s
        r.press("ls", true, 2.01)
        let before = r.mouse.x
        for i in 0...50 { pe_gyro(r.engine, 0, yaw, 0, 2.02 + Double(i) * 0.01) }
        XCTAssertEqual(r.mouse.x, before)
    }

    func testGyroToStick() {
        let r = PadRecorder("gyro out=rstick stickfull=100 stickmin=0 cal=off")
        pe_gyro(r.engine, 0, Float(-50 * Double.pi / 180), 0, 1)
        XCTAssertEqual(Double(r.axes[2]), 16384, accuracy: 100)
    }

    func testReleaseAllLetsGo() {
        let r = PadRecorder("bind 0 a press=key:13\nbind 0 b press=pad:x")
        r.press("a", true, 1); r.press("b", true, 1)
        _ = r.take()
        pe_release_all(r.engine, 2)
        XCTAssertEqual(Set(r.take()), ["key 13 up", "pad x up"])
    }

    func testRejectsNonProfiles() {
        XCTAssertNil(pe_create("hello", pe_sink()))
    }
}
