import XCTest
@testable import NokcanduCore
final class GameStorageTests: XCTestCase {
    func testSplitGameStorageCountsEachLocationOnce() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("storage-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Game.app"), prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        let folder = prefix.appendingPathComponent("drive_c/Games/Test")
        try NokPaths.ensure(folder); try NokPaths.ensure(root.appendingPathComponent("External"))
        try Data(repeating: 42, count: 16384).write(to: folder.appendingPathComponent("Test.exe"))
        let c = CustomGameConfig(id: "storage", name: "Storage test", source: .folder, exe: #"C:\Games\Test\Test.exe"#, graphics: .classic3D)
        let g = InstalledGame(appURL: app, name: c.name, custom: c)
        let before = Storage.usage(for: g)
        XCTAssertEqual(before.parts.count, 1)
        try GameMover.moveFiles(g, to: root.appendingPathComponent("External"))
        let split = Storage.usage(for: g)
        XCTAssertEqual(split.parts.count, 2)
        XCTAssertEqual(split.parts[1].title, "Game files")
        XCTAssertEqual(split.bytes, Storage.size(app) + Storage.size(root.appendingPathComponent("External/Test")))
        let inventory = try XCTUnwrap(Storage.games([g]).first)
        XCTAssertEqual(inventory.bytes, split.bytes)
        XCTAssertTrue(inventory.detail.contains("Game files:"))
        XCTAssertTrue(split.complete)
        XCTAssertFalse(split.parts[0].drive.isEmpty)
        XCTAssertEqual(Storage.driveName(URL(fileURLWithPath: "/Volumes/Offline Games/Game")), "Offline Games")
    }
}

final class GameRemovalStorageTests: XCTestCase {
    func testOnlyDedicatedOwnedExternalFolderIsOfferedForRemoval() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("removal-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = root.appendingPathComponent("Library"), external = library.appendingPathComponent("Test")
        try NokPaths.ensure(external)
        func game(_ name: String) throws -> InstalledGame {
            let app = root.appendingPathComponent(name + ".app")
            let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
            let games = prefix.appendingPathComponent("drive_c/Games")
            try NokPaths.ensure(games)
            try fm.createSymbolicLink(atPath: games.appendingPathComponent("Test").path, withDestinationPath: external.path)
            let config = CustomGameConfig(id: name, name: name, source: .folder, exe: #"C:\Games\Test\Game.exe"#, graphics: .classic3D)
            return InstalledGame(appURL: app, name: name, custom: config)
        }
        let first = try game("First")
        XCTAssertEqual(GameRemoval.removableExternalFiles(first, library: [first], folders: [library])?.path, external.path)
        XCTAssertNil(GameRemoval.removableExternalFiles(first, library: [first], folders: [root]))
        let second = try game("Second")
        XCTAssertNil(GameRemoval.removableExternalFiles(first, library: [first, second], folders: [library]))
        try sourceMarker(first.support)
        XCTAssertNil(GameRemoval.removableExternalFiles(first, library: [first], folders: [library]))
        XCTAssertTrue(fm.fileExists(atPath: external.path))
    }
    private func sourceMarker(_ support: URL) throws {
        try "borrowed".write(to: support.appendingPathComponent("referenced-game-folder.txt"), atomically: true, encoding: .utf8)
    }
}

final class CopiedMetadataTests: XCTestCase {
    func testRemovesOnlyVerifiedAppleDoubleFromNewCopy() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("metadata-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try NokPaths.ensure(root)
        let sidecar = root.appendingPathComponent("._L0101.ldf")
        try Data([0,5,0x16,7,0,2,0,0]).write(to: sidecar)
        let gameFile = root.appendingPathComponent("L0101.ldf"), unusual = root.appendingPathComponent("._actual-game-data")
        try Data([42]).write(to: gameFile); try Data([43]).write(to: unusual)
        try GameMover.removeCopiedMacMetadata(in: root)
        XCTAssertFalse(fm.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try Data(contentsOf: gameFile), Data([42]))
        XCTAssertEqual(try Data(contentsOf: unusual), Data([43]))
    }
}

final class StorageInventoryLocationTests: XCTestCase {
    func testLauncherGameOnMappedDriveIncludesEntireInstallAndReportsMissingFiles() throws {
        for kind in [PCLauncher.ea, .ubisoft] {
            let f = try LauncherRemovalTests().fixture(kind: kind)
            defer { try? FileManager.default.removeItem(at: f.root) }
            try Data(repeating: 17, count: 2_000_000).write(to: f.files.appendingPathComponent("game-data.bin"))
            let item = try XCTUnwrap(Storage.games([f.game]).first)
            XCTAssertEqual(item.bytes, Storage.allocatedSize(f.game.appURL) + Storage.allocatedSize(f.files))
            XCTAssertGreaterThan(item.bytes, 1_900_000)
            XCTAssertTrue(item.detail.contains("Game files:")); XCTAssertTrue(item.detail.contains(" on "))
            XCTAssertFalse(item.incomplete)
            try FileManager.default.removeItem(at: f.files)
            let missing = try XCTUnwrap(Storage.games([f.game]).first)
            XCTAssertTrue(missing.incomplete); XCTAssertTrue(missing.detail.contains("unavailable"))
        }
    }
    func testInternalLauncherFilesBelongToGameRowRatherThanSharedHostTwice() throws {
        let f = try LauncherRemovalTests().fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let internalRoot = f.host.prefix.appendingPathComponent("drive_c/Games")
        try NokPaths.ensure(internalRoot)
        let internalGame = internalRoot.appendingPathComponent("Installed Game")
        try FileManager.default.moveItem(at: f.files, to: internalGame)
        let drive = f.host.prefix.appendingPathComponent("dosdevices/e:")
        try FileManager.default.removeItem(at: drive)
        try FileManager.default.createSymbolicLink(at: drive, withDestinationURL: internalRoot)
        try Data(repeating: 23, count: 1_000_000).write(to: internalGame.appendingPathComponent("game-data.bin"))
        let hostBytes = Storage.allocatedSize(f.host.appURL, excluding: [internalGame])
        let items = Storage.games([f.host, f.game])
        XCTAssertEqual(items.first(where: { $0.url == f.host.appURL })?.bytes, hostBytes)
        XCTAssertEqual(items.first(where: { $0.url == f.game.appURL })?.bytes, Storage.allocatedSize(f.game.appURL) + Storage.allocatedSize(internalGame))
        XCTAssertEqual(Storage.usage(for: f.host).bytes, hostBytes + Storage.allocatedSize(internalGame))
    }
    func testNativeGameUsesKnownInstallFolderNotOnlySmallLauncherApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-storage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try NokPaths.ensure(root)
        let app = root.appendingPathComponent("Native.app"), files = root.appendingPathComponent("Game Files")
        try NokPaths.ensure(app); try NokPaths.ensure(files)
        try Data(repeating: 31, count: 1_000_000).write(to: files.appendingPathComponent("content.bin"))
        var game = InstalledGame(appURL: app, name: "Native")
        game.native = NativeGame(id: "native", name: "Native", appPath: app.path, installFolder: files.path)
        XCTAssertEqual(Storage.games([game]).first?.bytes, Storage.allocatedSize(files))
    }
}

extension StorageInventoryLocationTests {
    func testBattleNetMappedDriveUsesRegisteredGameRoot() throws {
        let f = try LauncherRemovalTests().fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let reg = #"""
        WINE REGISTRY Version 2

        [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\BlizzardGame]
        "DisplayName"="Blizzard Game"
        "InstallLocation"="E:\\Installed Game\\"
        "UninstallString"="Blizzard Uninstaller --uid=osi"

        """#
        try reg.write(to: f.host.prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        try Data(repeating: 19, count: 1_000_000).write(to: f.files.appendingPathComponent("content.bin"))
        let game = InstalledGame(appURL: f.game.appURL, name: "Blizzard Game", battleNet: .init(hostApp: f.host.appURL.path, uid: "osi", code: "OSI", name: "Blizzard Game"))
        XCTAssertEqual(Storage.games([game]).first?.bytes, Storage.allocatedSize(game.appURL) + Storage.allocatedSize(f.files))
    }
    func testSteamMappedLibraryCountsFilesAndLostMetadataIsNotReportedAsComplete() throws {
        let f = try LauncherRemovalTests().fixture()
        let previous = ProcessInfo.processInfo.environment["NOKCANDU_GAME_APPS"]
        defer {
            if let previous { setenv("NOKCANDU_GAME_APPS", previous, 1) } else { unsetenv("NOKCANDU_GAME_APPS") }
            try? FileManager.default.removeItem(at: f.root)
        }
        // Every write/move below uses an explicit child of this temporary fixture.
        // Global Steam paths are only read after checking the environment override.
        let apps = f.root.appendingPathComponent("Apps")
        let fixtureHost = apps.appendingPathComponent("Steam.app")
        try NokPaths.ensure(apps)
        try FileManager.default.moveItem(at: f.host.appURL, to: fixtureHost)
        let steamApps = fixtureHost.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Steam/steamapps")
        try NokPaths.ensure(steamApps)
        try #"""
        "libraryfolders" { "1" { "path" "E:\\" "apps" { "123" "1" } } }
        """#.write(to: steamApps.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)
        let externalApps = f.files.deletingLastPathComponent().appendingPathComponent("steamapps")
        let folder = externalApps.appendingPathComponent("common/Installed Game")
        try NokPaths.ensure(folder.deletingLastPathComponent())
        try FileManager.default.moveItem(at: f.files, to: folder)
        try Data(repeating: 29, count: 1_000_000).write(to: folder.appendingPathComponent("content.bin"))
        let manifest = externalApps.appendingPathComponent("appmanifest_123.acf")
        try #"""
        "AppState" { "appid" "123" "name" "Steam Game" "installdir" "Installed Game" "StateFlags" "4" }
        """#.write(to: manifest, atomically: true, encoding: .utf8)
        setenv("NOKCANDU_GAME_APPS", apps.path, 1)
        guard SharedSteam.appURL.standardizedFileURL == fixtureHost.standardizedFileURL else {
            throw NokError("Fixture override did not resolve to the isolated test host; test stopped.")
        }
        var config = CustomGameConfig(id: "steam-storage", name: "Steam Game", source: .steamLibrary, exe: "game.exe", graphics: .classic3D)
        config.steamAppID = 123
        let game = InstalledGame(appURL: f.game.appURL, name: "Steam Game", custom: config)
        let item = try XCTUnwrap(Storage.games([game]).first)
        XCTAssertEqual(item.bytes, Storage.allocatedSize(game.appURL) + Storage.allocatedSize(folder))
        XCTAssertFalse(item.incomplete)
        try FileManager.default.removeItem(at: manifest)
        XCTAssertTrue(try XCTUnwrap(Storage.games([game]).first).incomplete)
    }
}

extension StorageInventoryLocationTests {
    func testPrivateGameLinksCountEvenWhenSelectedProgramIsSeparateHub() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-storage-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Game.app"), files = root.appendingPathComponent("External Game")
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        try NokPaths.ensure(files); try NokPaths.ensure(prefix.appendingPathComponent("drive_c/Games"))
        try Data(repeating: 47, count: 1_000_000).write(to: files.appendingPathComponent("content.bin"))
        for name in ["Original Game", "Duplicate Alias"] {
            try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("drive_c/Games/" + name), withDestinationURL: files)
        }
        // User-folder mappings must not add unrelated personal data to game size.
        let personal = root.appendingPathComponent("Personal")
        try NokPaths.ensure(personal); try NokPaths.ensure(prefix.appendingPathComponent("drive_c/users"))
        try Data(repeating: 51, count: 2_000_000).write(to: personal.appendingPathComponent("unrelated.bin"))
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("drive_c/users/owner"), withDestinationURL: personal)
        let config = CustomGameConfig(id: "hub", name: "Game", source: .folder, exe: #"C:\Program Files (x86)\Game Hub\hub.exe"#, graphics: .classic3D)
        let game = InstalledGame(appURL: app, name: "Game", custom: config)
        let usage = Storage.usage(for: game), row = try XCTUnwrap(Storage.games([game]).first)
        XCTAssertEqual(usage.parts.count, 2)
        XCTAssertEqual(row.bytes, Storage.allocatedSize(app) + Storage.allocatedSize(files))
        XCTAssertTrue(row.detail.contains("Game files:"))
        try FileManager.default.removeItem(at: files)
        XCTAssertTrue(try XCTUnwrap(Storage.games([game]).first).incomplete)
    }
}
