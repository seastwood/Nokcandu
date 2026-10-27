import XCTest
@testable import NokcanduCore

final class GameFoldersTests: XCTestCase {
    func makeApp(in folder: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let app = folder.appendingPathComponent("\(name).app")
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/SharedSupport/MountedDisc"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/d:").path,
                                  withDestinationPath: app.appendingPathComponent("Contents/SharedSupport/MountedDisc").path)
        let win = "Z:" + app.path.replacingOccurrences(of: "/", with: "\\\\")
        try "\"Marlett (TrueType)\"=\"\(win)\\\\Contents\\\\SharedSupport\\\\wine\\\\fonts\\\\marlett.ttf\"\n"
            .write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try "<plist/>".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return app
    }

    func testMoveRewritesDriveLinksAndRegistry() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nok-folders-\(UUID().uuidString)").resolvingSymlinksInPath()
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B Games")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = try makeApp(in: a, name: "Old Game")
        let g = InstalledGame(appURL: app, name: "Old Game")
        let moved = try GameMover.move(g, to: b)
        XCTAssertEqual(moved.path, b.appendingPathComponent("Old Game.app").path)
        XCTAssertFalse(fm.fileExists(atPath: app.path))
        let dos = moved.appendingPathComponent("Contents/SharedSupport/prefix/dosdevices")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dos.appendingPathComponent("c:").path), "../drive_c")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dos.appendingPathComponent("d:").path),
                       moved.appendingPathComponent("Contents/SharedSupport/MountedDisc").path)
        let reg = try String(contentsOf: moved.appendingPathComponent("Contents/SharedSupport/prefix/system.reg"), encoding: .utf8)
        XCTAssertTrue(reg.contains("B Games\\\\Old Game.app\\\\Contents"), reg)
        XCTAssertFalse(reg.contains("\\\\A\\\\Old Game.app"), reg)
        // Refuses a name clash.
        _ = try makeApp(in: a, name: "Old Game")
        XCTAssertThrowsError(try GameMover.move(InstalledGame(appURL: a.appendingPathComponent("Old Game.app"), name: "Old Game"), to: b))
    }

    func testProblemForMissingFolder() {
        XCTAssertNotNil(GameFolders.problem(with: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
        XCTAssertNil(GameFolders.problem(with: FileManager.default.temporaryDirectory))
    }

    func testGameFilesFolderAndRelocate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nok-files-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix"), drive = root.appendingPathComponent("Elements/Nokcandu Games")
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        XCTAssertEqual(GameMover.gameFilesFolder(exe: "C:\\Games\\Battlefield 1942\\BF1942.exe", prefix: prefix)?.lastPathComponent, "Battlefield 1942")
        XCTAssertEqual(GameMover.gameFilesFolder(exe: "C:\\Program Files\\Bethesda\\Morrowind\\Morrowind.exe", prefix: prefix)?.lastPathComponent, "Bethesda")
        XCTAssertEqual(GameMover.gameFilesFolder(exe: "C:\\Westwood\\RA2\\ra2.exe", prefix: prefix)?.lastPathComponent, "Westwood")
        XCTAssertNil(GameMover.gameFilesFolder(exe: "D:\\setup.exe", prefix: prefix))
        XCTAssertNil(GameMover.gameFilesFolder(exe: "C:\\game.exe", prefix: prefix))

        let game = prefix.appendingPathComponent("drive_c/Games/BF")
        try fm.createDirectory(at: game.appendingPathComponent("Mods"), withIntermediateDirectories: true)
        try "x".write(to: game.appendingPathComponent("Mods/a.txt"), atomically: true, encoding: .utf8)
        let dest = try GameMover.relocate(game, to: drive)
        XCTAssertEqual(dest.path, drive.appendingPathComponent("BF").path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: game.path), dest.path)
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("Mods/a.txt"), encoding: .utf8), "x")   // through the link
        // And back.
        try GameMover.relocate(game, to: nil)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: game.path))
        XCTAssertTrue(fm.fileExists(atPath: game.appendingPathComponent("Mods/a.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
    }
}
