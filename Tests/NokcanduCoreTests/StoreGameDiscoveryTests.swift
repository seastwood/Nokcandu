import XCTest
@testable import NokcanduCore

final class StoreGameDiscoveryTests: XCTestCase {
    func testCompletedEAAndUbisoftInstallationsBecomeCandidatesButMissingOrOfflineDoNot() throws {
        for kind in [PCLauncher.ea, .ubisoft] {
            let f = try LauncherRemovalTests().fixture(kind: kind)
            defer { try? FileManager.default.removeItem(at: f.root) }
            let found = StoreGameDiscovery.candidates(in: [f.host])
            XCTAssertEqual(found.map(\.name), ["Installed Game"])
            try FileManager.default.removeItem(at: f.files)
            XCTAssertTrue(StoreGameDiscovery.candidates(in: [f.host]).isEmpty)
            let e = f.host.prefix.appendingPathComponent("dosdevices/e:")
            try FileManager.default.removeItem(at: e)
            try FileManager.default.createSymbolicLink(atPath: e.path, withDestinationPath: "/Volumes/Nokcandu-Offline-" + UUID().uuidString)
            XCTAssertTrue(StoreGameDiscovery.candidates(in: [f.host]).isEmpty)
        }
    }
    func testSteamIgnoresDownloadsMissingFoldersAndRuntimePackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try NokPaths.ensure(root.appendingPathComponent("steamapps/common/Game"))
        var game = SharedSteam.LibraryGame(appID: 240, name: "Game", installed: true, installDir: "Game", sizeOnDisk: nil, playtimeMinutes: nil, iconURL: nil, owned: true)
        game.library = root
        XCTAssertTrue(StoreGameDiscovery.steamEligible(game))
        game.stateFlags = 4 | 0x100
        XCTAssertFalse(StoreGameDiscovery.steamEligible(game))
        game.stateFlags = 4; game.appID = 228980
        XCTAssertFalse(StoreGameDiscovery.steamEligible(game))
        game.appID = 240; game.installed = false
        XCTAssertFalse(StoreGameDiscovery.steamEligible(game))
        game.installed = true; game.installDir = "Missing"
        XCTAssertFalse(StoreGameDiscovery.steamEligible(game))
    }
    func testAutomaticAndManualAddsReuseAppWithoutChangingLauncherOrSettings() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = try XCTUnwrap(PCLaunchers.installedGames(.ea, host: f.host).first)
        let candidate = StoreGameDiscovery.Candidate(key: "ea:\(StoreGameDiscovery.hostKey(f.host)):installed game", name: installed.name,
            create: { try PCLaunchers.addGame(installed, kind: .ea, host: f.host, in: f.root) })
        let state = f.root.appendingPathComponent("discovery.json"), scan = { GameLibrary.scan(folders: [f.root]) }
        let first = try StoreGameDiscovery.synchronize(candidates: [candidate, candidate], stateURL: state, scan: scan)
        XCTAssertEqual(first.added.count, 1)
        let app = try XCTUnwrap(first.added.first)
        let script = app.appendingPathComponent("Contents/MacOS/\(CustomGames.launcherName)")
        let manualScript = "#!/bin/sh\n# My edited launcher\nexit 0\n"
        try manualScript.write(to: script, atomically: true, encoding: .utf8)
        let settings = app.appendingPathComponent("Contents/SharedSupport/nokcandu/my-setting.txt")
        try Data("custom settings".utf8).write(to: settings)
        XCTAssertEqual(try PCLaunchers.addGame(installed, kind: .ea, host: f.host, in: f.root).resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
        XCTAssertTrue(try StoreGameDiscovery.synchronize(candidates: [candidate], stateURL: state, scan: scan).added.isEmpty)
        XCTAssertEqual(try String(contentsOf: script), manualScript)
        XCTAssertEqual(try Data(contentsOf: settings), Data("custom settings".utf8))
    }
    func testRemovalStaysRemovedAndManualReaddClearsExclusion() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = try XCTUnwrap(PCLaunchers.installedGames(.ea, host: f.host).first)
        let scan = { GameLibrary.scan(folders: [f.root]) }, state = f.root.appendingPathComponent("state.json")
        let candidate = StoreGameDiscovery.Candidate(key: "ea:\(StoreGameDiscovery.hostKey(f.host)):installed game", name: installed.name,
            create: { try PCLaunchers.addGame(installed, kind: .ea, host: f.host, in: f.root) })
        let url = try XCTUnwrap(StoreGameDiscovery.synchronize(candidates: [candidate], stateURL: state, scan: scan).added.first)
        let game = try XCTUnwrap(GameLibrary.inspect(url))
        try StoreGameDiscovery.preservingRemovalIntent(for: game, library: scan(), at: state) { try FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try StoreGameDiscovery.synchronize(candidates: [candidate], stateURL: state, scan: scan).added.isEmpty)
        _ = try PCLaunchers.addGame(installed, kind: .ea, host: f.host, in: f.root)
        _ = try StoreGameDiscovery.synchronize(candidates: [candidate], stateURL: state, scan: scan)
        XCTAssertFalse(try StoreGameDiscovery.load(state).excluded.contains(candidate.key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.files.path))
    }
    func testFailedRemovalRestoresPolicyAndCorruptStateFailsClosed() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = try XCTUnwrap(PCLaunchers.installedGames(.ea, host: f.host).first)
        let url = try PCLaunchers.addGame(installed, kind: .ea, host: f.host, in: f.root)
        let game = try XCTUnwrap(GameLibrary.inspect(url)), state = f.root.appendingPathComponent("state.json")
        XCTAssertThrowsError(try StoreGameDiscovery.preservingRemovalIntent(for: game, library: [f.host, game], at: state) { throw NokError("Trash refused") })
        XCTAssertEqual(try StoreGameDiscovery.load(state), StoreGameDiscovery.State())
        try Data("corrupt".utf8).write(to: state)
        var invoked = false
        let candidate = StoreGameDiscovery.Candidate(key: "test", name: "Test", create: { invoked = true; return url })
        XCTAssertThrowsError(try StoreGameDiscovery.synchronize(candidates: [candidate], stateURL: state, scan: { [] }))
        XCTAssertFalse(invoked)
    }
    func testFailedCandidateDoesNotBlockOtherGamesAndConcurrentRefreshCreatesOnce() throws {
        let f = try LauncherRemovalTests().fixture(kind: .ubisoft); defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = try XCTUnwrap(PCLaunchers.installedGames(.ubisoft, host: f.host).first)
        let state = f.root.appendingPathComponent("state.json"), scan = { GameLibrary.scan(folders: [f.root]) }
        let good = StoreGameDiscovery.Candidate(key: "ubisoft:\(StoreGameDiscovery.hostKey(f.host)):123", name: installed.name,
            create: { try PCLaunchers.addGame(installed, kind: .ubisoft, host: f.host, in: f.root) })
        let bad = StoreGameDiscovery.Candidate(key: "bad", name: "Incomplete", create: { throw NokError("Not ready") })
        let first = try StoreGameDiscovery.synchronize(candidates: [bad, good], stateURL: state, scan: scan)
        XCTAssertEqual(first.added.count, 1); XCTAssertEqual(first.errors.count, 1)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            _ = try? StoreGameDiscovery.synchronize(candidates: [good], stateURL: state, scan: scan)
        }
        XCTAssertEqual(scan().filter { $0.hosted?.id == "123" }.count, 1)
    }
    func testSameProductInDifferentHostsRemainsDistinctAndHostMoveKeepsKey() throws {
        let a = try LauncherRemovalTests().fixture(kind: .ubisoft), b = try LauncherRemovalTests().fixture(kind: .ubisoft)
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        let keys = StoreGameDiscovery.candidates(in: [a.host, b.host]).map(\.key)
        XCTAssertEqual(Set(keys).count, 2)
        var moved = a.host
        moved.appURL = a.root.appendingPathComponent("Moved Host.app")
        XCTAssertEqual(StoreGameDiscovery.hostKey(moved), StoreGameDiscovery.hostKey(a.host))
    }
}

extension StoreGameDiscoveryTests {
    func testOfflineShortcutAndUnavailableLibraryNeverCauseDuplicateCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state.json")
        try StoreGameDiscovery.save(StoreGameDiscovery.State(apps: ["known": "/Volumes/Nokcandu-Offline-\(UUID().uuidString)/Game.app"]), to: state)
        var invoked = false
        let create = { invoked = true; return root.appendingPathComponent("Game.app") }
        let known = StoreGameDiscovery.Candidate(key: "known", name: "Known", create: create)
        _ = try StoreGameDiscovery.synchronize(candidates: [known], stateURL: state, scan: { [] })
        let unknown = StoreGameDiscovery.Candidate(key: "unknown", name: "Unknown", create: create)
        _ = try StoreGameDiscovery.synchronize(candidates: [unknown], stateURL: state, allowNew: false, scan: { [] })
        XCTAssertFalse(invoked)
        XCTAssertTrue(try StoreGameDiscovery.load(state).excluded.isEmpty)
    }
    func testBlizzardDiscoveryAndIdempotentCreationUseSameProductIdentity() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var config = try XCTUnwrap(f.host.custom)
        config.exe = #"C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe"#
        try config.encoded().write(to: CustomGameConfig.url(in: f.host.contents))
        let registry = #"""
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\StarCraft]
        "DisplayName"="StarCraft"
        "InstallLocation"="E:\\Installed Game"
        "UninstallString"="C:\\Blizzard Uninstaller.exe --uid=s1"

        """#
        try registry.write(to: f.host.prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        let host = try XCTUnwrap(GameLibrary.inspect(f.host.appURL))
        let candidates = StoreGameDiscovery.candidates(in: [host])
        XCTAssertEqual(candidates.count, 1)
        let game = try XCTUnwrap(BattleNet.installedGames(host: host).first)
        let app = try BattleNet.addGame(game, host: host, in: f.root)
        let added = try XCTUnwrap(GameLibrary.inspect(app))
        XCTAssertEqual(StoreGameDiscovery.key(for: added, library: [host, added]), candidates.first?.key)
        XCTAssertEqual(try BattleNet.addGame(game, host: host, in: f.root).resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
    }
    func testFinderRemovalIsRespectedWithoutDeletingInstalledContent() throws {
        let f = try LauncherRemovalTests().fixture(kind: .ubisoft); defer { try? FileManager.default.removeItem(at: f.root) }
        let installed = try XCTUnwrap(PCLaunchers.installedGames(.ubisoft, host: f.host).first)
        let state = f.root.appendingPathComponent("state.json"), scan = { GameLibrary.scan(folders: [f.root]) }
        let candidate = StoreGameDiscovery.Candidate(key: "ubisoft:\(StoreGameDiscovery.hostKey(f.host)):123", name: installed.name,
            create: { try PCLaunchers.addGame(installed, kind: .ubisoft, host: f.host, in: f.root) })
        let app = try XCTUnwrap(StoreGameDiscovery.synchronize(candidates: [candidate], stateURL: state, scan: scan).added.first)
        try FileManager.default.removeItem(at: app)
        XCTAssertTrue(try StoreGameDiscovery.synchronize(candidates: [candidate], stateURL: state, scan: scan).added.isEmpty)
        XCTAssertTrue(try StoreGameDiscovery.load(state).excluded.contains(candidate.key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.files.path))
    }
}
