import XCTest
@testable import NokcanduCore

final class AntiCheatTests: XCTestCase {
    func testVerdicts() {
        XCTAssertNil(AntiCheat.warning(.init(name: "CS2", status: "Supported", anticheats: ["VAC"])))
        let f = AntiCheat.warning(.init(name: "Fortnite", status: "Denied", anticheats: ["Easy Anti-Cheat"]))
        XCTAssertEqual(f?.verdict, .blocked); XCTAssertTrue(f!.detail.contains("kernel-level"))
        let r = AntiCheat.warning(.init(name: "Rocket League", status: "Supported", anticheats: ["Easy Anti-Cheat", "VAC"]))
        XCTAssertEqual(r?.verdict, .risky); XCTAssertEqual(r?.anticheats, ["Easy Anti-Cheat"])
        XCTAssertEqual(AntiCheat.normalized("Rocket League®"), AntiCheat.normalized("rocket league"))
        let pb = AntiCheat.warning(.init(name: "Battlefield 1942", status: "Broken", anticheats: ["PunkBuster"]))
        XCTAssertEqual(pb?.verdict, .risky); XCTAssertTrue(pb!.detail.contains("worth trying"))
        XCTAssertNil(AntiCheat.warning(.init(name: "Diablo II: Resurrected", status: "Supported", anticheats: ["Warden"])))
    }

    func testFindMacApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nok-mac-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for p in ["Game/Uninstall.app/Contents", "Game/Contents/Helpers/Crash Helper.app/Contents", "Game/My Game.app/Contents/Frameworks/X.app/Contents"] {
            try fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        XCTAssertEqual(NativeGames.findApp(in: root)?.lastPathComponent, "My Game.app")
    }
}
