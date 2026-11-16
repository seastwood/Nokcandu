import XCTest
@testable import NokcanduCore

/// Reports and commands checked byte by byte against SDL's HIDAPI drivers (review of November 16, 2026): the
/// places a wrong byte, bit or sign would otherwise only show with the controller in hand.
final class ControllerDriverLayoutTests: XCTestCase {
    private func le(_ v: Int16) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }

    /// SDL_hidapi_8bitdo.c: PL 0x20 / PR 0x04 on most; the Ultimate 2C has L4 0x04 / R4 0x20.
    func testEightBitDoBackButtonsByModel() {
        var d = [UInt8](repeating: 0, count: 12)
        d[0] = 0x04; d[1] = 8; d[2] = 0x7F; d[3] = 0x7F; d[4] = 0x7F; d[5] = 0x7F
        d[8] = 0x04
        var pro2 = ReportPadDecoder(.eightBitDo(product: 0x6003)), ultimate2C = ReportPadDecoder(.eightBitDo(product: 0x301B))
        XCTAssertEqual(pro2.decode(d)?.buttons, [.paddle1])              // PR: right
        XCTAssertEqual(ultimate2C.decode(d)?.buttons, [.paddle2])        // L4: left
        d[8] = 0x20
        XCTAssertEqual(pro2.decode(d)?.buttons, [.paddle2])              // PL: left
        XCTAssertEqual(ultimate2C.decode(d)?.buttons, [.paddle1])        // R4: right
    }

    func testRumbleReports() {
        XCTAssertEqual(ReportPadDriver.eightBitDo(product: 0x6003).rumble(low: 1, high: 0.5), [0x05, 255, 127, 0, 0])
        XCTAssertEqual(ReportPadDriver.lunaBluetooth.rumble(low: 1, high: 0.5), [0x03, 0x0F, 0, 0, 100, 50, 0xFF, 0, 0xEB])
        XCTAssertNil(ReportPadDriver.lunaUSB.rumble(low: 1, high: 1))
        let sinput = try! XCTUnwrap(ReportPadDriver.sinput.rumble(low: 1, high: 0.5))
        XCTAssertEqual(sinput.count, 48); XCTAssertEqual(Array(sinput.prefix(8)), [0x03, 0x01, 2, 255, 0, 127, 0, 0])
        XCTAssertEqual(ReportPadDriver.zuiki(product: 0x001C).rumble(low: 1, high: 0.5), [0, 0, 0, 0, 255, 127, 0, 0])
        XCTAssertNil(ReportPadDriver.zuiki(product: 0x0020).rumble(low: 1, high: 1))
        let gameSir = try! XCTUnwrap(ReportPadDriver.gameSir.rumble(low: 1, high: 0.5))
        XCTAssertEqual(gameSir.count, 64); XCTAssertEqual(Array(gameSir.prefix(5)), [0xA2, 0x03, 255, 127, 0])
        let mode = try! XCTUnwrap(ReportPadDriver.gameSir.startOutput)
        XCTAssertEqual(mode.count, 64); XCTAssertEqual(Array(mode.prefix(4)), [0xA2, 0x01, 0x00, 0])
        XCTAssertEqual(ReportPadDriver.shield(product: 0x7210).rumble(low: 1, high: 0.5), [0x01, 0, 255, 0, 127, 0, 0])
        XCTAssertNil(ReportPadDriver.shield(product: 0x7214).rumble(low: 1, high: 1))
        // PlayStation by USB: rumble only (no light change); the right (small, high) motor comes first.
        let ps4 = try! XCTUnwrap(ReportPadDriver.ps4.rumble(low: 1, high: 0.5))
        XCTAssertEqual(ps4.count, 32); XCTAssertEqual(Array(ps4.prefix(6)), [0x05, 0x01, 0, 0, 127, 255])
        let ps5 = try! XCTUnwrap(ReportPadDriver.ps5.rumble(low: 1, high: 0.5))
        XCTAssertEqual(ps5.count, 48); XCTAssertEqual(Array(ps5.prefix(5)), [0x02, 0x03, 0, 127, 255])
    }

    /// SDL_hidapi_luna.c, the 10-byte USB report.
    func testLunaUSB() {
        var dec = ReportPadDecoder(.lunaUSB)
        let d: [UInt8] = [0x01, 0x01 | 0x80, 0x02, 4, 0x7F, 0x7F, 0x7F, 0x7F, 255, 0]
        let s = try! XCTUnwrap(dec.decode(d))
        XCTAssertEqual(s.buttons, [.a, .start, .misc, .down])
        XCTAssertEqual(s.axes[0], 0); XCTAssertEqual(s.axes[4], 32767); XCTAssertEqual(s.axes[5], 0)
        XCTAssertNil(dec.decode(d + [0]))
    }

    /// Newer Xbox controllers send input messages longer than 32 bytes (the read takes a whole 64-byte packet).
    func testLongGIPInput() {
        var d = [UInt8](repeating: 0, count: 48)
        d[0] = 0x20; d[3] = 0x2C; d[4] = 0x10; d[6] = 0xFF; d[7] = 0x03
        var dec = GIPController.Decoder()
        let s = try! XCTUnwrap(dec.decode(d, last: nil))
        XCTAssertEqual(s.buttons, [.a]); XCTAssertEqual(s.axes[4], 32767); XCTAssertEqual(s.axes[1], 0)
    }

    /// SDL_hidapi_steam_hori.c: gyro (−16, −12, −14), acceleration (22, −20, 18) of the report, in SDL's axes.
    func testHoriSteam() {
        var d = [UInt8](repeating: 0, count: 24)
        d[0] = 0x07; d[1] = 0x80; d[2] = 0x80; d[3] = 0x80; d[4] = 0x80
        d[5] = 0x08 | 0x10; d[6] = 0x02; d[7] = 0x80; d[8] = 255
        d.replaceSubrange(12..<14, with: le(1000)); d.replaceSubrange(22..<24, with: le(4096))
        var dec = ReportPadDecoder(.horiSteam)
        let s = try! XCTUnwrap(dec.decode(d))
        XCTAssertEqual(s.buttons, [.a, .paddle2, .paddle4])
        XCTAssertEqual(s.axes[0], 0); XCTAssertEqual(s.axes[5], 32767); XCTAssertEqual(s.axes[4], 0)
        let g = try! XCTUnwrap(s.gyro), a = try! XCTUnwrap(s.acceleration)
        XCTAssertEqual(g[0], 0); XCTAssertEqual(g[1], 0); XCTAssertLessThan(g[2], 0)
        XCTAssertEqual(a[0], 1, accuracy: 0.001); XCTAssertEqual(a[1], 0); XCTAssertEqual(a[2], 0)
    }

    /// SDL_hidapi_gamesir.c: the d-pad counts from 1 (up) clockwise; L4 is 0x40 of the same byte.
    func testGameSirFullMode() {
        var p = [UInt8](repeating: 0, count: 14)
        p[0] = 0x01; p[2] = 0x03 | 0x40; p[12] = 255
        var dec = ReportPadDecoder(.gameSir)
        let s = try! XCTUnwrap(dec.decode([0xA1, 0xC8] + p))
        XCTAssertEqual(s.buttons, [.a, .right, .paddle2])
        XCTAssertEqual(s.axes[1], 0); XCTAssertEqual(s.axes[4], 32767); XCTAssertNil(s.gyro)
        XCTAssertEqual(dec.decode([0x43, 0xA1, 0xC8] + p)?.buttons, [.a, .right, .paddle2])
        XCTAssertNil(dec.decode([0x02] + p))
    }

    /// SDL_hidapi_zuiki.c: SDL's gyro is (8, 12, −10) of the USB report, its acceleration (14, 18, −16).
    func testZuikiUSBMotion() {
        var d = [UInt8](repeating: 0, count: 20)
        d[0] = 0x04 | 0x40; d[2] = 8; d[3] = 0x7F; d[4] = 0x7F; d[5] = 0x7F; d[6] = 0x7F
        d.replaceSubrange(10..<12, with: le(1000)); d.replaceSubrange(14..<16, with: le(4096))
        var dec = ReportPadDecoder(.zuiki(product: 0x001C))
        let s = try! XCTUnwrap(dec.decode(d))
        XCTAssertEqual(s.buttons, [.a]); XCTAssertEqual(s.axes[4], 32767); XCTAssertEqual(s.axes[0], 0)
        let g = try! XCTUnwrap(s.gyro), a = try! XCTUnwrap(s.acceleration)
        XCTAssertEqual(g[0], 0); XCTAssertLessThan(g[1], 0); XCTAssertEqual(g[2], 0)
        XCTAssertEqual(a[0], 1, accuracy: 0.001)
    }
}
