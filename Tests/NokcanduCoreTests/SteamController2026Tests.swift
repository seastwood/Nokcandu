import XCTest
@testable import NokcanduCore

/// Reports built to the layout in Valve's SDL driver (SDL_hidapi_steam_triton.c, controller_structs.h).
final class SteamController2026Tests: XCTestCase {
    private func le(_ v: Int) -> [UInt8] { let u = UInt16(truncatingIfNeeded: v); return [UInt8(u & 255), UInt8(u >> 8)] }
    /// A 0x42 report: buttons, triggers, sticks, pads (x, y, pressure), then motion (timestamp, accel, gyro).
    private func report(id: UInt8 = 0x42, buttons: UInt32 = 0, lt: Int = 0, rt: Int = 0, ls: (Int, Int) = (0, 0), rs: (Int, Int) = (0, 0),
                        lp: (Int, Int, Int) = (0, 0, 0), rp: (Int, Int, Int) = (0, 0, 0), accel: (Int, Int, Int) = (0, 0, 16384), gyro: (Int, Int, Int) = (0, 0, 0)) -> [UInt8] {
        var b: [UInt8] = [id, 7]
        b += [UInt8(buttons & 255), UInt8(buttons >> 8 & 255), UInt8(buttons >> 16 & 255), UInt8(buttons >> 24)]
        b += le(lt) + le(rt) + le(ls.0) + le(ls.1) + le(rs.0) + le(rs.1)
        if id == 0x47 { b += le(1234) }
        b += le(lp.0) + le(lp.1) + le(lp.2) + le(rp.0) + le(rp.1) + le(rp.2)
        b += id == 0x47 ? le(99) : [0, 0, 0, 0]
        b += le(accel.0) + le(accel.1) + le(accel.2) + le(gyro.0) + le(gyro.1) + le(gyro.2)
        return b
    }

    func testInterfacesAreFound() {
        XCTAssertEqual(SteamController2026.identify(vendor: 0x28de, product: 0x1302, interface: 0), .cable)
        XCTAssertEqual(SteamController2026.identify(vendor: 0x28de, product: 0x1303, interface: -1), .bluetooth)
        for slot in 2...5 { XCTAssertEqual(SteamController2026.identify(vendor: 0x28de, product: 0x1304, interface: slot), .receiver) }
        XCTAssertNil(SteamController2026.identify(vendor: 0x28de, product: 0x1304, interface: 1))
        XCTAssertNil(SteamController2026.identify(vendor: 0x1234, product: 0x1302, interface: 0))
    }

    func testButtonsSticksTriggersAndSensors() {
        let bits: UInt32 = 0x1 | 0x10 | 0x80 | 0x40000 | 0x2000 | 0x0040_0000 | 0x2000_0000 | 0x0010_0000
        let st = try! XCTUnwrap(SteamController2026.decode(report(buttons: bits, lt: 16384, rt: 32767, ls: (16384, -16384), rs: (-32768, 32767)), counter: 1))
        XCTAssertEqual(st.kind, .steam2026)
        XCTAssertEqual(st.buttons, [.a, .misc, .paddle1, .paddle4, .up, .rpclick, .lgrip, .rstouch])
        XCTAssertEqual(st.leftTrigger, 16384.0 / 32767, accuracy: 1e-4)
        XCTAssertEqual(st.rightTrigger, 1)
        XCTAssertEqual(st.stick.x, 16384.0 / 32767, accuracy: 1e-4)
        XCTAssertEqual(st.rightStick.x, -1); XCTAssertEqual(st.rightStick.y, 1)
        // The right stick is the engine's right stick, whatever the right pad does.
        XCTAssertEqual(st.axes[2], -32767); XCTAssertEqual(st.axes[3], -32767)
        XCTAssertEqual(st.padClick(1), .rpclick); XCTAssertEqual(st.padClick(0), .touchpad)
        // A trigger's click is a full pull.
        XCTAssertEqual(SteamController2026.decode(report(buttons: 0x0800_0000, lt: 100), counter: 2)?.leftTrigger, 1)
    }

    func testPadsPressureAndMotionInBothLayouts() {
        for id: UInt8 in [0x42, 0x45, 0x47] {
            let st = try! XCTUnwrap(SteamController2026.decode(report(id: id, buttons: 0x0200_0000 | 0x0020_0000, lp: (8000, -8000, 16384), rp: (-4000, 4000, 32767),
                                                                     accel: (100, 200, 16384), gyro: (10, 20, 30)), counter: 1), "report \(id)")
            XCTAssertTrue(st.leftTouch); XCTAssertTrue(st.rightTouch)
            XCTAssertEqual(st.leftPad.x, 8000.0 / 32767, accuracy: 1e-4)
            XCTAssertEqual(st.rightPad.y, 4000.0 / 32767, accuracy: 1e-4)
            XCTAssertEqual(st.leftPressure, 0.5, accuracy: 1e-3)
            XCTAssertEqual(st.rightPressure, 1, accuracy: 1e-3)
            XCTAssertEqual(st.acceleration[2], 1, accuracy: 1e-4)
            let scale = Float(2000.0 / 32768.0 * Double.pi / 180)
            // Read like the original's axes: y flipped (SDL gives this one's as x, z, −y and the original's as x, z, y).
            XCTAssertEqual(st.gyro[0], 10 * scale, accuracy: 1e-6)
            XCTAssertEqual(st.gyro[1], -20 * scale, accuracy: 1e-6)
            XCTAssertEqual(st.gyro[2], 30 * scale, accuracy: 1e-6)
        }
        // Pads not touched read as centred; other reports aren't state.
        let idle = try! XCTUnwrap(SteamController2026.decode(report(lp: (9000, 9000, 0)), counter: 1))
        XCTAssertFalse(idle.leftTouch); XCTAssertEqual(idle.leftPad, SteamControllerReport.Point())
        XCTAssertNil(SteamController2026.decode([0x43] + [UInt8](repeating: 0, count: 50), counter: 1))
        XCTAssertNil(SteamController2026.decode(Array(report().prefix(30)), counter: 1))
    }

    func testRightPadAsStickOnlyWhenPushedFurther() {
        var st = try! XCTUnwrap(SteamController2026.decode(report(buttons: 0x0020_0000, rs: (8000, 0), rp: (16000, 0, 0)), counter: 1))
        XCTAssertEqual(st.mappingAxes(rightTrackpadAsStick: true)[2], Int(Float(16000) / 32767 * 32767))
        XCTAssertEqual(st.mappingAxes(rightTrackpadAsStick: false)[2], Int(Float(8000) / 32767 * 32767))
        st.rightStick = .init(1, 0)
        XCTAssertEqual(st.mappingAxes(rightTrackpadAsStick: true)[2], 32767)
    }

    func testReportsOut() {
        let k = SteamController2026.keepAlive
        XCTAssertEqual(k.count, 64)
        XCTAssertEqual(Array(k.prefix(9)), [1, 0x87, 6, 9, 0, 0, 48, 0x18, 0])
        let original = try! XCTUnwrap(SteamControllerHaptics.pulse(side: 0, strength: 1))
        XCTAssertEqual(SteamController2026.pulse(fromOriginal: original), [0x81] + Array(original[2..<9]))
        XCTAssertEqual(SteamController2026.rumble(low: 0x1234, high: 0xffff), [0x80, 0, 0, 0, 0x34, 0x12, 0, 0xff, 0xff, 0])
        XCTAssertEqual(SteamController2026.event([0x79, 1]), .disconnected)
        XCTAssertEqual(SteamController2026.event([0x46, 2]), .connected)
        XCTAssertNil(SteamController2026.event([0x42, 1]))
    }
}
