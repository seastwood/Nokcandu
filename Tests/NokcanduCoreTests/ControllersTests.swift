import XCTest
@testable import NokcanduCore

final class ControllersTests: XCTestCase {
    func testModesDecideEachMakerAndWineDefaultsStay() {
        XCTAssertEqual(Controllers.plan(.native, steam: false)[.nintendo], true)
        XCTAssertEqual(Controllers.plan(.xbox, steam: true)[.playstation], false)
        XCTAssertEqual(Controllers.plan(.automatic, steam: true)[.valve], true)
        XCTAssertEqual(Controllers.plan(.automatic, steam: false)[.nintendo], .some(nil))
        XCTAssertTrue(Controllers.passesThrough(.playstation, mode: .automatic, steam: false), "Wine passes PlayStation controllers through by default")
        XCTAssertFalse(Controllers.passesThrough(.nintendo, mode: .automatic, steam: false))
        XCTAssertTrue(Controllers.passesThrough(.nintendo, mode: .automatic, steam: true))
        XCTAssertFalse(Controllers.passesThrough(nil, mode: .native, steam: true), "other makers are always converted")
    }

    func testRegistryKeysAreWrittenAndRemovedWithoutTouchingTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-ctl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let system = root.appendingPathComponent("system.reg")
        try "WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n[Software\\\\Other] 1700000000\n\"Keep\"=\"me\"\n".write(to: system, atomically: true, encoding: .utf8)

        try Controllers.apply(Controllers.plan(.native, steam: false), system: system)
        var text = try String(contentsOf: system, encoding: .utf8)
        XCTAssertTrue(text.contains("[System\\\\CurrentControlSet\\\\Services\\\\WineBus\\\\Devices\\\\057e]"))
        XCTAssertTrue(text.contains("[System\\\\CurrentControlSet\\\\Services\\\\WineBus\\\\Devices\\\\28de]"))
        XCTAssertEqual(text.components(separatedBy: "\"Hidraw\"=dword:00000001").count - 1, 3)

        try Controllers.apply(Controllers.plan(.xbox, steam: false), system: system)
        text = try String(contentsOf: system, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\"Hidraw\"=dword:00000000").count - 1, 3)
        XCTAssertFalse(text.contains("dword:00000001"))

        try Controllers.apply(Controllers.plan(.automatic, steam: false), system: system)
        text = try String(contentsOf: system, encoding: .utf8)
        XCTAssertFalse(text.contains("\"Hidraw\""), "Automatic outside Steam leaves Wine's defaults")
        XCTAssertTrue(text.contains("\"Keep\"=\"me\""))
    }

    func testDescriptionsSayWhatWindowsSees() {
        let pro = Controllers.Connected(name: "Pro Controller", vendorID: 0x057E, productID: 0x2009, location: 1, bluetooth: true, isGamepad: true)
        XCTAssertEqual(Controllers.describe(pro, mode: .automatic, steam: false), "As an Xbox controller (gyro isn't passed on this way).")
        XCTAssertTrue(Controllers.describe(pro, mode: .automatic, steam: true).hasPrefix("As itself, with gyro. Steam Input"))
        let steamController = Controllers.Connected(name: "Steam Controller", vendorID: 0x28DE, productID: 0x1142, location: 2, bluetooth: false, isGamepad: false)
        XCTAssertTrue(Controllers.describe(steamController, mode: .native, steam: true).hasPrefix("Not seen by Windows programs yet"))
        XCTAssertEqual(pro.ids, "057E:2009")
    }
}
