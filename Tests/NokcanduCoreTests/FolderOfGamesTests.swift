import XCTest
@testable import NokcanduCore

final class FolderOfGamesTests: XCTestCase {
    func file(_ u: URL, _ size: Int = 10) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: u)
    }

    func testFindsEachGameAndItsProgram() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try file(root.appendingPathComponent("Battlefield_1942/BF1942.exe"), 3_000_000)
        try file(root.appendingPathComponent("Battlefield_1942/UnInstall.exe"))
        try file(root.appendingPathComponent("Battlefield_1942/BF1942_Dedicated_Server.exe"), 9_000_000)
        try file(root.appendingPathComponent("Deus Ex/System/DeusEx.exe"), 1_000_000)
        try file(root.appendingPathComponent("Deus Ex/System/UCC.exe"))
        try file(root.appendingPathComponent("Installers/setup.exe"))
        try file(root.appendingPathComponent("Music/song.mp3"))
        let found = FolderOfGames.scan(root)
        XCTAssertEqual(found.map(\.name), ["Battlefield 1942", "Deus Ex"])
        XCTAssertEqual(found[0].program, "BF1942.exe")
        XCTAssertEqual(found[1].program, "System/DeusEx.exe")
    }

    func testAFolderThatIsItselfOneGame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fog-\(UUID().uuidString)/Half-Life")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try file(root.appendingPathComponent("hl.exe"), 2_000_000)
        try file(root.appendingPathComponent("valve/dlls/hl.dll"))
        XCTAssertEqual(FolderOfGames.scan(root).map(\.name), ["Half-Life"])
    }

    func testLooksInsideFoldersOfFoldersAndUnticksDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try file(root.appendingPathComponent("Old Laptop/Games/Battlefield 1942/BF1942.exe"), 3_000_000)
        try file(root.appendingPathComponent("Old Laptop/Games/Battlefield 1942/BF1942_w32ded.exe"), 9_000_000)
        try file(root.appendingPathComponent("Old Laptop/Games/Overwatch/_retail_/Overwatch.exe"), 5_000_000)
        try file(root.appendingPathComponent("Downloads/rufus-4.4.exe"), 1_000_000)
        try file(root.appendingPathComponent("Adobe/Set-up.exe"), 1_000_000)
        try file(root.appendingPathComponent("$RECYCLE.BIN/game.exe"), 1_000_000)
        let found = FolderOfGames.scan(root)
        XCTAssertEqual(found.map(\.name), ["Downloads", "Battlefield 1942", "Overwatch"])
        XCTAssertEqual(found.map(\.likely), [false, true, true])
        XCTAssertEqual(found[1].program, "BF1942.exe")
        XCTAssertEqual(found[2].program, "_retail_/Overwatch.exe")
    }
}
