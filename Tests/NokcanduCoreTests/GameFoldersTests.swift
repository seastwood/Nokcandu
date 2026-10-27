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

final class PortableGameFixTests: XCTestCase {
    func testMovingAppKeepsPrivateUndoAndNativeRendererPaths() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("portable-fix-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("A/BF1942.app"), dest = root.appendingPathComponent("B")
        try NokPaths.ensure(dest)
        let contents = app.appendingPathComponent("Contents"), prefix = contents.appendingPathComponent("SharedSupport/prefix")
        try NokPaths.ensure(prefix.appendingPathComponent("dosdevices")); try NokPaths.ensure(contents.appendingPathComponent("MacOS"))
        try NokPaths.ensure(contents.appendingPathComponent("SharedSupport/nokcandu"))
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        let gameRoot = prefix.appendingPathComponent("drive_c/Games/BF1942")
        try NokPaths.ensure(gameRoot.appendingPathComponent("Mods/bf1942/Settings/Profiles/Default"))
        try Data("test EXE".utf8).write(to: gameRoot.appendingPathComponent("BF1942.exe"))
        let video = gameRoot.appendingPathComponent("Mods/bf1942/Settings/Profiles/Default/Video.con")
        let original = Data("game.setGameDisplayMode 800 600 32 60\n".utf8)
        try original.write(to: video)
        try Data("run Profiles/Default/Video.con\n".utf8).write(to: gameRoot.appendingPathComponent("Mods/bf1942/Settings/Video.con"))
        var c = CustomGameConfig(id: "portable", name: "BF1942", source: .folder, exe: #"C:\Games\BF1942\BF1942.exe"#, graphics: .classic3D)
        c.environment = ["WINEDLLPATH_D9VK": contents.appendingPathComponent("SharedSupport/renderer/dxvk/wine").path]
        let script = CustomGames.launcherScript(for: c)
        c.launcherSHA = Hashing.sha256(data: Data(script.utf8))
        try Data(script.utf8).write(to: contents.appendingPathComponent("MacOS/game-launcher"))
        try c.encoded().write(to: CustomGameConfig.url(in: contents))
        let info = ["CFBundleName": "BF1942", "CFBundleExecutable": "game-launcher", "CFBundleIdentifier": "local.portable." + UUID().uuidString]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let g = try XCTUnwrap(GameLibrary.inspect(app))
        try await BF1942DisplayFix.apply(to: g, size: [1280, 800], recommended: false) { _ in }
        let movedURL = try GameMover.move(try XCTUnwrap(GameLibrary.inspect(app)), to: dest)
        let moved = try XCTUnwrap(GameLibrary.inspect(movedURL))
        XCTAssertTrue(moved.custom?.environment?["WINEDLLPATH_D9VK"]?.hasPrefix(moved.contents.path) == true)
        XCTAssertEqual(moved.custom?.launcherSHA, try Hashing.sha256(file: moved.contents.appendingPathComponent("MacOS/game-launcher")))
        try BF1942DisplayFix.undo(for: moved) { _ in }
        XCTAssertEqual(try Data(contentsOf: moved.prefix.appendingPathComponent("drive_c/Games/BF1942/Mods/bf1942/Settings/Profiles/Default/Video.con")), original)
        // File-only relocation must retain BF1942 controls and its Undo path too.
        try await BF1942DisplayFix.apply(to: moved, size: [1920, 1080], recommended: false) { _ in }
        let external = root.appendingPathComponent("GameFiles")
        try NokPaths.ensure(external)
        try GameMover.moveFiles(CompatibilityFixes.fresh(moved), to: external)
        XCTAssertTrue(BF1942DisplayFix.supports(CompatibilityFixes.fresh(moved)))
        try BF1942DisplayFix.undo(for: CompatibilityFixes.fresh(moved)) { _ in }
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("BF1942/Mods/bf1942/Settings/Profiles/Default/Video.con")), original)
        try GameMover.moveFiles(CompatibilityFixes.fresh(moved), to: nil)
        XCTAssertFalse(fm.fileExists(atPath: external.appendingPathComponent("BF1942").path))
    }
}
