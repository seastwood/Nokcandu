import XCTest
@testable import NokcanduCore

final class SpaceManagementTests: XCTestCase {
    var root: URL!
    var apps: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-space-\(UUID().uuidString)").resolvingSymlinksInPath()
        apps = root.appendingPathComponent("Apps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        setenv("NOKCANDU_GAME_APPS", apps.path, 1)
    }
    override func tearDownWithError() throws {
        unsetenv("NOKCANDU_GAME_APPS")
        try? FileManager.default.removeItem(at: root)
    }

    func makeApp(in folder: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let app = folder.appendingPathComponent("\(name).app")
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/Games/\(name)"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try Data("game data".utf8).write(to: prefix.appendingPathComponent("drive_c/Games/\(name)/game.exe"))
        let plist: [String: Any] = ["CFBundleName": name, "CFBundleExecutable": "game-launcher", "CFBundleIdentifier": "test.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testOwnershipIsStringOnlyAndHandlesPrivateAndLinkedApps() throws {
        let app = try makeApp(in: apps, name: "Owned")
        let contents = app.appendingPathComponent("Contents")
        let support = WineTools.supportPath(contents)
        XCTAssertTrue(WineTools.owns(executable: support + "/wine/bin/wineserver", support: support))
        XCTAssertTrue(WineTools.owns(executable: support + "/GameApp/Owned.app/Contents/MacOS/Owned", support: support))
        XCTAssertFalse(WineTools.owns(executable: support + "/GameApp/Owned.app/Contents/Resources/x", support: support))
        XCTAssertFalse(WineTools.owns(executable: support + "-other/wine/bin/wine", support: support))
        // The kernel reports /private/var/… for /var/… paths.
        XCTAssertTrue(WineTools.owns(executable: "/private/var/x/SharedSupport/wine/bin/wine", support: "/var/x/SharedSupport"))
        // A link to the app resolves to the same real place.
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertEqual(WineTools.supportPath(link.appendingPathComponent("Contents")), support)
    }

    func testCopyComparisonCatchesMissingAndChangedFiles() throws {
        let fm = FileManager.default
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try fm.createDirectory(at: a.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("1234".utf8).write(to: a.appendingPathComponent("sub/file"))
        try fm.createSymbolicLink(atPath: a.appendingPathComponent("link").path, withDestinationPath: "sub")
        try fm.copyItem(at: a, to: b)
        XCTAssertNil(GameMover.compare(a, b))
        try Data("12345".utf8).write(to: b.appendingPathComponent("sub/file"))
        XCTAssertNotNil(GameMover.compare(a, b))
        try fm.removeItem(at: b.appendingPathComponent("sub/file"))
        XCTAssertNotNil(GameMover.compare(a, b))
    }

    func testMoveKeepsApplicationsLinkListsOnceAndComesBack() throws {
        let fm = FileManager.default
        let other = root.appendingPathComponent("Volume/Nokcandu")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let app = try makeApp(in: apps, name: "Mover")
        let g = try XCTUnwrap(GameLibrary.inspect(app))
        let moved = try GameMover.moveAnchored(g, to: other, library: [g], progress: { _ in })
        XCTAssertEqual(moved.path, other.appendingPathComponent("Mover.app").path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: app.path), moved.path, "Applications keeps a link")
        // Listed once, by the real app, from either folder.
        let listed = GameLibrary.scan(folders: [apps, other]).filter { $0.name == "Mover" }
        XCTAssertEqual(listed.map { $0.appURL.resolvingSymlinksInPath().path }, [moved.resolvingSymlinksInPath().path])
        XCTAssertEqual(GameLibrary.inspect(app)?.appURL.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
        // Back home: the link becomes the app again.
        // Through the library entry (the real app, reached via the link) — as the app does it.
        let back = try GameMover.moveAnchored(try XCTUnwrap(GameLibrary.inspect(app)), to: apps, library: [], progress: { _ in })
        XCTAssertEqual(back.path, app.path)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: app.path))
        XCTAssertFalse(fm.fileExists(atPath: moved.path))
        XCTAssertTrue(fm.fileExists(atPath: app.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/Games/Mover/game.exe").path))
    }

    func testInstallRecordsFollowMovesAndGhostsAreFound() throws {
        let fm = FileManager.default
        let installs = NokPaths.installs.appendingPathComponent("space-test-\(UUID().uuidString)")
        try fm.createDirectory(at: installs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: installs) }
        let old = apps.appendingPathComponent("Record.app")
        let other = root.appendingPathComponent("Other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let real = try makeApp(in: other, name: "Record")
        var state = InstallState(installID: installs.lastPathComponent, recipeID: "custom", targetApp: old.path)
        state.inputs["iconSource"] = old.path + "/Contents/x.exe"
        try ChangeJournal.encoder.encode(state).write(to: installs.appendingPathComponent("state.json"))
        let game = try XCTUnwrap(GameLibrary.inspect(real))
        XCTAssertEqual(InstallRecords.reconcile(library: [game]), 1)
        let saved = try ChangeJournal.decoder.decode(InstallState.self, from: Data(contentsOf: installs.appendingPathComponent("state.json")))
        XCTAssertEqual(saved.targetApp, real.path)
        XCTAssertEqual(saved.inputs["iconSource"], real.path + "/Contents/x.exe")
        // A ghost: settings written into the old place after the move.
        try fm.createDirectory(at: old.appendingPathComponent("Contents/SharedSupport/nokcandu"), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: old.appendingPathComponent("Contents/SharedSupport/nokcandu/microphone-policy"))
        XCTAssertEqual(GhostApps.find(library: [game], confirmedOnly: true).map { $0.resolvingSymlinksInPath().path }, [old.resolvingSymlinksInPath().path])
        // Never a real app, nor a folder with other content.
        try Data("x".utf8).write(to: old.appendingPathComponent("Contents/SharedSupport/other.bin"))
        XCTAssertTrue(GhostApps.find(library: [game]).isEmpty)
        // Writers don't recreate a moved app.
        XCTAssertFalse(AppPresence.exists(root.appendingPathComponent("Gone.app/Contents")))
    }

    func testLogRetentionKeepsCurrentAndRecentLogs() throws {
        let fm = FileManager.default
        let app = try makeApp(in: apps, name: "Logs")
        let g = try XCTUnwrap(GameLibrary.inspect(app))
        try fm.createDirectory(at: g.logs, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-40 * 24 * 3600)
        for name in ["launch.log", "old.log", "recent.log"] {
            try Data(repeating: 65, count: 1000).write(to: g.logs.appendingPathComponent(name))
        }
        for name in ["launch.log", "old.log"] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: g.logs.appendingPathComponent(name).path)
        }
        LogRetention.prune([g])
        XCTAssertTrue(fm.fileExists(atPath: g.logs.appendingPathComponent("launch.log").path), "the current launch log is kept")
        XCTAssertFalse(fm.fileExists(atPath: g.logs.appendingPathComponent("old.log").path))
        XCTAssertTrue(fm.fileExists(atPath: g.logs.appendingPathComponent("recent.log").path))
    }

    func testEngineFilesAreSharedOnlyWhenIdentical() throws {
        let fm = FileManager.default
        EngineShare.testRoot = root
        defer { EngineShare.testRoot = nil }
        func app(_ name: String, special: Bool) throws -> URL {
            let a = try makeApp(in: apps, name: name)
            let wine = a.appendingPathComponent("Contents/SharedSupport/wine/lib")
            try fm.createDirectory(at: wine, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 300_000).write(to: wine.appendingPathComponent("common.so"))
            try Data(repeating: special ? 9 : 8, count: 200_000).write(to: wine.appendingPathComponent("driver.so"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.appendingPathComponent("common.so").path)
            return a
        }
        let a = try app("EngineA", special: false), b = try app("EngineB", special: true)
        XCTAssertEqual(try EngineShare.share(app: a), 0, "the first app seeds the drive's shared copies")
        let freed = try EngineShare.share(app: b)
        XCTAssertGreaterThanOrEqual(freed, 300_000, "the identical file is now stored once")
        let common = b.appendingPathComponent("Contents/SharedSupport/wine/lib/common.so")
        XCTAssertEqual(try Data(contentsOf: common), Data(repeating: 7, count: 300_000))
        XCTAssertEqual((try fm.attributesOfItem(atPath: common.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("Contents/SharedSupport/wine/lib/driver.so")), Data(repeating: 9, count: 200_000),
                       "a file the game changed keeps its own version")
    }
}
