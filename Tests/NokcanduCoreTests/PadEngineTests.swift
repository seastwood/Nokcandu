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

@testable import NokcanduCore

final class PadProfilesTests: XCTestCase {
    typealias P = PadProfiles

    func testStackedProfilesAndLayersCompileAndRun() {
        var shooter = P.Profile(id: "s", name: "Shooter basics")
        shooter.base[.rt] = .as(.mouse(.left))
        shooter.base[.a] = .as(.key(49))
        shooter.layers.append(P.Layer(name: "Weapons", bindings: [:]))
        shooter.layers[1][.a] = .as(.key(18))
        shooter.base[.lb] = .as(.layerHold("Weapons"))
        var aim = P.Profile(id: "g", name: "Gyro aim", buildsOn: ["s"])
        aim.gyro = P.Gyro(output: .mouse)
        aim.base[.a] = .as(.key(36))                     // overrides Shooter basics' Space
        var weapons = P.Layer(name: "weapons")           // same layer, other case: merged
        weapons[.b] = .as(.key(19))
        aim.layers.append(weapons)
        let text = P.compile(aim, all: [shooter, aim])
        XCTAssertTrue(text.contains("gyro out=mouse"))
        XCTAssertTrue(text.contains("bind 0 a press=key:36"))
        XCTAssertTrue(text.contains("bind 0 rt press=mouse:left"))
        XCTAssertTrue(text.contains("bind 0 lb press=layer:hold:1"))
        XCTAssertTrue(text.contains("bind 1 a press=key:18"))
        XCTAssertTrue(text.contains("bind 1 b press=key:19"))
        let r = PadRecorder(String(text.dropFirst("nokpad 1\n".count)))
        XCTAssertNotNil(r.engine)
        r.press("lb", true, 1); r.press("a", true, 1.1); r.press("a", false, 1.2); r.press("lb", false, 1.3)
        r.press("a", true, 2); r.press("a", false, 2.1)
        XCTAssertEqual(r.take(), ["key 18 down", "key 18 up", "key 36 down", "key 36 up"])
    }

    func testBuildsOnLoopsAreCut() {
        let a = P.Profile(id: "a", name: "A", buildsOn: ["b"]), b = P.Profile(id: "b", name: "B", buildsOn: ["a"])
        XCTAssertEqual(P.stack(a, all: [a, b]).map(\.id), ["b", "a"])
    }

    func testOutputTokensRoundTrip() throws {
        let outs: [P.Output] = [.pad(.y), .trigger(right: true), .key(56), .mouse(.forward), .wheel(up: false), .gyroOn, .gyroOff,
                                .gyroToggle, .layerHold("Weapons"), .layerToggle("Map"), .nothing]
        for o in outs { XCTAssertEqual(P.Output(token: o.token), o) }
        let data = try JSONEncoder().encode(P.starters())
        XCTAssertEqual(try JSONDecoder().decode([P.Profile].self, from: data), P.starters())
    }

    func testChoicesDefaultAndOwn() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("padprof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let lf = base.appendingPathComponent("profiles.json"), df = base.appendingPathComponent("default")
        let env1 = base.appendingPathComponent("One.app/Contents"), env2 = base.appendingPathComponent("Two.app/Contents")
        var p = P.Profile(id: "p", name: "Mine"); p.base[.a] = .as(.key(49))
        try P.store(p, environments: [env1, env2], file: lf, defaultFile: df)
        XCTAssertFalse(P.inUse(contents: env1))                     // no default yet
        try P.setDefault(p, environments: [env1, env2], file: df, profilesFile: lf)
        XCTAssertTrue(P.inUse(contents: env1)); XCTAssertTrue(P.inUse(contents: env2))
        try P.set(.normal, contents: env2, file: lf, defaultFile: df)
        XCTAssertFalse(P.inUse(contents: env2))
        p.base[.a] = .as(.key(36))
        try P.store(p, environments: [env1, env2], file: lf, defaultFile: df)
        XCTAssertTrue(try String(contentsOf: P.mapFile(env1), encoding: .utf8).contains("key:36"))
        try P.delete(p, environments: [env1, env2], file: lf, defaultFile: df)
        XCTAssertEqual(P.choice(contents: env1), .followDefault)     // followed the default, which is gone
        XCTAssertFalse(P.inUse(contents: env1))
    }
}

final class MacGameKeysTests: XCTestCase {
    func testHidutilJSONMapsFnBothWaysAndReadsPreviousMapping() {
        let json = KeyRemap.hidutilJSON("0xff0100000003 0x7000000e0\n0x7000000e0 0xff0100000003\n")!
        XCTAssertTrue(json.contains("\"HIDKeyboardModifierMappingSrc\":1095216660483,\"HIDKeyboardModifierMappingDst\":30064771296"))
        XCTAssertTrue(json.contains("\"HIDKeyboardModifierMappingSrc\":280379760050179,\"HIDKeyboardModifierMappingDst\":30064771296"))
        XCTAssertTrue(json.contains("\"HIDKeyboardModifierMappingSrc\":30064771296,\"HIDKeyboardModifierMappingDst\":1095216660483"))
        XCTAssertNil(KeyRemap.hidutilJSON(""))
        let out = """
        RegistryID  Key                   Value
        100000a9c   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771296;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        100000f44   UserKeyMapping   (
        )
        """
        XCTAssertEqual(KeyRemap.previousMapping(out), "[{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771296}]")
        XCTAssertEqual(KeyRemap.previousMapping("RegistryID Key Value\n1 UserKeyMapping (\n)\n"), "[]")
    }
}

final class NetworkSteadyTests: XCTestCase {
    func testHelperScriptAndPlistAreValid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netsteady-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = dir.appendingPathComponent("s.sh"), p = dir.appendingPathComponent("p.plist")
        try Data(NetworkSteady.scriptText(flag: "/Users/x/Library/Application Support/Nokcandu/it's here").utf8).write(to: s)
        try Data(NetworkSteady.plistText().utf8).write(to: p)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", s.path]).ok)
        XCTAssertTrue(try Shell.run("/usr/bin/plutil", ["-lint", p.path]).ok)
    }
}

final class PadDriverHelperTests: XCTestCase {
    func testProfileEnvironmentsLoadTheHelperInWindowsBackgroundProcesses() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("padhelper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let c = base.appendingPathComponent("Game.app/Contents")
        let nok = c.appendingPathComponent("SharedSupport/nokcandu"), prefix = c.appendingPathComponent("SharedSupport/prefix")
        try FileManager.default.createDirectory(at: nok, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: nok.appendingPathComponent("nokcandu-rawmouse.dylib"))
        let user = prefix.appendingPathComponent("user.reg")
        try Data("WINE REGISTRY Version 2\n\n[Environment] 1792876383\n#time=1\n\"TEMP\"=\"C:\\\\temp\"\n".utf8).write(to: user)
        XCTAssertFalse(PadProfiles.ensureDriverHelper(contents: c))          // no profile: nothing
        try Data("nokpad 1\n".utf8).write(to: PadProfiles.mapFile(c))
        XCTAssertTrue(PadProfiles.ensureDriverHelper(contents: c))
        let text = try String(contentsOf: user, encoding: .utf8)
        XCTAssertTrue(text.contains("\"DYLD_INSERT_LIBRARIES\"=\""))
        XCTAssertTrue(text.contains("nokcandu-rawmouse.dylib\""))
        XCTAssertTrue(text.contains("\"TEMP\""))
        XCTAssertFalse(PadProfiles.ensureDriverHelper(contents: c))          // once
    }
}

final class PadAxisSpeedTests: XCTestCase {
    func testStickMouseSpeedsPerAxis() {
        let r = PadRecorder("stick 1 mode=mouse sens=1000 power=1 dz=0 outer=1 xs=2 ys=0.5")
        pe_axis(r.engine, Int32(PE_AXIS_RX), 23170, 1)
        pe_axis(r.engine, Int32(PE_AXIS_RY), -23170, 1)       // up-right
        for i in 1...25 { r.tick(1 + Double(i) * 0.004) }
        XCTAssertEqual(Double(r.mouse.x), 141, accuracy: 4)     // 0.707 × 1000 × 0.1 s × 2
        XCTAssertEqual(Double(r.mouse.y), -35, accuracy: 3)     // × 0.5, up
    }
}

final class PadGyroDirectionTests: XCTestCase {
    /// Turning right (−yaw) and tilting right (−roll) both move the mouse right, in every turn setting.
    func testTurningAndTiltingRightGoRight() {
        for (mode, x, z) in [("yaw", -0.5, 0.0), ("roll", 0.0, -0.5), ("both", -0.3, -0.3)] {
            let r = PadRecorder("gyro out=mouse min=10 cal=off yaw=\(mode)")
            for i in 0...50 { pe_gyro(r.engine, 0, Float(x), Float(z), 1 + Double(i) * 0.01) }
            XCTAssertGreaterThan(r.mouse.x, 50, mode)
        }
    }
}

final class PadEdgeBoostTests: XCTestCase {
    func testHoldingAtTheEdgeSpeedsUp() {
        let r = PadRecorder("stick 1 mode=mouse sens=1000 power=1 dz=0 outer=1 ramp=1 ramptime=0.2")
        pe_axis(r.engine, Int32(PE_AXIS_RX), 32767, 1)
        for i in 1...100 { r.tick(1 + Double(i) * 0.004) }         // 0.4 s: 0.2 s ramping, 0.2 s at 2×
        XCTAssertEqual(Double(r.mouse.x), 700, accuracy: 15)
    }
}

final class PadStateReportTests: XCTestCase {
    final class Box { var states: [String] = [] }
    func testLayerAndGyroChangesAreReported() {
        let box = Box()
        var sink = pe_sink()
        sink.ctx = Unmanaged.passUnretained(box).toOpaque()
        sink.state = { c, l, g in Unmanaged<Box>.fromOpaque(c!).takeUnretainedValue().states.append("\(l),\(g)") }
        let e = pe_create("nokpad 1\ngyro out=mouse\nbind 0 lb press=layer:hold:1\nbind 0 back press=gyro:toggle\nbind 1 a press=key:1", sink)
        pe_button(e, pe_input_named("lb"), true, 1); pe_button(e, pe_input_named("lb"), false, 1.1)
        pe_button(e, pe_input_named("back"), true, 2); pe_button(e, pe_input_named("back"), false, 2.1)
        pe_button(e, pe_input_named("a"), true, 3); pe_button(e, pe_input_named("a"), false, 3.1)    // not a state change
        XCTAssertEqual(box.states, ["1,1", "0,1", "0,0"])
        pe_destroy(e)
    }
}

final class PadDeviceTests: XCTestCase {
    func testDeviceButtonsHatAndAxes() {
        let r = PadRecorder("device 1 vendor=1103 product=46727 kind=joystick\naxis 1 2 mode=pad to=lt half=1 dz=0\naxis 1 0 mode=mouse to=x sens=1000 power=1 dz=0\nbind 0 d1b0 press=key:49\nbind 0 d1hu press=key:13\nbind 0 d1a1p press=key:1\nbind 0 d1b1 press=pad:a")
        pe_dev_button(r.engine, 1, 0, true, 1); pe_dev_button(r.engine, 1, 0, false, 1.1)
        pe_dev_button(r.engine, 1, 5, true, 1.2)                       // nothing set: nothing (the game reads the device itself)
        pe_dev_button(r.engine, 1, 1, true, 1.3); pe_dev_button(r.engine, 1, 1, false, 1.4)
        pe_dev_hat(r.engine, 1, Int32(PE_HAT_UP | PE_HAT_RIGHT), 1.5); pe_dev_hat(r.engine, 1, 0, 1.6)
        pe_dev_axis(r.engine, 1, 1, 30000, 1.7); pe_dev_axis(r.engine, 1, 1, 20000, 1.8); pe_dev_axis(r.engine, 1, 1, 0, 1.9)
        XCTAssertEqual(r.take(), ["key 49 down", "key 49 up", "pad a down", "pad a up", "key 13 down", "key 13 up", "key 1 down", "key 1 up"])
        pe_dev_axis(r.engine, 1, 2, -32768, 2); XCTAssertEqual(r.axes[4], 0)            // pedal at rest
        pe_dev_axis(r.engine, 1, 2, 32767, 2.1); XCTAssertEqual(r.axes[4], 32767)        // all the way
        pe_dev_axis(r.engine, 1, 0, 32767, 3)
        for i in 1...50 { r.tick(3 + Double(i) * 0.01) }
        XCTAssertEqual(Double(r.mouse.x), 500, accuracy: 30)
        XCTAssertTrue(pe_dev_uses(r.engine, 1, 0, 0)); XCTAssertFalse(pe_dev_uses(r.engine, 1, 0, 5))
        XCTAssertTrue(pe_dev_uses(r.engine, 1, 1, 0)); XCTAssertTrue(pe_dev_uses(r.engine, 1, 2, 2)); XCTAssertFalse(pe_dev_uses(r.engine, 1, 2, 3))
    }

    func testJoinedControllerActsAsTheMainOne() {
        let r = PadRecorder("device 1 vendor=1406 product=8201 kind=gamepad join=1\nbind 0 d1b1 press=key:12")
        pe_dev_button(r.engine, 1, 0, true, 1); pe_dev_button(r.engine, 1, 0, false, 1.1)
        pe_dev_button(r.engine, 1, 1, true, 1.2)
        XCTAssertEqual(r.take(), ["pad a down", "pad a up", "key 12 down"])
        pe_dev_axis(r.engine, 1, 3, 20000, 2); XCTAssertEqual(r.axes[3], 20000)
        pe_dev_axis(r.engine, 1, 5, 32767, 2.1); XCTAssertEqual(r.axes[5], 32767)
        XCTAssertTrue(pe_dev_uses(r.engine, 1, 0, 9))
    }

    func testInputNames() {
        for n in ["d1b0", "d1b31", "d2hu", "d4hl", "d3a7p", "d1a0n"] { XCTAssertEqual(String(cString: pe_input_name(pe_input_named(n))), n) }
        for n in ["d0b1", "d5b1", "d1b32", "d1a8p", "d1a1", "d1hx"] { XCTAssertEqual(pe_input_named(n), -1, n) }
    }

    func testProfileCompilesDevicesAndTheirBindings() {
        var p = PadProfiles.Profile(name: "Flight")
        var stick = PadProfiles.Device(name: "Stick", productName: "T.16000M", vendorID: 1103, productID: 46727, buttonCount: 16, axisNames: ["X", "Y", "Twist", "Slider"], hasHat: true)
        stick.setAxis(2, { var a = PadProfiles.DeviceAxis(mode: .stick); a.target = .rx; return a }())
        var pedals = PadProfiles.Device(name: "Pedals", productName: "TFRP", vendorID: 1103, productID: 46721, nth: 1)
        pedals.setAxis(0, { var a = PadProfiles.DeviceAxis(); a.restsAtEnd = true; return a }())
        p.devices = [stick, pedals]
        p.base[key: stick.key("b0")] = .as(.key(49))
        p.base[key: pedals.key("a0p")] = .as(.key(1))
        p.base[key: "dev.gone.b0"] = .as(.key(2))                  // a removed device's leftover: skipped
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.contains("device 1 vendor=1103 product=46727 nth=0 kind=joystick join=0"))
        XCTAssertTrue(text.contains("device 2 vendor=1103 product=46721 nth=1 kind=joystick join=0"))
        XCTAssertTrue(text.contains("axis 1 2 mode=pad to=rx"))
        XCTAssertTrue(text.contains("axis 2 0 mode=off to=lx inv=0 half=1"))
        XCTAssertTrue(text.contains("bind 0 d1b0 press=key:49"))
        XCTAssertTrue(text.contains("bind 0 d2a0p press=key:1"))
        XCTAssertFalse(text.contains("key:2"))
        // A profile built on this one gets its devices and can add to their bindings in a layer of the same name.
        var top = PadProfiles.Profile(name: "Top", buildsOn: [p.id])
        top.base[key: stick.key("b1")] = .as(.key(3))
        let t2 = PadProfiles.compile(top, all: [p, top])
        XCTAssertTrue(t2.contains("bind 0 d1b0 press=key:49") && t2.contains("bind 0 d1b1 press=key:3"))
        // It runs: the engine reads all of it.
        let r = PadRecorder(String(text.dropFirst("nokpad 1\n".count)))
        XCTAssertEqual(pe_device_count(r.engine), 2)
        pe_dev_axis(r.engine, 2, 0, 32767, 1)
        XCTAssertEqual(r.take(), ["key 1 down"])
        // Saved and read back (older profiles without devices still read).
        let back = try? JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertNil(try JSONDecoder().decode(PadProfiles.Profile.self, from: Data(#"{"id":"x","name":"Old","buildsOn":[],"layers":[{"id":"base","name":"Base","bindings":{}}]}"#.utf8)).devices)
    }

    func testDeviceInputTitles() {
        let d = PadProfiles.Device(name: "Stick", productName: "Stick", vendorID: 1, productID: 2, axisNames: ["X", "Y", "Throttle"])
        XCTAssertEqual(d.inputTitle("b0"), "Button 1"); XCTAssertEqual(d.inputTitle("hl"), "Hat left")
        XCTAssertEqual(d.inputTitle("a1n"), "Pushed forward (Y)"); XCTAssertEqual(d.inputTitle("a2p"), "Throttle +")
        let g = PadProfiles.Device(name: "Pad", productName: "Pad", vendorID: 1, productID: 2, gamepad: true)
        XCTAssertEqual(g.inputTitle("b0"), "A"); XCTAssertEqual(g.inputTitle("b0", family: .playstation), "Cross"); XCTAssertEqual(g.buttons, 21)
    }

    /// SDL's order: by usage across pages, the device's order for equal usages, duplicates skipped.
    func testHIDLayoutMatchesSDL() {
        typealias E = HIDLayout.Element
        let list = [
            E(type: 2, page: 9, usage: 2, cookie: 10, min: 0, max: 1),       // button 2
            E(type: 2, page: 9, usage: 1, cookie: 11, min: 0, max: 1),       // button 1
            E(type: 1, page: 2, usage: 0xBB, cookie: 20, min: 0, max: 255),  // throttle
            E(type: 1, page: 1, usage: 0x31, cookie: 21, min: 0, max: 1023), // Y
            E(type: 1, page: 1, usage: 0x30, cookie: 22, min: 0, max: 1023), // X
            E(type: 1, page: 1, usage: 0x36, cookie: 23, min: 0, max: 255),  // slider
            E(type: 1, page: 1, usage: 0x36, cookie: 24, min: 0, max: 255),  // slider 2
            E(type: 1, page: 1, usage: 0x39, cookie: 30, min: 0, max: 7),    // hat
            E(type: 1, page: 1, usage: 0x30, cookie: 22, min: 0, max: 1023), // X again: skipped
            E(type: 513, page: 9, usage: 3, cookie: 40, min: 0, max: 1),     // an output, not an input: skipped
        ]
        let l = HIDLayout.layout(list)
        XCTAssertEqual(l.buttons.map(\.cookie), [11, 10])
        XCTAssertEqual(l.axes.map(\.name), ["X", "Y", "Slider", "Slider 2", "Throttle"])
        XCTAssertEqual(l.hat?.cookie, 30)
        XCTAssertEqual(HIDLayout.axisValue(0, min: 0, max: 1023), -32768)
        XCTAssertEqual(HIDLayout.axisValue(1023, min: 0, max: 1023), 32767)
        XCTAssertEqual(HIDLayout.hatBits(1, min: 0, max: 7), 3)          // up-right
        XCTAssertEqual(HIDLayout.hatBits(8, min: 0, max: 7), 0)          // centred
        XCTAssertEqual(HIDLayout.hatBits(1, min: 0, max: 3), 2)          // 4-position hat: right
    }
}

final class PadStickDirectionTests: XCTestCase {
    func testEachDirectionIsItsOwnButton() {
        var p = PadProfiles.Profile(name: "Dirs")
        p.leftStick = PadProfiles.Stick(mode: .directions)
        p.base[.lsup] = .as(.key(13))
        p.base[.lsright] = PadProfiles.Binding(tap: [.key(2)], hold: [.key(3)])
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.contains("stick 0 mode=dirs"))
        let r = PadRecorder(String(text.dropFirst("nokpad 1\n".count)))
        pe_axis(r.engine, Int32(PE_AXIS_LY), -30000, 1)          // up
        pe_axis(r.engine, Int32(PE_AXIS_LX), 30000, 1.01)        // up and right
        pe_axis(r.engine, Int32(PE_AXIS_LY), 0, 1.02)            // right
        r.tick(1.5)                                              // held: the hold
        pe_axis(r.engine, Int32(PE_AXIS_LX), 0, 1.6)
        XCTAssertEqual(r.take(), ["key 13 down", "key 13 up", "key 3 down", "key 3 up"])
        XCTAssertEqual(r.axes[0], 0)                             // the game doesn't see the stick move
        XCTAssertNil(PadProfiles.Output(token: "pad:lsup"))      // not a controller button to send
        XCTAssertFalse(PadProfiles.Input.padButtons.contains(.rsleft))
    }
}

final class PadExtrasTests: XCTestCase {
    func testLayersMacrosSequencesMenusTouchTiltCompileAndRun() {
        var p = PadProfiles.Profile(name: "All")
        p.rightStick = { var s = PadProfiles.Stick(mode: .mouse); s.speed = 1000; s.curve = 1; s.deadzone = 0; return s }()
        var aim = PadProfiles.Layer(name: "Aim")
        aim.rightStick = { var s = PadProfiles.Stick(mode: .mouse); s.speed = 100; s.curve = 1; s.deadzone = 0; return s }()
        p.layers.append(aim)
        p.base[.lb] = .as(.layerHold("Aim"))
        let mac = PadProfiles.Macro(name: "Hi", steps: [.init(.press, output: .key(4)), .init(.wait, ms: 50), .init(.text, text: "gg")])
        p.macros = [mac]
        p.base[.a] = .as(.macro(mac.id))
        p.sequences = [PadProfiles.Sequence(name: "Konami", inputs: [.up, .up, .down], outputs: [.key(5)])]
        let menu = PadProfiles.RadialMenu(name: "Buy", stick: 1, slices: [.init(title: "One", outputs: [.key(18)]), .init(title: "Two", outputs: [.key(19)])])
        p.menus = [menu]
        p.base[.rb] = .as(.menu(menu.id))
        p.base[.back] = .as(.calibrate)
        p.touchpad = PadProfiles.Touchpad(mode: .zones)
        p.base[.tz1] = .as(.key(6))
        p.tilt = PadProfiles.Tilt()
        p.base[.tiltright] = .as(.key(7))
        let text = PadProfiles.compile(p, all: [p])
        for want in ["stick 1 mode=mouse", "layer=1", "macro 0 down:key:4 wait:30 up:key:4 wait:50 text:6767", "seq 0 in=up,up,down", "menu 0 stick=1 s0=key:18 s1=key:19",
                     "bind 0 a press=macro:0", "bind 0 rb press=menu:0", "bind 0 back press=calibrate", "touch mode=zones", "tilt angle=30", "bind 0 tz1 press=key:6", "bind 0 tiltright press=key:7"] {
            XCTAssertTrue(text.contains(want), want + "\n" + text)
        }
        let r = PadRecorder(String(text.dropFirst("nokpad 1\n".count)))
        r.press("a", true, 1); r.press("a", false, 1.01)
        r.tick(1.2)
        XCTAssertEqual(Array(r.take().prefix(2)), ["key 4 down", "key 4 up"])
        r.press("up", true, 2); r.press("up", false, 2.05); r.press("up", true, 2.2); r.press("up", false, 2.25); r.press("down", true, 2.4)
        XCTAssertTrue(r.take().contains("key 5 down"))
        // Tokens survive saving.
        for o: PadProfiles.Output in [.macro("x"), .menu("y"), .keyboard, .calibrate, .rumble] { XCTAssertEqual(PadProfiles.Output(token: o.token), o) }
        XCTAssertFalse(PadProfiles.Input.padButtons.contains(.tz1)); XCTAssertFalse(PadProfiles.Input.padButtons.contains(.tiltleft))
    }

    func testShareAndImport() throws {
        let base = PadProfiles.Profile(name: "Base")
        var top = PadProfiles.Profile(name: "CS2", buildsOn: [base.id])
        top.base[.a] = .as(.key(49))
        let text = PadProfiles.exportText(top, all: [base, top])
        let imported = try PadProfiles.importText("Here you go:\n```json\n" + text + "\n```", existing: [base])
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported.last?.name, "CS2"); XCTAssertEqual(imported.first?.name, "Base (2)")
        XCTAssertNotEqual(imported.last?.id, top.id)
        XCTAssertEqual(imported.last?.buildsOn, [imported.first!.id])
        XCTAssertEqual(imported.last?.base[.a], .as(.key(49)))
        XCTAssertThrowsError(try PadProfiles.importText("hello", existing: []))
    }
}

final class PadToggleTests: XCTestCase {
    func testPersistentToggleIsIndependentOfLayerAndPhysicalRelease() {
        let r = PadRecorder("bind 0 a press=keytoggle:12\nbind 0 b press=layer:toggle:1\nbind 1 x press=mousetoggle:left")
        r.press("a", true, 1); r.press("a", false, 1.1)
        XCTAssertEqual(r.take(), ["key 12 down"])
        r.press("b", true, 2); r.press("b", false, 2.1)
        r.press("x", true, 3); r.press("x", false, 3.1)
        XCTAssertEqual(r.take(), ["mouse 0 down"])
        pe_release_all(r.engine, 4)
        XCTAssertEqual(Set(r.take()), Set(["key 12 up", "mouse 0 up"]))
        r.press("a", true, 5); r.press("a", false, 5.1)
        XCTAssertEqual(r.take(), ["key 12 down"])
    }
    func testToggleDoesNotReleaseAnotherButtonsHold() {
        let r = PadRecorder("bind 0 a press=keytoggle:12\nbind 0 b press=key:12")
        r.press("a", true, 1); r.press("a", false, 1.1)
        r.press("b", true, 2)
        r.press("a", true, 3); r.press("a", false, 3.1)
        XCTAssertEqual(r.take(), ["key 12 down"])
        r.press("b", false, 4)
        XCTAssertEqual(r.take(), ["key 12 up"])
    }
}

final class PadLiveBindingTests: XCTestCase {
    func testEditingHeldBindingReleasesOnlyThatBinding() {
        let r = PadRecorder("bind 0 a press=key:12\nbind 0 b press=key:13")
        r.press("a", true, 1); r.press("b", true, 1.1); _ = r.take()
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\nbind 0 a press=key:14\nbind 0 b press=key:13"))
        XCTAssertEqual(r.take(), ["key 12 up"])
        r.press("a", false, 2); r.press("b", false, 2.1)
        XCTAssertEqual(r.take(), ["key 13 up"])
        r.press("a", true, 3); r.press("a", false, 3.1)
        XCTAssertEqual(r.take(), ["key 14 down", "key 14 up"])
    }
    func testUnsupportedUpdateIsNonMutating() {
        let r = PadRecorder("bind 0 a press=key:12")
        r.press("a", true, 1); _ = r.take()
        XCTAssertFalse(pe_update_bindings(r.engine, "nokpad 1\nstick 0 mode=mouse\nbind 0 a press=key:14"))
        XCTAssertTrue(r.take().isEmpty)
        r.press("a", false, 2); XCTAssertEqual(r.take(), ["key 12 up"])
    }
}

final class PadButtonRouteTests: XCTestCase {
    func testNativeBothDisabledAndMappedAreDistinct() {
        let r = PadRecorder("bind 0 a press=key:12\nbind 0 b press=key:13\nbind 0 x press=key:14\nbind 0 y press=key:15\nroute a native\nroute b both\nroute x disabled\nroute y mapped")
        for name in ["a", "b", "x", "y"] { r.press(name, true, 1); r.press(name, false, 1.1) }
        XCTAssertEqual(r.take(), ["pad a down", "pad a up", "pad b down", "key 13 down", "pad b up", "key 13 up", "key 15 down", "key 15 up"])
    }
    func testBothRouteDisconnectReleasesBothOutputsAndAllowsReconnect() {
        let r = PadRecorder("bind 0 a press=key:12\nroute a both")
        r.press("a", true, 1); r.press("a", true, 1.1)
        XCTAssertEqual(r.take(), ["pad a down", "key 12 down"])
        pe_release_all(r.engine, 2)
        XCTAssertEqual(Set(r.take()), Set(["pad a up", "key 12 up"]))
        r.press("a", true, 3)
        XCTAssertEqual(r.take(), ["pad a down", "key 12 down"])
    }
}

final class PadCalibrationKindTests: XCTestCase {
    func testFocusReleaseRetainsBiasAndReleasesOldApplicationOutputs() {
        let r = PadRecorder("gyro out=mouse min=10 max=10 smooth=0 tight=0 cal=off\nbind 0 a press=key:12\nbind 0 b press=keytoggle:13")
        let drift = Float(2 * Double.pi / 180)
        pe_calibrate(r.engine, 1)
        for n in 0...220 { pe_gyro(r.engine, 0, drift, 0, 1 + Double(n) * 0.01) }
        r.press("a", true, 3.3); r.press("b", true, 3.4); r.press("b", false, 3.5)
        _ = r.take()
        pe_release_all(r.engine, 4) // Same compiled profile, new foreground PID.
        XCTAssertEqual(Set(r.take()), Set(["key 12 up", "key 13 up"]))
        r.mouse = (0, 0)
        for n in 0...50 { pe_gyro(r.engine, 0, drift, 0, 5 + Double(n) * 0.01) }
        XCTAssertEqual(r.mouse.x, 0, "Window changes must not discard measured sensor bias")
        XCTAssertEqual(r.mouse.y, 0)
        r.press("a", true, 5.6)
        XCTAssertEqual(r.take(), ["key 12 down"], "Fresh physical state must work after releasing the old application")
        for n in 0...20 { pe_gyro(r.engine, 0, drift + 1, 0, 6 + Double(n) * 0.01) }
        XCTAssertNotEqual(r.mouse.x, 0, "Retained calibration must not disable intentional motion")
    }

    func testManualCalibrationKindSurvivesCompletionThenAutoResetsIt() {
        let r = PadRecorder("gyro out=mouse min=8 max=8 cal=auto")
        pe_calibrate(r.engine, 1)
        XCTAssertTrue(pe_calibration_is_manual(r.engine))
        for n in 0...220 { pe_gyro(r.engine, 0, 0, 0, 1 + Double(n) * 0.01) }
        XCTAssertTrue(pe_calibration_is_manual(r.engine))
        pe_gyro(r.engine, 10, 10, 10, 4)
        for n in 0...100 { pe_gyro(r.engine, 0, 0, 0, 5 + Double(n) * 0.01) }
        XCTAssertFalse(pe_calibration_is_manual(r.engine))
    }
}

final class PadUnboundRouteTests: XCTestCase {
    func testMappedOnlyNeverFallsBackToNativeWhenUnbound() {
        let r = PadRecorder("route a mapped\nroute b both\nroute x native\nroute y disabled")
        for name in ["a", "b", "x", "y"] { r.press(name, true, 1); r.press(name, false, 1.1) }
        XCTAssertEqual(r.take(), ["pad b down", "pad b up", "pad x down", "pad x up"])
    }
}

final class PadMacroCleanupTests: XCTestCase {
    func testSequenceTracksMoreThanSixHeldOutputsThroughCompletionAndCancellation() {
        let downs = (10...17).map { "down:key:\($0)" }.joined(separator: " ")
        for cancel in [false, true] {
            let r = PadRecorder("macro 0 \(downs) wait:100\nbind 0 a press=macro:0")
            r.press("a", true, 1)
            XCTAssertEqual(r.take().count, 8)
            if cancel { pe_release_all(r.engine, 1.05) } else { r.tick(1.2) }
            XCTAssertEqual(r.take(), (10...17).reversed().map { "key \($0) up" })
            r.tick(5); XCTAssertTrue(r.take().isEmpty)
        }
    }
}

final class PadLiveTimerTests: XCTestCase {
    func testUnrelatedHoldDeadlineSurvivesBindingEdit() {
        let r = PadRecorder("bind 0 a tap=key:12 hold=key:13 holdtime=0.2\nbind 0 b press=key:14")
        r.press("a", true, 1)
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\nbind 0 a tap=key:12 hold=key:13 holdtime=0.2\nbind 0 b press=key:15"))
        r.tick(1.25); XCTAssertEqual(r.take(), ["key 13 down"])
        r.press("a", false, 1.3); XCTAssertEqual(r.take(), ["key 13 up"])
    }
    func testChangedPendingHoldIsCancelledWithoutOldTapOrDelayedPress() {
        let r = PadRecorder("bind 0 a tap=key:12 hold=key:13 holdtime=0.2")
        r.press("a", true, 1)
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\nbind 0 a press=key:14"))
        r.tick(2); r.press("a", false, 2.1); XCTAssertTrue(r.take().isEmpty)
        r.press("a", true, 3); r.press("a", false, 3.1)
        XCTAssertEqual(r.take(), ["key 14 down", "key 14 up"])
    }
    func testUnrelatedTurboKeepsItsCadence() {
        let r = PadRecorder("bind 0 a press=key:12 turbo=100\nbind 0 b press=key:13")
        r.press("a", true, 1); _ = r.take()
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\nbind 0 a press=key:12 turbo=100\nbind 0 b press=key:14"))
        XCTAssertTrue(r.take().isEmpty)
        r.tick(1.11); XCTAssertEqual(r.take(), ["key 12 up"])
        r.tick(1.16); XCTAssertEqual(r.take(), ["key 12 down"])
        r.press("a", false, 1.17); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testEditingActiveTurboReleasesOldOutputAndCancelsItsTimer() {
        let r = PadRecorder("bind 0 a press=key:12 turbo=100")
        r.press("a", true, 1); _ = r.take()
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\nbind 0 a press=key:14"))
        XCTAssertEqual(r.take(), ["key 12 up"])
        r.tick(2); r.press("a", false, 2.01); XCTAssertTrue(r.take().isEmpty)
    }
}

final class PadTurboOwnershipTests: XCTestCase {
    func testReleasingOffPhaseTurboDoesNotReleaseAnotherHold() {
        let r = PadRecorder("bind 0 a press=key:12 turbo=100\nbind 0 b press=key:12")
        r.press("a", true, 1); r.press("b", true, 1.01); _ = r.take()
        r.tick(1.11); XCTAssertTrue(r.take().isEmpty)
        r.press("a", false, 1.12); XCTAssertTrue(r.take().isEmpty)
        r.press("b", false, 1.13); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testEditingOffPhaseTurboPreservesOtherHoldAndCancelsRepeats() {
        let r = PadRecorder("bind 0 a press=key:12 turbo=100\nbind 0 b press=key:12")
        r.press("a", true, 1); r.press("b", true, 1.01); _ = r.take()
        r.tick(1.11)
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\nbind 0 a press=key:14\nbind 0 b press=key:12"))
        r.tick(2); r.press("a", false, 2.01); XCTAssertTrue(r.take().isEmpty)
        r.press("b", false, 2.02); XCTAssertEqual(r.take(), ["key 12 up"])
    }
}

final class PadEquivalentUpdateTests: XCTestCase {
    func testEquivalentSavePreservesLatchedKey() {
        let profile = "bind 0 a press=keytoggle:12"
        let r = PadRecorder(profile)
        r.press("a", true, 1); r.press("a", false, 1.1); _ = r.take()
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\n" + profile))
        XCTAssertTrue(r.take().isEmpty)
        r.press("a", true, 2); r.press("a", false, 2.1)
        XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testEquivalentSavePreservesPendingSequence() {
        let profile = "macro 0 down:key:12 wait:100 up:key:12\nbind 0 a press=macro:0"
        let r = PadRecorder(profile)
        r.press("a", true, 1); _ = r.take()
        XCTAssertTrue(pe_update_bindings(r.engine, "nokpad 1\n" + profile))
        XCTAssertTrue(r.take().isEmpty)
        r.tick(1.2); XCTAssertEqual(r.take(), ["key 12 up"])
    }
}

final class PadLiveTuningTests: XCTestCase {
    func testMouseSpeedEditKeepsStickPositionAndHeldKey() {
        let r = PadRecorder("stick 1 mode=mouse sens=100 power=1 dz=0 outer=1\nbind 0 a press=key:12")
        r.press("a", true, 1)
        pe_axis(r.engine, Int32(PE_AXIS_RX), 32767, 1.01)
        _ = r.take(); r.mouse = (0, 0)
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\nstick 1 mode=mouse sens=200 power=1 dz=0 outer=1\nbind 0 a press=key:12"))
        XCTAssertTrue(r.take().isEmpty)
        r.tick(1.11); XCTAssertEqual(r.mouse.x, 20)
        r.press("a", false, 1.12); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testTuningDuringSequenceAndToggleDoesNotResetEither() {
        let profile = "gyro out=mouse min=8 max=8\nmacro 0 down:key:13 wait:100 up:key:13\nbind 0 a press=keytoggle:12\nbind 0 b press=macro:0"
        let r = PadRecorder(profile)
        r.press("a", true, 1); r.press("a", false, 1.01); r.press("b", true, 1.02); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + profile.replacingOccurrences(of: "min=8 max=8", with: "min=16 max=16")))
        XCTAssertTrue(r.take().isEmpty)
        r.tick(1.2); XCTAssertEqual(r.take(), ["key 13 up"])
        r.press("a", true, 2); r.press("a", false, 2.01); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testFlickOutputChangeRejectsWithoutReleasingHeldKey() {
        let r = PadRecorder("stick 1 mode=mouse sens=100\nbind 0 a press=key:12")
        r.press("a", true, 1); _ = r.take()
        XCTAssertFalse(pe_update_profile(r.engine, "nokpad 1\nstick 1 mode=flick sens=100\nbind 0 a press=key:12"))
        XCTAssertTrue(r.take().isEmpty)
        r.press("a", false, 2); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testLayerTuningKeepsActiveLayer() {
        let profile = "stick 1 mode=mouse sens=100\nstick 1 layer=1 mode=mouse sens=200\nbind 0 lb press=layer:toggle:1"
        let r = PadRecorder(profile)
        r.press("lb", true, 1); r.press("lb", false, 1.01)
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + profile.replacingOccurrences(of: "sens=200", with: "sens=400")))
        XCTAssertEqual(pe_active_layer(r.engine), 1)
    }
}

final class PadLiveTuningContinuityTests: XCTestCase {
    func testGyroSensitivityTakesEffectAtNextSensorSample() {
        let r = PadRecorder("gyro out=mouse min=10 max=10 smooth=0 tight=0 cal=off")
        pe_gyro(r.engine, 0, -1, 0, 1)
        pe_gyro(r.engine, 0, -1, 0, 1.05)
        let before = r.mouse.x; r.mouse = (0, 0)
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\ngyro out=mouse min=20 max=20 smooth=0 tight=0 cal=off"))
        pe_gyro(r.engine, 0, -1, 0, 1.10)
        XCTAssertGreaterThan(before, 0)
        XCTAssertEqual(r.mouse.x, before * 2, accuracy: 2)
    }
    func testUnrelatedGyroTuningDoesNotRestartStickAcceleration() {
        let profile = "stick 1 mode=mouse sens=100 power=1 dz=0 outer=1 ramp=2 ramptime=1 edge=0.9\ngyro out=mouse min=8 max=8"
        let r = PadRecorder(profile)
        pe_axis(r.engine, Int32(PE_AXIS_RX), 32767, 1)
        for i in 1...5 { r.tick(1 + Double(i) * 0.1) }
        r.mouse = (0, 0)
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + profile.replacingOccurrences(of: "min=8 max=8", with: "min=16 max=16")))
        r.tick(1.6)
        XCTAssertEqual(r.mouse.x, 22, accuracy: 1)
    }
}

final class PadControlRouteTests: XCTestCase {
    func testNativeStickBypassesMouseMappingAndBothProducesBothWithoutDoublingAxes() {
        for route in ["native", "both", "mapped", "disabled"] {
            let r = PadRecorder("stick 1 mode=mouse sens=100 power=1 dz=0 outer=1\nroute rstick \(route)")
            pe_axis(r.engine, Int32(PE_AXIS_RX), 20000, 1)
            r.tick(1.1)
            XCTAssertEqual(r.axes[2], ["native", "both"].contains(route) ? 20000 : 0)
            XCTAssertEqual(r.mouse.x > 0, ["both", "mapped"].contains(route))
        }
        let r = PadRecorder("stick 0 mode=pad dz=0 outer=1\nroute lstick both")
        pe_axis(r.engine, Int32(PE_AXIS_LX), 12000, 1)
        XCTAssertEqual(r.axes[0], 12000)
    }
    func testTriggerNativeMappedBothDisabledAndCleanup() {
        for route in ["native", "both", "mapped", "disabled"] {
            let r = PadRecorder("bind 0 rt press=mouse:left\nroute rt \(route)")
            pe_axis(r.engine, Int32(PE_AXIS_RT), 24000, 1)
            XCTAssertEqual(r.axes[5], ["native", "both"].contains(route) ? 24000 : 0)
            XCTAssertEqual(r.take(), ["both", "mapped"].contains(route) ? ["mouse 0 down"] : [])
            pe_release_all(r.engine, 2)
            XCTAssertEqual(r.axes[5], 0)
            XCTAssertEqual(r.take(), ["both", "mapped"].contains(route) ? ["mouse 0 up"] : [])
        }
    }
    func testGyroRoutesOnlyControlMappedEmission() {
        for route in ["native", "both", "mapped", "disabled"] {
            let r = PadRecorder("gyro out=mouse min=10 max=10 smooth=0 tight=0 cal=off\nroute gyro \(route)")
            pe_gyro(r.engine, 0, -1, 0, 1); pe_gyro(r.engine, 0, -1, 0, 1.05)
            XCTAssertEqual(r.mouse.x > 0, ["both", "mapped"].contains(route))
        }
    }
}

final class PadToggleEditOwnershipTests: XCTestCase {
    func testUnrelatedBindingEditPreservesLatchedKeyAndMouse() {
        let text = "bind 0 a press=keytoggle:12\nbind 0 b press=mousetoggle:left\nbind 0 x press=key:13"
        let r = PadRecorder(text)
        for n in ["a", "b"] { r.press(n, true, 1); r.press(n, false, 1.01) }; _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=key:13", with: "press=key:14")))
        XCTAssertTrue(r.take().isEmpty)
        for n in ["a", "b"] { r.press(n, true, 2); r.press(n, false, 2.01) }
        XCTAssertEqual(r.take(), ["key 12 up", "mouse 0 up"])
    }
    func testRemovingToggleOwnerReleasesItsOutputButNotAnotherHold() {
        let r = PadRecorder("bind 0 a press=keytoggle:12\nbind 0 b press=key:12")
        r.press("a", true, 1); r.press("a", false, 1.01); r.press("b", true, 1.02); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\nbind 0 a press=key:14\nbind 0 b press=key:12"))
        XCTAssertTrue(r.take().isEmpty)
        r.press("b", false, 2); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testChangedOwnerReleasesLatchEvenAfterPhysicalRelease() {
        let r = PadRecorder("bind 0 a press=mousetoggle:right")
        r.press("a", true, 1); r.press("a", false, 1.01); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\nbind 0 a press=key:14"))
        XCTAssertEqual(r.take(), ["mouse 1 up"])
    }
    func testTimedHoldToggleCarriesPhysicalOrigin() {
        let r = PadRecorder("bind 0 a hold=keytoggle:12 holdtime=0.2\nbind 0 b press=key:13")
        r.press("a", true, 1); r.tick(1.3); r.press("a", false, 1.31); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\nbind 0 a press=none\nbind 0 b press=key:13"))
        XCTAssertEqual(r.take(), ["key 12 up"])
    }
}

final class PadDeviceReleaseTests: XCTestCase {
    func testDisconnectReleasesSlotLatchAndMacroButPreservesMainHold() {
        let r = PadRecorder("device 1 vendor=1 product=2 kind=joystick\nmacro 0 down:key:14 wait:1000 up:key:14\nbind 0 d1b0 press=keytoggle:12\nbind 0 d1b1 press=macro:0\nbind 0 a press=key:13")
        r.press("a", true, 1)
        pe_dev_button(r.engine, 1, 0, true, 1.01); pe_dev_button(r.engine, 1, 0, false, 1.02)
        pe_dev_button(r.engine, 1, 1, true, 1.03); _ = r.take()
        pe_release_device(r.engine, 1, 1.04)
        XCTAssertEqual(Set(r.take()), Set(["key 12 up", "key 14 up"]))
        r.tick(5); XCTAssertTrue(r.take().isEmpty)
        r.press("a", false, 5.1); XCTAssertEqual(r.take(), ["key 13 up"])
        pe_dev_button(r.engine, 1, 0, true, 6); XCTAssertEqual(r.take(), ["key 12 down"])
    }
    func testDisconnectNeutralizesOnlyItsAxisContribution() {
        let r = PadRecorder("device 1 vendor=1 product=2 kind=joystick\naxis 1 0 mode=pad to=lx dz=0")
        pe_axis(r.engine, Int32(PE_AXIS_RX), 16000, 1)
        pe_dev_axis(r.engine, 1, 0, 22000, 1.01)
        XCTAssertGreaterThan(r.axes[0], 0); let right = r.axes[2]
        pe_release_device(r.engine, 1, 2)
        XCTAssertEqual(r.axes[0], 0); XCTAssertEqual(r.axes[2], right)
    }
    func testPendingTapOnDisconnectedDeviceDoesNotFire() {
        let r = PadRecorder("device 1 vendor=1 product=2 kind=joystick\nbind 0 d1b0 tap=key:12 hold=key:13 holdtime=0.2")
        pe_dev_button(r.engine, 1, 0, true, 1)
        pe_release_device(r.engine, 1, 1.1)
        r.tick(2); XCTAssertTrue(r.take().isEmpty)
    }
}

final class PadMainReleaseTests: XCTestCase {
    func testPrimaryDisconnectReleasesOwnLatchButPreservesDeviceSlot() {
        let r = PadRecorder("device 1 vendor=1 product=2 kind=joystick\nbind 0 a press=keytoggle:12\nbind 0 d1b0 press=key:13")
        r.press("a", true, 1); r.press("a", false, 1.01)
        pe_dev_button(r.engine, 1, 0, true, 1.02); _ = r.take()
        pe_release_main(r.engine, 2); XCTAssertEqual(r.take(), ["key 12 up"])
        pe_dev_button(r.engine, 1, 0, false, 2.01); XCTAssertEqual(r.take(), ["key 13 up"])
    }
    func testPrimaryDisconnectRetainsAdditionalAxisAndClearsNativeBothReference() {
        let r = PadRecorder("device 1 vendor=1 product=2 kind=joystick\naxis 1 0 mode=pad to=lx dz=0\nbind 0 a press=key:12\nroute a both")
        pe_dev_axis(r.engine, 1, 0, 20000, 1)
        r.press("a", true, 1.01); _ = r.take()
        pe_release_main(r.engine, 2)
        XCTAssertEqual(r.axes[0], 20000)
        XCTAssertEqual(Set(r.take()), Set(["pad a up", "key 12 up"]))
        r.press("a", true, 3)
        XCTAssertEqual(r.take(), ["pad a down", "key 12 down"])
    }
}

final class PadCleanupNoActionTests: XCTestCase {
    func testCleanupClosesRadialMenuWithoutSelectingItsAction() {
        for device in [false, true] {
            let binding = device ? "device 1 vendor=1 product=2 kind=joystick\nbind 0 d1b0 press=menu:0" : "bind 0 rb press=menu:0"
            let r = PadRecorder("menu 0 stick=1 s0=mouse:left\n" + binding)
            if device { pe_dev_button(r.engine, 1, 0, true, 1) } else { r.press("rb", true, 1) }
            pe_axis(r.engine, Int32(PE_AXIS_RY), -32767, 1.01); _ = r.take()
            if device { pe_release_device(r.engine, 1, 2) } else { pe_release_all(r.engine, 2) }
            XCTAssertTrue(r.take().isEmpty, "Disconnect/cleanup must not click the selected radial slice")
        }
    }
    func testCleanupDoesNotFirePendingVirtualTapDuringLayerRelease() {
        let r = PadRecorder("stick 0 mode=dirs\nstick 0 layer=1 mode=dirs\nbind 0 lb press=layer:hold:1\nbind 1 lsup tap=mouse:left hold=key:12 holdtime=10")
        r.press("lb", true, 1); pe_axis(r.engine, Int32(PE_AXIS_LY), -32767, 1.01); _ = r.take()
        pe_release_all(r.engine, 1.02)
        XCTAssertFalse(r.take().contains("mouse 0 down"))
    }
}

final class PadTimerCapacityTests: XCTestCase {
    func saturate(_ r: PadRecorder) {
        for slot in 1...2 { for button in 0..<32 { pe_dev_button(r.engine, Int32(slot), Int32(button), true, 1) } }
    }
    var pending: String {
        (1...2).flatMap { slot in (0..<32).map { "bind 0 d\(slot)b\($0) hold=key:13 holdtime=1000" } }.joined(separator: "\n")
    }
    func testTapDoesNotEmitDownWhenNoReleaseCanBeScheduled() {
        let r = PadRecorder(pending + "\nbind 0 a tap=key:12 hold=key:15 holdtime=0.2")
        saturate(r); _ = r.take()
        r.press("a", true, 1.01); r.press("a", false, 1.02)
        XCTAssertTrue(r.take().isEmpty)
        pe_release_all(r.engine, 2); XCTAssertTrue(r.take().isEmpty)
    }
    func testSequenceReleasesHeldOutputsWhenContinuationQueueIsFull() {
        let r = PadRecorder(pending + "\nmacro 0 down:key:12 wait:100 up:key:12\nbind 0 a press=macro:0")
        saturate(r); _ = r.take()
        r.press("a", true, 1.01)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up"])
        r.press("a", false, 1.02); r.tick(2); XCTAssertTrue(r.take().isEmpty)
    }
}

final class PadDelayedToggleOwnerTests: XCTestCase {
    func testCompletedMacroToggleRetainsDeviceOriginForDisconnectCleanup() {
        let r = PadRecorder("device 1 vendor=1 product=2 kind=joystick\nmacro 0 wait:100 down:keytoggle:12\nbind 0 d1b0 press=macro:0")
        pe_dev_button(r.engine, 1, 0, true, 1)
        r.tick(1.2); XCTAssertEqual(r.take(), ["key 12 down"])
        pe_release_device(r.engine, 1, 1.3)
        XCTAssertEqual(r.take(), ["key 12 up"])
    }
}

final class PadSensorRouteTests: XCTestCase {
    func testTouchRoutingControlsMappingAndWinePassthroughIndependently() {
        for route in ["native", "both", "mapped", "disabled"] {
            let r = PadRecorder("touch mode=zones\nbind 0 tz1 press=key:12\nroute touch \(route)")
            pe_touch(r.engine, 0, true, 0.2, 0.2, 1); pe_touch(r.engine, 0, false, 0.2, 0.2, 1.1)
            XCTAssertEqual(r.take(), ["both", "mapped"].contains(route) ? ["key 12 down", "key 12 up"] : [])
            XCTAssertEqual(pe_touch_passthrough(r.engine), ["native", "both"].contains(route))
        }
    }
    func testTiltRouteAndReportedGyroStateRespectDisabledMapping() {
        for route in ["native", "both", "mapped", "disabled"] {
            let r = PadRecorder("bind 0 tiltright press=key:12\ngyro out=mouse on=1\nroute tilt \(route)\nroute gyro \(route)")
            pe_accel(r.engine, 1, 1, 0, 1); pe_accel(r.engine, 0, 1, 0, 1.1)
            let maps = ["both", "mapped"].contains(route)
            XCTAssertEqual(r.take(), maps ? ["key 12 down", "key 12 up"] : [])
            XCTAssertEqual(pe_active_gyro(r.engine), maps ? 1 : 0)
        }
    }
}

final class PadLiveOutputTransitionTests: XCTestCase {
    func testPadToMouseAndBackPreservesPositionAndHeldButton() {
        let r = PadRecorder("stick 1 mode=pad dz=0 outer=1 sens=100 power=1\nbind 0 a press=key:12")
        pe_axis(r.engine, Int32(PE_AXIS_RX), 32767, 1); r.press("a", true, 1.01); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\nstick 1 mode=mouse dz=0 outer=1 sens=100 power=1\nbind 0 a press=key:12"))
        XCTAssertEqual(r.axes[2], 0); XCTAssertTrue(r.take().isEmpty)
        r.tick(1.11); XCTAssertGreaterThan(r.mouse.x, 0)
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\nstick 1 mode=pad dz=0 outer=1 sens=100 power=1\nbind 0 a press=key:12"))
        XCTAssertEqual(r.axes[2], 32767)
        r.press("a", false, 2); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testGyroOutputOffClearsOnlyItsAnalogContribution() {
        let r = PadRecorder("gyro out=rstick min=8 max=8 stickfull=100 stickmin=0 cal=off\nbind 0 a press=keytoggle:12")
        r.press("a", true, 1); r.press("a", false, 1.01); _ = r.take()
        pe_gyro(r.engine, 0, -1, 0, 1.02)
        XCTAssertGreaterThan(r.axes[2], 0)
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\ngyro out=off min=8 max=8 stickfull=100 stickmin=0 cal=off\nbind 0 a press=keytoggle:12"))
        XCTAssertEqual(r.axes[2], 0); XCTAssertTrue(r.take().isEmpty)
        r.press("a", true, 2); r.press("a", false, 2.01); XCTAssertEqual(r.take(), ["key 12 up"])
    }
}

final class PadLiveIndependentActionTests: XCTestCase {
    func testUnrelatedEditPreservesRunningMacroAndDeadline() {
        let text = "macro 0 down:key:12 wait:100 up:key:12\nbind 0 a press=macro:0\nbind 0 b press=key:13"
        let r = PadRecorder(text)
        r.press("a", true, 1); r.press("a", false, 1.01)
        XCTAssertEqual(r.take(), ["key 12 down"])
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=key:13", with: "press=key:14")))
        XCTAssertTrue(r.take().isEmpty)
        r.press("b", true, 1.02); r.press("b", false, 1.03)
        XCTAssertEqual(r.take(), ["key 14 down", "key 14 up"])
        r.tick(1.11); XCTAssertEqual(r.take(), ["key 12 up"])
        r.tick(2); XCTAssertTrue(r.take().isEmpty)
    }
    func testUnrelatedEditPreservesTapPulse() {
        let text = "bind 0 a tap=key:12 hold=key:13 holdtime=0.2\nbind 0 b press=key:14"
        let r = PadRecorder(text)
        r.press("a", true, 1); r.press("a", false, 1.01)
        XCTAssertEqual(r.take(), ["key 12 down"])
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=key:14", with: "press=key:15")))
        XCTAssertTrue(r.take().isEmpty)
        r.tick(1.05); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testUnrelatedEditPreservesSimultaneousPendingAndActivePair() {
        let text = "bind 0 a press=key:12 sim=b simout=key:13\nbind 0 b press=key:14\nbind 0 x press=key:15"
        let r = PadRecorder(text)
        r.press("a", true, 1)
        let updated = "nokpad 1\n" + text.replacingOccurrences(of: "press=key:15", with: "press=key:16")
        XCTAssertTrue(pe_update_profile(r.engine, updated))
        r.press("b", true, 1.02); XCTAssertEqual(r.take(), ["key 13 down"])
        XCTAssertTrue(pe_update_profile(r.engine, updated.replacingOccurrences(of: "press=key:16", with: "press=key:17")))
        XCTAssertTrue(r.take().isEmpty)
        r.press("b", false, 1.03); r.press("a", false, 1.04)
        XCTAssertEqual(r.take(), ["key 13 up"])
        r.tick(2); XCTAssertTrue(r.take().isEmpty)
    }
    func testEditingMacroOwnerStillRejectsWithoutCancellingIt() {
        let text = "macro 0 down:key:12 wait:100 up:key:12\nbind 0 a press=macro:0"
        let r = PadRecorder(text)
        r.press("a", true, 1); _ = r.take()
        XCTAssertFalse(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=macro:0", with: "press=key:14")))
        XCTAssertTrue(r.take().isEmpty)
        r.tick(1.11); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testEditingSimultaneousPeerRejectsWithoutMutation() {
        let text = "bind 0 a press=key:12 sim=b simout=key:13\nbind 0 b press=key:14"
        let r = PadRecorder(text)
        r.press("a", true, 1)
        XCTAssertFalse(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=key:14", with: "press=key:15")))
        r.press("b", true, 1.02); XCTAssertEqual(r.take(), ["key 13 down"])
        r.press("b", false, 1.03); r.press("a", false, 1.04)
        XCTAssertEqual(r.take(), ["key 13 up"])
    }
}

final class PadLiveLatchedModeTests: XCTestCase {
    func testReplacingLatchedLayerOwnerReturnsToBaseWithoutReleasingOtherHold() {
        let text = "bind 0 lb press=layer:toggle:1\nbind 0 a press=key:12\nbind 1 a press=key:13"
        let r = PadRecorder(text)
        r.press("lb", true, 1); r.press("lb", false, 1.01)
        r.press("a", true, 1.02); XCTAssertEqual(r.take(), ["key 13 down"])
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=layer:toggle:1", with: "press=key:14")))
        XCTAssertEqual(pe_active_layer(r.engine), 0)
        XCTAssertTrue(r.take().isEmpty)
        r.press("a", false, 1.03); XCTAssertEqual(r.take(), ["key 13 up"])
        r.press("a", true, 1.04); r.press("a", false, 1.05)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up"])
    }
    func testReplacingGyroToggleOwnerClearsOnlyItsLatchedState() {
        let text = "gyro out=mouse on=0 cal=off\nbind 0 a press=gyro:toggle\nbind 0 b press=key:12"
        let r = PadRecorder(text)
        r.press("a", true, 1); r.press("a", false, 1.01)
        XCTAssertEqual(pe_active_gyro(r.engine), 1)
        r.press("b", true, 1.02); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=gyro:toggle", with: "press=key:14")))
        XCTAssertEqual(pe_active_gyro(r.engine), 0)
        XCTAssertTrue(r.take().isEmpty)
        r.press("b", false, 1.03); XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testUnrelatedEditPreservesLatchedLayerAndGyro() {
        let text = "gyro out=mouse on=0 cal=off\nbind 0 a press=gyro:toggle\nbind 0 lb press=layer:toggle:1\nbind 0 b press=key:12"
        let r = PadRecorder(text)
        r.press("a", true, 1); r.press("a", false, 1.01)
        r.press("lb", true, 1.02); r.press("lb", false, 1.03)
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "press=key:12", with: "press=key:14")))
        XCTAssertEqual(pe_active_layer(r.engine), 1)
        XCTAssertEqual(pe_active_gyro(r.engine), 1)
    }
}

final class PadLiveKeyStickTests: XCTestCase {
    func testKeyReplacementReleasesOldDirectionAndRetainsOtherHold() {
        let text = "stick 0 mode=keys keys=13,1,0,2\nbind 0 a press=key:12"
        let r = PadRecorder(text)
        r.press("a", true, 1)
        pe_axis(r.engine, Int32(PE_AXIS_LY), -32767, 1.01)
        XCTAssertEqual(r.take(), ["key 12 down", "key 13 down"])
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "13,1,0,2", with: "14,1,0,2")))
        XCTAssertEqual(r.take(), ["key 13 up", "key 14 down"])
        pe_axis(r.engine, Int32(PE_AXIS_LY), 0, 1.02)
        r.press("a", false, 1.03)
        XCTAssertEqual(r.take(), ["key 14 up", "key 12 up"])
    }
    func testLeavingKeysDoesNotReleaseSameKeyHeldByAnotherButton() {
        let text = "stick 0 mode=keys keys=13,1,0,2\nbind 0 a press=key:13"
        let r = PadRecorder(text)
        r.press("a", true, 1); pe_axis(r.engine, Int32(PE_AXIS_LY), -32767, 1.01); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "mode=keys", with: "mode=mouse")))
        XCTAssertTrue(r.take().isEmpty)
        r.press("a", false, 1.02); XCTAssertEqual(r.take(), ["key 13 up"])
        pe_axis(r.engine, Int32(PE_AXIS_LY), 0, 1.03)
        XCTAssertTrue(r.take().isEmpty)
    }
    func testEnteringKeysFromMouseUsesCurrentPositionWithoutInterruptingToggle() {
        let text = "stick 0 mode=mouse keys=13,1,0,2\nbind 0 a press=keytoggle:12"
        let r = PadRecorder(text)
        r.press("a", true, 1); r.press("a", false, 1.01)
        pe_axis(r.engine, Int32(PE_AXIS_LY), -32767, 1.02); _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "mode=mouse", with: "mode=keys")))
        XCTAssertEqual(r.take(), ["key 13 down"])
        pe_release_all(r.engine, 1.03)
        XCTAssertEqual(Set(r.take()), Set(["key 13 up", "key 12 up"]))
    }
    func testInvalidDirectionalKeyCodesAreIgnoredOnPressAndRelease() {
        let r = PadRecorder("stick 0 mode=keys keys=-1,128,9999,-1000")
        for axis in [PE_AXIS_LX, PE_AXIS_LY] {
            for value in [-32767, 32767, 0] { pe_axis(r.engine, Int32(axis), Int32(value), 1) }
        }
        pe_release_all(r.engine, 2)
        XCTAssertTrue(r.take().isEmpty)
    }
}

final class PadControllerOutputToggleTests: XCTestCase {
    func testControllerButtonStaysHeldUntilSecondPressAndIgnoresDuplicateDown() {
        let r = PadRecorder("bind 0 a press=padtoggle:b")
        r.press("a", true, 1); r.press("a", true, 1.01); r.press("a", false, 1.02)
        XCTAssertEqual(r.take(), ["pad b down"])
        r.press("a", true, 2); r.press("a", false, 2.01)
        XCTAssertEqual(r.take(), ["pad b up"])
    }
    func testToggleReleaseDoesNotReleaseAnotherButtonsHold() {
        let r = PadRecorder("bind 0 a press=padtoggle:x\nbind 0 b press=pad:x")
        r.press("a", true, 1); r.press("a", false, 1.01)
        r.press("b", true, 1.02); XCTAssertEqual(r.take(), ["pad x down"])
        r.press("a", true, 1.03); r.press("a", false, 1.04)
        XCTAssertTrue(r.take().isEmpty)
        r.press("b", false, 1.05); XCTAssertEqual(r.take(), ["pad x up"])
    }
    func testTriggerToggleAndCleanupRetainAnotherTriggerHold() {
        let r = PadRecorder("bind 0 a press=trigtoggle:r\nbind 0 b press=trig:r")
        r.press("a", true, 1); r.press("a", false, 1.01)
        XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 32767)
        r.press("b", true, 1.02)
        r.press("a", true, 1.03); r.press("a", false, 1.04)
        XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 32767)
        r.press("b", false, 1.05); XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 0)
        r.press("a", true, 2); r.press("a", false, 2.01)
        pe_release_all(r.engine, 2.02); XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 0)
        r.press("a", true, 3); r.press("a", false, 3.01)
        XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 32767)
    }
    func testChangedOwnerReleasesControllerTogglesAndUnrelatedOwnerSurvives() {
        let text = "bind 0 a press=padtoggle:x,trigtoggle:l\nbind 0 b press=padtoggle:y"
        let r = PadRecorder(text)
        for button in ["a", "b"] { r.press(button, true, 1); r.press(button, false, 1.01) }
        _ = r.take()
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "padtoggle:x,trigtoggle:l", with: "key:12")))
        XCTAssertEqual(r.take(), ["pad x up"])
        XCTAssertEqual(r.axes[Int(PE_AXIS_LT)], 0)
        r.press("b", true, 2); r.press("b", false, 2.01)
        XCTAssertEqual(r.take(), ["pad y up"])
    }
    func testDeviceDisconnectClearsOnlyItsLatchedControllerOutputs() {
        let r = PadRecorder("device 1 vendor=1 product=2\nbind 0 d1b0 press=padtoggle:x,trigtoggle:r\nbind 0 a press=padtoggle:y")
        pe_dev_button(r.engine, 1, 0, true, 1); pe_dev_button(r.engine, 1, 0, false, 1.01)
        r.press("a", true, 1.02); r.press("a", false, 1.03); _ = r.take()
        pe_release_device(r.engine, 1, 1.04)
        XCTAssertEqual(r.take(), ["pad x up"])
        XCTAssertEqual(r.axes[Int(PE_AXIS_RT)], 0)
        pe_release_all(r.engine, 1.05); XCTAssertEqual(r.take(), ["pad y up"])
    }
    func testFullCleanupResetsGyroToggleToItsDefault() {
        let r = PadRecorder("gyro out=mouse on=0 cal=off\nbind 0 a press=gyro:toggle")
        r.press("a", true, 1); r.press("a", false, 1.01)
        XCTAssertEqual(pe_active_gyro(r.engine), 1)
        pe_release_all(r.engine, 1.02)
        XCTAssertEqual(pe_active_gyro(r.engine), 0)
        r.press("a", true, 2); r.press("a", false, 2.01)
        XCTAssertEqual(pe_active_gyro(r.engine), 1)
    }
}

final class PadSharedMotionPauseTests: XCTestCase {
    func testOffHoldsPauseHeadMotionEvenWithControllerGyroUnconfigured() {
        let r = PadRecorder("gyro out=off\nbind 0 a press=gyro:off\nbind 0 b press=gyro:off\nbind 0 x press=gyro:on")
        XCTAssertFalse(pe_motion_paused(r.engine))
        r.press("a", true, 1); r.press("b", true, 1.01); r.press("x", true, 1.02)
        XCTAssertTrue(pe_motion_paused(r.engine))
        r.press("a", false, 1.03); XCTAssertTrue(pe_motion_paused(r.engine))
        r.press("b", false, 1.04); XCTAssertFalse(pe_motion_paused(r.engine))
    }
    func testPauseOwnershipClearsOnEditDisconnectAndFullRelease() {
        let text = "device 1 vendor=1 product=2\nbind 0 d1b0 press=gyro:off\nbind 0 a press=gyro:off"
        let r = PadRecorder(text)
        pe_dev_button(r.engine, 1, 0, true, 1); r.press("a", true, 1.01)
        pe_release_device(r.engine, 1, 1.02); XCTAssertTrue(pe_motion_paused(r.engine))
        XCTAssertTrue(pe_update_profile(r.engine, "nokpad 1\n" + text.replacingOccurrences(of: "bind 0 a press=gyro:off", with: "bind 0 a press=key:12")))
        XCTAssertFalse(pe_motion_paused(r.engine))
        pe_dev_button(r.engine, 1, 0, true, 2); XCTAssertTrue(pe_motion_paused(r.engine))
        pe_release_all(r.engine, 2.01); XCTAssertFalse(pe_motion_paused(r.engine))
    }
}
