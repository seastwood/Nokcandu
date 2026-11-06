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

final class KeyRemapTests: XCTestCase {
    func testMappingsBecomeMacKeyboardRemapsAndBack() {
        let m = [KeyRemap.Mapping(from: 63, to: 59), KeyRemap.Mapping(from: 59, to: 63), KeyRemap.Mapping(from: 61, to: 62), KeyRemap.Mapping(from: 0, to: nil)]
        let text = KeyRemap.text(m)
        XCTAssertEqual(text, "0xff0100000003 0x7000000e0\n0x7000000e0 0xff0100000003\n0x7000000e6 0x7000000e4\n0x700000004 0x700000000\n")
        XCTAssertEqual(KeyRemap.parse(text), m)
        XCTAssertEqual(Set(KeyRemap.keys.map(\.code)).count, KeyRemap.keys.count, "no key listed twice")
        XCTAssertTrue(KeyRemap.keys.allSatisfy { KeyRemap.hidUsages[$0.code] != nil }, "every listed key can be remapped")
        XCTAssertEqual(KeyRemap.hidUsages[16], 0x7_0000_001C, "Y")
        XCTAssertEqual(KeyRemap.hidUsages[29], 0x7_0000_0027, "0")
    }

    func testKarabinerSimpleModificationsAreCopied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-kb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: root) }
        try #"""
        {"profiles":[{"name":"Default profile","simple_modifications":[{"from":{"key_code":"right_option"},"to":[{"key_code":"right_control"}]}]},
         {"name":"Voidlink","selected":true,"simple_modifications":[{"from":{"apple_vendor_top_case_key_code":"keyboard_fn"},"to":[{"key_code":"left_control"}]},
          {"from":{"key_code":"left_control"},"to":[{"apple_vendor_top_case_key_code":"keyboard_fn"}]},{"from":{"key_code":"caps_lock"},"to":[{"key_code":"vk_none"}]},
          {"from":{"consumer_key_code":"mute"},"to":[{"key_code":"f1"}]}],
          "complex_modifications":{"rules":[{"description":"x"}]}}]}
        """#.write(to: root, atomically: true, encoding: .utf8)
        let p = KeyRemap.karabinerProfiles(root)
        XCTAssertEqual(p.map(\.name), ["Default profile", "Voidlink"])
        XCTAssertEqual(p[0].mappings, [KeyRemap.Mapping(from: 61, to: 62)])
        XCTAssertEqual(p[1].mappings, [KeyRemap.Mapping(from: 63, to: 59), KeyRemap.Mapping(from: 59, to: 63), KeyRemap.Mapping(from: 57, to: nil)])
        XCTAssertEqual(p[1].skipped, 2)
        XCTAssertTrue(p[1].selected)
    }
}

final class ControllerKindTests: XCTestCase {
    func testWheelsPedalsAndFlightGearAreRecognized() {
        XCTAssertEqual(Controllers.kind(vendorID: 0x046D, productID: 0xC24F, usagePage: 1, usage: 4), .wheel, "Logitech G29")
        XCTAssertEqual(Controllers.kind(vendorID: 0x044F, productID: 0xB66E, usagePage: 1, usage: 4), .wheel, "Thrustmaster T300")
        XCTAssertEqual(Controllers.kind(vendorID: 0x044F, productID: 0xB679, usagePage: 1, usage: 4), .flight, "Thrustmaster rudder pedals")
        XCTAssertEqual(Controllers.kind(vendorID: 0x0EB7, productID: 0x0001, usagePage: 1, usage: 4), .wheel, "Fanatec")
        XCTAssertEqual(Controllers.kind(vendorID: 0x231D, productID: 0x0200, usagePage: 1, usage: 4), .flight, "VKB")
        XCTAssertEqual(Controllers.kind(vendorID: 0x1234, productID: 0x1, usagePage: 2, usage: 0x02), .wheel, "simulation: automobile")
        XCTAssertEqual(Controllers.kind(vendorID: 0x045E, productID: 0x0B13, usagePage: 1, usage: 5), .gamepad, "Xbox")
        let pedals = Controllers.Connected(name: "Pedals", vendorID: 0x1234, productID: 1, location: 3, bluetooth: false, isGamepad: false, usagePage: 2, usage: 0xBB)
        XCTAssertTrue(Controllers.describe(pedals, mode: .automatic, steam: false).hasPrefix("Not seen by Windows programs yet"))
        let wheel = Controllers.Connected(name: "G29", vendorID: 0x046D, productID: 0xC24F, location: 4, bluetooth: false, isGamepad: true, usagePage: 1, usage: 4)
        XCTAssertEqual(Controllers.describe(wheel, mode: .xbox, steam: false), "As itself: its own axes and buttons, for games with wheel support.")
    }
}
