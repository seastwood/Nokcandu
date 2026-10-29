import XCTest
@testable import NokcanduCore

final class LauncherRemovalTests: XCTestCase {
    struct Fixture {
        var root: URL
        var host: InstalledGame
        var game: InstalledGame
        var files: URL
    }
    func fixture(kind: PCLauncher = .ea) throws -> Fixture {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("launcher-removal-" + UUID().uuidString).resolvingSymlinksInPath()
        let app = root.appendingPathComponent("Host.app")
        let contents = app.appendingPathComponent("Contents"), prefix = contents.appendingPathComponent("SharedSupport/prefix")
        try NokPaths.ensure(prefix.appendingPathComponent("drive_c")); try NokPaths.ensure(prefix.appendingPathComponent("dosdevices"))
        try NokPaths.ensure(contents.appendingPathComponent("MacOS")); try NokPaths.ensure(contents.appendingPathComponent("SharedSupport/nokcandu"))
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        let drive = root.appendingPathComponent("Other Drive"), files = drive.appendingPathComponent("Installed Game")
        try NokPaths.ensure(files.appendingPathComponent("bin"))
        try Data("game bytes".utf8).write(to: files.appendingPathComponent("bin/game.exe"))
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/e:").path, withDestinationPath: drive.path)
        let config = CustomGameConfig(id: UUID().uuidString, name: "Host", source: .installer, exe: kind.defaultExe, graphics: .classic3D)
        try config.encoded().write(to: CustomGameConfig.url(in: contents))
        let info: [String: Any] = ["CFBundleName": "Host", "CFBundleExecutable": "game-launcher", "CFBundleIdentifier": "test." + UUID().uuidString]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let wine = contents.appendingPathComponent("SharedSupport/wine/bin/wine")
        try NokPaths.ensure(wine.deletingLastPathComponent()); try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let reg: String
        if kind == .ea {
            reg = #"""
            WINE REGISTRY Version 2

            [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\game]
            "DisplayName"="Installed Game"
            "Publisher"="Electronic Arts, Inc."
            "InstallLocation"="E:\\Installed Game\\"
            "DisplayIcon"="E:\\Installed Game\\bin\\game.exe"

            """#
        } else {
            reg = #"""
            WINE REGISTRY Version 2

            [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\123]
            "InstallDir"="E:/Installed Game/"

            """#
        }
        try reg.write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        let host = try XCTUnwrap(GameLibrary.inspect(app))
        let link = HostedGameLink(hostApp: app.path, launcher: kind, id: kind == .ea ? "Installed Game" : "123", name: "Installed Game", exe: #"E:\Installed Game\bin\game.exe"#)
        let smallApp = root.appendingPathComponent("Game.app")
        let game = InstalledGame(appURL: smallApp, name: "Installed Game", hosted: link)
        try NokPaths.ensure(game.nokcanduState)
        return Fixture(root: root, host: host, game: game, files: files)
    }
    func testAppOnlyKeepsFilesAndAppAndFilesRemovesEntireRootThenApp() throws {
        for mode in [GameRemoval.Mode.appOnly, .appAndGameFiles] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let plan = GameRemoval.plan(for: f.game, library: [f.host, f.game])
            let folder = try XCTUnwrap(plan.gameFolder, plan.folderUnavailable ?? "missing folder")
            XCTAssertEqual(folder.url.path, f.files.path)
            XCTAssertFalse(folder.url.path.hasSuffix("/bin"))
            let trash = f.root.appendingPathComponent("Trash"); try NokPaths.ensure(trash)
            var moved: [URL] = []
            let failures = try GameRemoval.remove(f.game, library: [f.host, f.game], mode: mode, expectedFolder: folder, trash: { source in
                XCTAssertTrue(source.path.hasPrefix(f.root.path + "/"))
                moved.append(source)
                try FileManager.default.moveItem(at: source, to: trash.appendingPathComponent(source.lastPathComponent))
            })
            XCTAssertEqual(failures, [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.game.appURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.host.appURL.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: f.files.path), mode == .appOnly)
            if mode == .appAndGameFiles { XCTAssertEqual(moved.first?.path, f.files.path); XCTAssertEqual(PCLaunchers.installedGames(.ea, host: f.host), []) }
            else { XCTAssertEqual(PCLaunchers.installedGames(.ea, host: f.host).count, 1) }
        }
    }
    func testTrashFailureKeepsAppAndRecordsAndNeverPermanentlyDeletesFiles() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = GameRemoval.plan(for: f.game, library: [f.host, f.game])
        var attempts: [URL] = []
        let failures = try GameRemoval.remove(f.game, library: [f.host, f.game], mode: .appAndGameFiles, expectedFolder: plan.gameFolder, trash: { url in
            attempts.append(url); throw NokError("Drive cannot use Trash")
        })
        XCTAssertEqual(attempts.map(\.path), [f.files.path])
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.game.appURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.files.appendingPathComponent("bin/game.exe").path))
    }
    func testMissingFilesDisappearForEAAndUbisoftButOfflineVolumeIsRetained() throws {
        for kind in [PCLauncher.ea, .ubisoft] {
            let f = try fixture(kind: kind); defer { try? FileManager.default.removeItem(at: f.root) }
            XCTAssertEqual(PCLaunchers.installedGames(kind, host: f.host).count, 1)
            try FileManager.default.removeItem(at: f.files)
            XCTAssertEqual(PCLaunchers.installedGames(kind, host: f.host), [])
            XCTAssertNil(GameRemoval.plan(for: f.game, library: [f.host, f.game]).gameFolder)
            let link = f.host.prefix.appendingPathComponent("dosdevices/e:")
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Volumes/Nokcandu-Offline-" + UUID().uuidString)
            XCTAssertEqual(PCLaunchers.installedGames(kind, host: f.host).count, 1)
            XCTAssertEqual(LauncherInstallation.presence(at: PCLaunchers.installFolder(f.game.hosted!, host: f.host)), .offline)
        }
    }
    func testSharedRootsOtherShortcutsAndChangedFolderAreRejectedBeforeRemoval() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let plan = GameRemoval.plan(for: f.game, library: [f.host, f.game])
        let copy = InstalledGame(appURL: f.root.appendingPathComponent("Second.app"), name: "Second", hosted: f.game.hosted)
        try NokPaths.ensure(copy.nokcanduState)
        XCTAssertNil(GameRemoval.plan(for: f.game, library: [f.host, f.game, copy]).gameFolder)
        XCTAssertNotNil(GameRemoval.blocker(f.host, library: [f.host, f.game]))
        let location = try XCTUnwrap(LauncherInstallation.location(for: f.game))
        var unsafe = location; unsafe.folder = f.files.deletingLastPathComponent()
        XCTAssertNotNil(LauncherInstallation.removalBlocker(unsafe, game: f.game, library: [f.host, f.game]))
        unsafe = location; unsafe.otherFolders = [f.files.appendingPathComponent("Other Product")]
        XCTAssertNotNil(LauncherInstallation.removalBlocker(unsafe, game: f.game, library: [f.host, f.game]))
        try FileManager.default.moveItem(at: f.files, to: f.root.appendingPathComponent("Previous Game"))
        try NokPaths.ensure(f.files)
        var touched = false
        XCTAssertThrowsError(try GameRemoval.remove(f.game, library: [f.host, f.game], mode: .appAndGameFiles, expectedFolder: plan.gameFolder, trash: { _ in touched = true }))
        XCTAssertFalse(touched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.game.appURL.path))
    }
    func testBattleNetAndSteamIgnoreStaleRegistrationAndKeepPartialDownloads() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let reg = #"""
        WINE REGISTRY Version 2

        [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\BlizzardGame]
        "DisplayName"="Blizzard Game"
        "InstallLocation"="E:\\Installed Game\\"
        "UninstallString"="Blizzard Uninstaller --uid=osi"

        """#
        try reg.write(to: f.host.prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BattleNet.installedGames(host: f.host).count, 1)
        let link = BattleNetLink(hostApp: f.host.appURL.path, uid: "osi", code: "OSI", name: "Blizzard Game")
        let game = InstalledGame(appURL: f.game.appURL, name: "Blizzard Game", battleNet: link)
        XCTAssertNotNil(GameRemoval.plan(for: game, library: [f.host, game]).gameFolder)
        try FileManager.default.removeItem(at: f.files)
        XCTAssertEqual(BattleNet.installedGames(host: f.host), [])
        let lib = f.root.appendingPathComponent("Steam Library"), apps = lib.appendingPathComponent("steamapps")
        try NokPaths.ensure(apps.appendingPathComponent("common/Steam Game"))
        func manifest(_ flags: Int) throws {
            try "\"AppState\" { \"appid\" \"123\" \"name\" \"Steam Game\" \"installdir\" \"Steam Game\" \"StateFlags\" \"\(flags)\" }".write(to: apps.appendingPathComponent("appmanifest_123.acf"), atomically: true, encoding: .utf8)
        }
        try manifest(4)
        XCTAssertEqual(SharedSteam.installedGames(in: [lib]).first?.installed, true)
        try FileManager.default.removeItem(at: apps.appendingPathComponent("common/Steam Game"))
        XCTAssertTrue(SharedSteam.installedGames(in: [lib]).isEmpty)
        try manifest(2)
        XCTAssertEqual(SharedSteam.installedGames(in: [lib]).first?.installed, false)
        var malformed = SharedSteam.LibraryGame(appID: 1, name: "Bad", installed: true, installDir: "../", sizeOnDisk: nil, playtimeMinutes: nil, iconURL: nil, owned: true)
        malformed.library = lib
        XCTAssertNil(malformed.folder)
    }

    func testOnlyMountedDrivesCountAsConnected() throws {
        XCTAssertTrue(LauncherInstallation.isMountPoint(URL(fileURLWithPath: "/")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-drive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(LauncherInstallation.isMountPoint(dir))
        // A game on a drive that isn't mounted is "offline", never "missing" (uninstalled).
        XCTAssertEqual(LauncherInstallation.presence(at: URL(fileURLWithPath: "/Volumes/NokcanduNoSuchDrive-\(UUID().uuidString)/Games/X")), .offline)
    }
}
