import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

/// Reading controllers taken from macOS: their reports, checked against the virtual controller's own (the same
/// layouts, built by NokcanduPadEngine/virtualpad.c), plus start-up and rumble.
final class TakeoverPadTests: XCTestCase {
    private func state(_ buttons: [Int32], axes: [Int: Int16] = [:]) -> vp_state {
        var s = vp_state()
        for b in buttons { s.buttons |= 1 << UInt32(b) }
        withUnsafeMutableBytes(of: &s.axes) { raw in
            let a = raw.bindMemory(to: Int16.self)
            for (i, v) in axes { a[i] = v }
        }
        s.accel.1 = 9.80665
        return s
    }
    private func report(_ kind: Int32, _ s: vp_state, pro: Bool = false) -> [UInt8] {
        var d = vp_device(); vp_init(&d, kind, 0)
        if pro { d.pro_full = true; d.pro_imu = true }
        var out = [UInt8](repeating: 0, count: 64), st = s
        let n = vp_input_report(&d, &st, &out, 64)
        return Array(out.prefix(n))
    }

    func testIdentities() {
        XCTAssertEqual(TakeoverPad.find(vendor: 0x054C, product: 0x05C4), .ps4)
        XCTAssertEqual(TakeoverPad.find(vendor: 0x054C, product: 0x0CE6), .ps5)
        XCTAssertEqual(TakeoverPad.find(vendor: 0x045E, product: 0x0B13), .xbox)
        XCTAssertNil(TakeoverPad.find(vendor: 0x045E, product: 0x02FD), "older Xbox firmware stays with macOS")
        XCTAssertEqual(TakeoverPad.find(vendor: 0x057E, product: 0x2009), .switchPro)
        XCTAssertNil(TakeoverPad.find(vendor: 0x28DE, product: 0x1102), "Steam Controllers have their own reader")
        XCTAssertEqual(TakeoverPad.matching.count, 9)
    }

    func testXboxBluetoothReport() throws {
        let r = report(Int32(VP_XBOX), state([Int32(PE_A), Int32(PE_Y), Int32(PE_LB), Int32(PE_GUIDE), Int32(PE_RS), Int32(PE_UP), Int32(PE_RIGHT), Int32(PE_MISC)],
                                             axes: [0: 32767, 1: -32768, 5: 32767]))
        let s = try XCTUnwrap(XboxBluetoothPad.decode(r))
        XCTAssertEqual(s.buttons, [.a, .y, .lb, .guide, .rs, .up, .right, .misc])
        XCTAssertEqual(s.axes[0], 32767); XCTAssertEqual(s.axes[1], -32767); XCTAssertEqual(s.axes[2], 0)
        XCTAssertEqual(s.axes[5], 32767); XCTAssertEqual(s.axes[4], 0)
        XCTAssertNil(XboxBluetoothPad.decode([0x02, 0x01]))
    }

    func testSwitchProReportIsPositional() throws {
        let r = report(Int32(VP_SWITCH_PRO), state([Int32(PE_A), Int32(PE_X), Int32(PE_BACK), Int32(PE_GUIDE), Int32(PE_DOWN), Int32(PE_LB)],
                                                   axes: [0: 32767, 1: 16384, 4: 32767]), pro: true)
        let s = try XCTUnwrap(SwitchProPad.decode(r, calibration: .init(centre: [2048, 2048, 2048, 2048], below: [1792, 1792, 1792, 1792], above: [1792, 1792, 1792, 1792])))
        XCTAssertEqual(s.buttons, [.a, .x, .back, .guide, .down, .lb])
        XCTAssertEqual(Double(s.axes[0]!), 32767, accuracy: 40); XCTAssertEqual(Double(s.axes[1]!), 16384, accuracy: 40, "y down, as the engine's")
        XCTAssertEqual(s.axes[4], 32767, "ZL"); XCTAssertEqual(s.axes[5], 0)
        let a = try XCTUnwrap(s.acceleration)
        XCTAssertEqual(a[2], 1, accuracy: 0.01, "1 g on SDL's y, which is Nokcandu's third axis")
        XCTAssertEqual(a[0], 0, accuracy: 0.01); XCTAssertEqual(a[1], 0, accuracy: 0.01)
    }

    func testSwitchProCalibrationReply() throws {
        func pack(_ a: Int, _ b: Int) -> [UInt8] { [UInt8(a & 0xFF), UInt8((a >> 8) & 0x0F | (b & 0x0F) << 4), UInt8(b >> 4)] }
        var r = [UInt8](repeating: 0, count: 49)
        r[0] = 0x21; r[14] = 0x10; r[15] = 0x3D; r[16] = 0x60; r[19] = 18
        let flash = pack(1500, 1400) + pack(2000, 2100) + pack(1300, 1350) + pack(2050, 1990) + pack(1450, 1500) + pack(1550, 1600)
        r.replaceSubrange(20..<38, with: flash)
        let c = try XCTUnwrap(SwitchProPad.calibration(fromReply: r))
        XCTAssertEqual(c.centre, [2000, 2100, 2050, 1990]); XCTAssertEqual(c.above, [1500, 1400, 1550, 1600]); XCTAssertEqual(c.below, [1300, 1350, 1450, 1500])
        var erased = r; erased.replaceSubrange(20..<38, with: [UInt8](repeating: 0xFF, count: 18))
        XCTAssertNil(SwitchProPad.calibration(fromReply: erased))
        var decoder = TakeoverPadDecoder(.switchPro, bluetooth: true)
        _ = decoder.decode(r); XCTAssertEqual(decoder.proSticks, c)
    }

    func testSwitchProStartUp() {
        var bt = TakeoverPadDecoder(.switchPro, bluetooth: true), usb = TakeoverPadDecoder(.switchPro, bluetooth: false)
        let b = bt.start(), u = usb.start()
        XCTAssertEqual(b.map { $0[10] }, [0x03, 0x40, 0x48, 0x10]); XCTAssertEqual(b[0][11], 0x30)
        XCTAssertTrue(b.allSatisfy { $0.count == 49 && $0[0] == 0x01 })
        XCTAssertEqual(Array(u.prefix(4)), [[0x80, 0x02], [0x80, 0x03], [0x80, 0x02], [0x80, 0x04]])
        XCTAssertTrue(u.dropFirst(4).allSatisfy { $0.count == 64 })
        XCTAssertEqual(Set(b.map { $0[1] }).count, 4, "each command its own counter")
    }

    func testRumbleReports() {
        var ps4u = TakeoverPadDecoder(.ps4, bluetooth: false), ps4b = TakeoverPadDecoder(.ps4, bluetooth: true)
        XCTAssertEqual(ps4u.rumble(low: 1, high: 0.5).prefix(6), [0x05, 0x01, 0, 0, 128, 255])
        let b = ps4b.rumble(low: 1, high: 0)
        XCTAssertEqual(b.count, 78); XCTAssertEqual(b[0], 0x11); XCTAssertEqual(b[7], 255)
        let crc = PlayStationPad.crc32([0xA2] + b[0..<74])
        XCTAssertEqual(UInt32(b[74]) | UInt32(b[75]) << 8 | UInt32(b[76]) << 16 | UInt32(b[77]) << 24, crc)
        XCTAssertEqual(PlayStationPad.crc32(Array("123456789".utf8)), 0xCBF4_3926, "standard CRC-32")
        var ps5 = TakeoverPadDecoder(.ps5, bluetooth: true)
        let p = ps5.rumble(low: 0.5, high: 1); XCTAssertEqual(p[0], 0x31); XCTAssertEqual(p[4], 255); XCTAssertEqual(p[5], 128)
        var xbox = TakeoverPadDecoder(.xbox, bluetooth: true)
        XCTAssertEqual(xbox.rumble(low: 1, high: 0.5), [0x03, 0x0F, 0, 0, 100, 50, 0xFF, 0, 0xEB])
        var pro = TakeoverPadDecoder(.switchPro, bluetooth: true)
        XCTAssertEqual(pro.rumble(low: 1, high: 1).suffix(8), [0x74, 0xBE, 0xBD, 0x6F, 0x74, 0xBE, 0xBD, 0x6F])
        XCTAssertEqual(pro.rumble(low: 0, high: 0).suffix(4), [0x00, 0x01, 0x40, 0x40])
    }
}
