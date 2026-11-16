import XCTest
@testable import NokcanduCore

final class GamepadMappingTests: XCTestCase {
    func testTheDatabaseLoadsAndIdentifiesControllers() {
        XCTAssertGreaterThan(GamepadMapping.database.count, 150)
        // 8BitDo 64: vendor 0x2DC8, product 0x3019 (the GUID's bytes are little-endian: c82d, 1930).
        let m = try! XCTUnwrap(GamepadMapping.find(vendor: 0x2dc8, product: 0x3019))
        XCTAssertEqual(m.name, "8BitDo 64")
        XCTAssertTrue(m.entries.contains { $0.target == .input(.guide) && $0.source == .button(12) })
        XCTAssertNil(GamepadMapping.find(vendor: 0x1234, product: 0x5678))
    }

    func testButtonsHatsAxesAndTriggers() {
        let m = try! XCTUnwrap(GamepadMapping(line: "03000000c82d00001930000000000000,Test,a:b0,b:b1,dpup:h0.1,dpleft:h0.8,leftx:a0,lefty:a1,lefttrigger:a2,righttrigger:b7,rightx:a3~,+righty:a4,-righty:a5,platform:Mac OS X,"))
        var buttons = [Bool](repeating: false, count: 16); buttons[1] = true; buttons[7] = true
        let s = m.state(buttons: buttons, axes: [1000, -2000, -32768, 500, 32767, 0], hat: 1 | 8)
        XCTAssertEqual(s.buttons, [.b, .up, .left])
        XCTAssertEqual(s.axes[0], 1000); XCTAssertEqual(s.axes[1], -2000)
        XCTAssertEqual(s.axes[4], 0, "a resting full-axis trigger reads 0")
        XCTAssertEqual(s.axes[5], 32767, "a button trigger, pressed")
        XCTAssertEqual(s.axes[2], -500, "~ inverts")
        XCTAssertEqual(s.axes[3], 32767, "two halves add up")
        let full = m.state(buttons: [], axes: [0, 0, 32767, 0, 0, 32767], hat: 0)
        XCTAssertEqual(full.axes[4], 32767)
        XCTAssertEqual(full.axes[3], -32767)
    }

    func testBadLinesAreSkipped() {
        XCTAssertNil(GamepadMapping(line: "# a comment"))
        XCTAssertNil(GamepadMapping(line: "nothex,Name,a:b0"))
        XCTAssertNil(GamepadMapping(line: "03000000000000000000000000000000,Name,a:b0"), "no vendor")
    }

    func testGuessedLayout() {
        let m = try! XCTUnwrap(GamepadMapping.guessed(vendor: 0x1234, product: 0xabcd, name: "Pad", buttons: 10, axes: 2, hat: true))
        XCTAssertEqual(m.name, "Pad (guessed layout)")
        XCTAssertEqual(m.vendorID, 0x1234); XCTAssertEqual(m.productID, 0xabcd)
        var b = [Bool](repeating: false, count: 10); b[9] = true
        XCTAssertEqual(m.state(buttons: b, axes: [0, 0], hat: 4).buttons, [.start, .down])
        XCTAssertNil(GamepadMapping.guessed(vendor: 1, product: 1, name: "x", buttons: 2, axes: 2, hat: false))
        // A comma in the device's name doesn't break the mapping.
        let c = try! XCTUnwrap(GamepadMapping.guessed(vendor: 0x1234, product: 0xabcd, name: "ACME, Inc. Pad", buttons: 10, axes: 2, hat: true))
        XCTAssertEqual(c.name, "ACME  Inc. Pad (guessed layout)")
        XCTAssertEqual(c.state(buttons: b, axes: [0, 0], hat: 4).buttons, [.start, .down])
    }
}
