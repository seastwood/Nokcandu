import XCTest
@testable import NokcanduCore

/// Reports built to the layout in SDL's driver (SDL_hidapi_switch2.c).
final class Switch2ControllerTests: XCTestCase {
    private func report(_ set: [Int: UInt8] = [:], lx: Int = 2048, ly: Int = 2048, rx: Int = 2048, ry: Int = 2048) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 64)
        d[11] = UInt8(lx & 255); d[12] = UInt8(lx >> 8 & 0x0F) | UInt8(ly & 0x0F) << 4; d[13] = UInt8(ly >> 4)
        d[14] = UInt8(rx & 255); d[15] = UInt8(rx >> 8 & 0x0F) | UInt8(ry & 0x0F) << 4; d[16] = UInt8(ry >> 4)
        for (i, v) in set { d[i] = v }
        return d
    }

    func testProButtonsByTheirLetters() {
        let s = try! XCTUnwrap(Switch2Controller.decode(report([5: 0x08 | 0x80, 6: 0x10 | 0x20, 7: 0x02 | 0x40, 8: 0x01]), product: Switch2Controller.pro, calibration: .init()))
        XCTAssertEqual(s.buttons, [.a, .guide, .misc, .up, .lb, .paddle1])
        XCTAssertEqual(s.axes[5], 32767); XCTAssertEqual(s.axes[4], 0)
    }

    func testSticksWithAndWithoutCalibration() {
        let raw = try! XCTUnwrap(Switch2Controller.decode(report(lx: 4095, ly: 0), product: Switch2Controller.pro, calibration: .init()))
        XCTAssertGreaterThan(raw.axes[0]!, 32000)
        XCTAssertGreaterThan(raw.axes[1]!, 32000, "stick down is y down")
        var c = Switch2Controller.Calibration()
        c.left.x = .init(neutral: 2000, max: 1000, min: 1000)
        let cal = try! XCTUnwrap(Switch2Controller.decode(report(lx: 2500), product: Switch2Controller.pro, calibration: c))
        XCTAssertEqual(cal.axes[0]!, 16383, accuracy: 2)
    }

    func testCalibrationParsing() {
        // neutral x 0x123 y 0x456, max x 0x111 y 0x222, min x 0x333 y 0x444
        let b: [UInt8] = [0x23, 0x61, 0x45, 0x11, 0x21, 0x22, 0x33, 0x43, 0x44]
        let s = try! XCTUnwrap(Switch2Controller.stick(b[...]))
        XCTAssertEqual(s.x, .init(neutral: 0x123, max: 0x111, min: 0x333))
        XCTAssertEqual(s.y, .init(neutral: 0x456, max: 0x222, min: 0x444))
    }

    func testGameCubeTriggersAndMotion() {
        var c = Switch2Controller.Calibration(); c.leftTriggerZero = 32
        var r = report([5: 0x04, 61: 132, 62: 0])
        r[0x37] = 0x10; r[0x38] = 0x00; r[0x31] = 0xff; r[0x32] = 0x0f
        let s = try! XCTUnwrap(Switch2Controller.decode(r, product: Switch2Controller.gameCube, calibration: c))
        XCTAssertEqual(s.buttons, [.a])
        XCTAssertEqual(s.axes[4]!, 16383, accuracy: 2)
        XCTAssertEqual(s.gyro[0], 16 * 34.8 / 32767, accuracy: 1e-6)
        XCTAssertEqual(s.acceleration[0], 4095 * 8 / 32767, accuracy: 1e-4)
        XCTAssertNil(Switch2Controller.decode(Array(r.prefix(40)), product: Switch2Controller.pro, calibration: c))
        XCTAssertNil(Switch2Controller.decode(r, product: 0x1234, calibration: c))
    }

    func testCommands() {
        for c in Switch2Controller.startup { XCTAssertEqual(c.count, Int(c[5]) + 8, "length is byte 5 plus 8") }
        XCTAssertEqual(Array(Switch2Controller.flashRead(0x13080)[12..<16]), [0x80, 0x30, 0x01, 0x00])
    }
}

final class XInputControllerTests: XCTestCase {
    func testReports() {
        var d = [UInt8](repeating: 0, count: 20); d[1] = 0x14
        d[2] = 0x01 | 0x10; d[3] = 0x10 | 0x04; d[4] = 255; d[5] = 0
        d[6] = 0xff; d[7] = 0x7f                       // left x full right
        d[8] = 0x00; d[9] = 0x80                       // left y full down (−32768 up-positive)
        let s = try! XCTUnwrap(XInputController.decode(d))
        XCTAssertEqual(s.buttons, [.up, .start, .a, .guide])
        XCTAssertEqual(s.axes[0], 32767); XCTAssertEqual(s.axes[1], 32767, "down is +y")
        XCTAssertEqual(s.axes[4], 32767); XCTAssertEqual(s.axes[5], 0)
        XCTAssertNil(XInputController.decode([0x01, 0x03, 0x06]))
        XCTAssertEqual(XInputController.rumble(low: 10, high: 20), [0, 8, 0, 10, 20, 0, 0, 0])
    }
}

final class GIPControllerTests: XCTestCase {
    func testInputAndGuide() {
        var d = [UInt8](repeating: 0, count: 18); d[0] = 0x20; d[3] = 0x0e
        d[4] = 0x10 | 0x04; d[5] = 0x01 | 0x10; d[6] = 0xff; d[7] = 0x03
        d[12] = 0xff; d[13] = 0x7f                     // left y full up
        var g = GIPController.Decoder()
        let s = try! XCTUnwrap(g.decode(d, last: nil))
        XCTAssertEqual(s.buttons, [.a, .start, .up, .lb])
        XCTAssertEqual(s.axes[4], 32767); XCTAssertEqual(s.axes[1], -32767)
        let guide = try! XCTUnwrap(g.decode([0x07, 0x20, 0x02, 0x02, 0x01, 0x5b], last: s))
        XCTAssertTrue(guide.buttons.contains(.guide))
        XCTAssertTrue(g.decode(d, last: guide)!.buttons.contains(.guide), "held until released")
        XCTAssertNil(g.decode([0x03, 0x20, 0x01, 0x04], last: nil))
        XCTAssertEqual(GIPController.acknowledge([0x07, 0x30, 0x05, 0x02])?.prefix(4).map { $0 }, [0x01, 0x20, 0x05, 0x09])
        XCTAssertNil(GIPController.acknowledge([0x20, 0x00, 0x05, 0x0e]))
    }
}

final class GameCubeAdapterTests: XCTestCase {
    func testPorts() {
        var d = [UInt8](repeating: 0, count: 37); d[0] = 0x21
        // Port 2 (index 1): wired, A and Start, stick up, L clicked.
        let p = 1 + 9
        d[p] = 0x10; d[p + 1] = 0x01; d[p + 2] = 0x01 | 0x08
        d[p + 3] = 128; d[p + 4] = 216; d[p + 5] = 128; d[p + 6] = 128; d[p + 7] = 40; d[p + 8] = 40
        let ports = try! XCTUnwrap(GameCubeAdapter.decode(d))
        XCTAssertNil(ports[0]); XCTAssertNil(ports[2])
        let c = try! XCTUnwrap(ports[1])
        XCTAssertEqual(c.buttons, [.a, .start])
        XCTAssertEqual(c.axes[1], -32767, "up is −y")
        XCTAssertEqual(c.axes[0], 0)
        XCTAssertEqual(c.axes[4], 32767); XCTAssertEqual(c.axes[5], 0)
        XCTAssertNil(GameCubeAdapter.decode([0x22] + d.dropFirst()))
    }
}

final class EightBitDoControllerTests: XCTestCase {
    func testFullReport() {
        var d = [UInt8](repeating: 0, count: 34)
        d[0] = 0x04; d[1] = 2                       // d-pad right
        d[2] = 0x7F; d[3] = 0; d[4] = 0xFF; d[5] = 0x7F
        d[6] = 255; d[7] = 0                        // right trigger full
        d[8] = 0x01 | 0x04                          // A, back paddle
        d[9] = 0x08 | 0x80                          // Start, Share
        d[10] = 0x02
        d[23] = 0x00; d[24] = 0x10                  // gyro y = 4096
        let s = try! XCTUnwrap(EightBitDoController.decode(d))
        XCTAssertEqual(s.buttons, [.right, .a, .paddle1, .start, .misc, .paddle3])
        XCTAssertEqual(s.axes[0], 0); XCTAssertEqual(s.axes[1], -32767)
        XCTAssertEqual(s.axes[2], 32767)
        XCTAssertEqual(s.axes[5], 32767); XCTAssertEqual(s.axes[4], 0)
        let g = try! XCTUnwrap(s.gyro)
        XCTAssertLessThan(g[0], 0); XCTAssertEqual(g[1], 0); XCTAssertEqual(g[2], 0)
        XCTAssertNil(EightBitDoController.decode([0x09] + d.dropFirst()))
    }
    func testOldReport() {
        let d: [UInt8] = [0x02, 0x01, 0x0F, 0x7F, 0x7F, 0x7F, 0x7F, 0, 0]
        let s = EightBitDoController.decode(d)!
        XCTAssertEqual(s.buttons, [.b]); XCTAssertEqual(s.axes[4], 32767); XCTAssertNil(s.gyro)
    }
}

final class ReportPadTests: XCTestCase {
    func testFind() {
        XCTAssertEqual(ReportPadDriver.find(vendor: 0x2DC8, product: 0x6003), .eightBitDo(product: 0x6003))
        XCTAssertEqual(ReportPadDriver.find(vendor: 0x18D1, product: 0x9400), .stadia)
        XCTAssertNil(ReportPadDriver.find(vendor: 0x2DC8, product: 0x3019))
    }
    func testStadia() {
        var d = [UInt8](repeating: 0x80, count: 10); d[0] = 0x03; d[1] = 8; d[2] = 0x01 | 0x02; d[3] = 0x40; d[8] = 0; d[9] = 255
        var dec = ReportPadDecoder(.stadia)
        let s = dec.decode(d)!
        XCTAssertEqual(s.buttons, [.misc, .paddle1, .a]); XCTAssertEqual(s.axes[0], 0); XCTAssertEqual(s.axes[5], 32767)
        XCTAssertEqual(ReportPadDriver.stadia.rumble(low: 1, high: 0), [0x05, 0xFF, 0xFF, 0, 0])
    }
    func testLunaBluetoothHomeReport() {
        var dec = ReportPadDecoder(.lunaBluetooth)
        XCTAssertNil(dec.decode([0x02, 0x01]))
        var d = [UInt8](repeating: 0, count: 17); d[0] = 0x01; d[2] = 0x7F; d[4] = 0x7F; d[6] = 0x7F; d[8] = 0x7F
        d[13] = 1; d[16] = 0x02; d[9] = 0xFF; d[10] = 0x03
        let s = dec.decode(d)!
        XCTAssertEqual(s.buttons, [.guide, .up, .misc]); XCTAssertEqual(s.axes[4], 32767); XCTAssertEqual(s.axes[1], 0)
    }
}

final class SInputTests: XCTestCase {
    func testReportAndFeatures() {
        var dec = ReportPadDecoder(.sinput)
        var f = [UInt8](repeating: 0, count: 64); f[0] = 0x02; f[1] = 0x02; f[4] = 0x40   // left analog trigger only
        f[10] = 4; f[12] = 0xE8; f[13] = 0x03                                                // ±4 g, ±1000 °/s
        XCTAssertNil(dec.decode(f))
        var d = [UInt8](repeating: 0, count: 64); d[0] = 0x01
        d[3] = 0x02 | 0x10                 // South, d-pad up
        d[4] = 0x20                        // right digital trigger
        d[5] = 0x04                        // Guide
        d[7] = 0xFF; d[8] = 0x7F           // left x full right
        d[15] = 0xFF; d[16] = 0x7F         // left trigger full
        d[29] = 0x00; d[30] = 0x80         // gyro x −32768
        let s = try! XCTUnwrap(dec.decode(d))
        XCTAssertEqual(s.buttons, [.a, .up, .guide])
        XCTAssertEqual(s.axes[0], 32767); XCTAssertEqual(s.axes[4], 32767); XCTAssertEqual(s.axes[5], 32767)
        XCTAssertEqual(Double(s.gyro![0]), 1000 * Double.pi / 180, accuracy: 0.001)
        XCTAssertEqual(ReportPadDriver.sinput.startOutput?.count, 48)
        XCTAssertEqual(ReportPadDriver.find(vendor: 0x2E8A, product: 0x10DF), .sinput)
    }
}

final class ZuikiTests: XCTestCase {
    func testUSBAndBluetooth() {
        var dec = ReportPadDecoder(.zuiki(product: 0x001D))
        var d = [UInt8](repeating: 0, count: 20); d[0] = 0x04 | 0x80; d[1] = 0x20; d[2] = 0x0F
        d[3] = 0x7F; d[4] = 0x7F; d[5] = 0x7F; d[6] = 0x7F; d[8] = 0x00; d[9] = 0x40
        let s = try! XCTUnwrap(dec.decode(d))
        XCTAssertEqual(s.buttons, [.a, .misc]); XCTAssertEqual(s.axes[5], 32767); XCTAssertGreaterThan(s.gyro![0], 0)
        var bt = ReportPadDecoder(.zuiki(product: 0x0017))
        var b = [UInt8](repeating: 0, count: 30); b[1] = 0x00; b[2] = 0x80; b[3] = 0xFF; b[4] = 0xFF; b[13] = 3; b[15] = 0x10
        b[5] = 0; b[6] = 0x80; b[7] = 0; b[8] = 0x80
        let t = try! XCTUnwrap(bt.decode(b))
        XCTAssertEqual(t.buttons, [.right, .guide]); XCTAssertEqual(t.axes[0], 0); XCTAssertEqual(t.axes[1], 32767); XCTAssertNil(t.gyro)
        XCTAssertEqual(ReportPadDriver.zuiki(product: 0x0020).rumble(low: 1, high: 1), nil)
    }
}
