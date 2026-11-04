import XCTest
@testable import NokcanduCore

final class SharedGameCompatibilityTests: XCTestCase {
    enum Kind: CaseIterable { case ea, ubisoft, battleNet, steam }
    struct Fixture {
        var root: URL
        var game: InstalledGame
        var host: InstalledGame
        var program: URL
        var previousApps: String?
        var previousJournalRoot: URL?
        func clean() {
            if let previousApps { setenv("NOKCANDU_GAME_APPS", previousApps, 1) } else { unsetenv("NOKCANDU_GAME_APPS") }
            ChangeJournal.defaultRootForTesting = previousJournalRoot
            try? FileManager.default.removeItem(at: root)
        }
    }
    func fixture(_ kind: Kind) throws -> Fixture {
        let f = try LauncherRemovalTests().fixture(kind: kind == .ubisoft ? .ubisoft : .ea)
        let previous = ProcessInfo.processInfo.environment["NOKCANDU_GAME_APPS"]
        let previousJournal = ChangeJournal.defaultRootForTesting
        ChangeJournal.defaultRootForTesting = f.root
        setenv("NOKCANDU_GAME_APPS", f.root.path, 1)
        var completed = false
        defer {
            if !completed {
                if let previous { setenv("NOKCANDU_GAME_APPS", previous, 1) } else { unsetenv("NOKCANDU_GAME_APPS") }
                ChangeJournal.defaultRootForTesting = previousJournal
                try? FileManager.default.removeItem(at: f.root)
            }
        }
        var game = f.game, host = f.host, program = f.files.appendingPathComponent("bin/game.exe")
        try EngineGraphicsTests().image(["d3d8.dll"]).write(to: program)
        switch kind {
        case .ea, .ubisoft:
            try NokPaths.ensure(game.contents.appendingPathComponent("MacOS"))
            try HostedSettings.initialize(try XCTUnwrap(game.hosted), contents: game.contents, host: host)
        case .battleNet:
            let registry = #"""
            WINE REGISTRY Version 2

            [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\game]
            "DisplayName"="Installed Game"
            "UninstallString"="Blizzard Uninstaller --uid=testgame"
            "InstallLocation"="E:\\Installed Game"
            "DisplayIcon"="E:\\Installed Game\\bin\\game.exe"

            """#
            try registry.write(to: host.prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
            game.hosted = nil; game.battleNet = .init(hostApp: host.appURL.path, uid: "testgame", code: "TEST", name: "Installed Game")
        case .steam:
            let app = f.root.appendingPathComponent("Steam.app")
            try FileManager.default.moveItem(at: host.appURL, to: app)
            host = try XCTUnwrap(GameLibrary.inspect(app))
            try NokPaths.ensure(SharedSteam.helper.deletingLastPathComponent())
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: SharedSteam.helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: SharedSteam.helper.path)
            try NokPaths.ensure(SharedSteam.steamDir.appendingPathComponent("steamapps/common/Installed Game"))
            try Data().write(to: SharedSteam.steamDir.appendingPathComponent("steam.exe"))
            program = SharedSteam.steamDir.appendingPathComponent("steamapps/common/Installed Game/game.exe")
            try EngineGraphicsTests().image(["d3d8.dll"]).write(to: program)
            try #"""
            "AppState" { "appid" "12345" "name" "Installed Game" "installdir" "Installed Game" "StateFlags" "4" }
            """#.write(to: SharedSteam.steamDir.appendingPathComponent("steamapps/appmanifest_12345.acf"), atomically: true, encoding: .utf8)
            game.hosted = nil
            game.custom = CustomGameConfig(id: "steam-regression", name: "Installed Game", source: .steamLibrary, steamAppID: 12345, exe: "steam.exe", graphics: .classic3D)
        }
        game.bundleIdentifier = "test.shared." + UUID().uuidString
        game.executableName = CustomGames.launcherName
        let info: [String: Any] = ["CFBundleName": game.name, "CFBundleIdentifier": game.bundleIdentifier!, "CFBundleExecutable": CustomGames.launcherName]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: game.contents.appendingPathComponent("Info.plist"))
        if let link = game.hosted { try JSONEncoder().encode(link).write(to: HostedGameLink.url(game.contents)) }
        if let link = game.battleNet { try JSONEncoder().encode(link).write(to: BattleNetLink.url(game.contents)) }
        if let config = game.custom { try config.encoded().write(to: CustomGameConfig.url(in: game.contents)) }
        completed = true
        return Fixture(root: f.root, game: game, host: host, program: program, previousApps: previous, previousJournalRoot: previousJournal)
    }
    func testPerGameComponentInstallRoutesAndUndoForEveryLauncher() async throws {
        for kind in Kind.allCases {
            let f = try fixture(kind); defer { f.clean() }
            let before = try Data(contentsOf: CustomGameConfig.url(in: f.host.contents))
            XCTAssertEqual(CompatibilityFixes.programForFixes(f.game)?.resolvingSymlinksInPath(), f.program.resolvingSymlinksInPath(), "\(kind)")
            XCTAssertNil(CompatibilityFixes.unavailable(.cursorVisibility, for: f.game), "\(kind)")
            // No game launcher is needed to test a game-local component and exact-program routing.
            try SharedGameCompatibility.writeRoutes(f.game)
            let routes = f.host.nokcanduState.appendingPathComponent("program-fixes.tsv")
            let originalRoutes = try String(contentsOf: routes)
            try await CompatibilityFixes.install(.cursorVisibility, for: f.game) { _ in }
            let content = try String(contentsOf: routes)
            XCTAssertTrue(content.contains(f.program.path)); XCTAssertTrue(content.contains("NOKCANDU_GAME_FIX_STATE=" + f.game.nokcanduState.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.host.nokcanduState.appendingPathComponent("cursor-visibility-fix").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.game.nokcanduState.appendingPathComponent("cursor-visibility-fix").path))
            XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: f.host.contents)), before)
            try CompatibilityFixes.undo(.cursorVisibility, for: f.game) { _ in }
            XCTAssertFalse(CompatibilityFixes.isInstalled(.cursorVisibility, for: f.game))
            XCTAssertEqual(try String(contentsOf: routes), originalRoutes)
            XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: f.host.contents)), before)
        }
    }
    func testTwoGamesWithSameProgramNameKeepIndependentRoutesAndUndo() async throws {
        let f = try fixture(.ea); defer { f.clean() }
        let otherRoot = f.root.appendingPathComponent("Other Drive/Another Game")
        try NokPaths.ensure(otherRoot.appendingPathComponent("bin"))
        try EngineGraphicsTests().image([]).write(to: otherRoot.appendingPathComponent("bin/game.exe"))
        let registry = f.host.prefix.appendingPathComponent("system.reg")
        let block = #"""

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\another]
        "DisplayName"="Another Game"
        "Publisher"="Electronic Arts, Inc."
        "InstallLocation"="E:\\Another Game"
        "DisplayIcon"="E:\\Another Game\\bin\\game.exe"

        """#
        try (String(contentsOf: registry) + "\n" + block).write(to: registry, atomically: true, encoding: .utf8)
        let link = HostedGameLink(hostApp: f.host.appURL.path, launcher: .ea, id: "Another Game", name: "Another Game", exe: #"E:\Another Game\bin\game.exe"#)
        let other = InstalledGame(appURL: f.root.appendingPathComponent("Another.app"), name: "Another Game", hosted: link)
        try NokPaths.ensure(other.nokcanduState); try NokPaths.ensure(other.contents.appendingPathComponent("MacOS"))
        try HostedSettings.initialize(link, contents: other.contents, host: f.host)
        try await CompatibilityFixes.install(.cursorVisibility, for: f.game) { _ in }
        try await CompatibilityFixes.install(.cursorVisibility, for: other) { _ in }
        let routes = f.host.nokcanduState.appendingPathComponent("program-fixes.tsv")
        XCTAssertTrue(try String(contentsOf: routes).contains(f.program.path))
        try CompatibilityFixes.undo(.cursorVisibility, for: f.game) { _ in }
        let remaining = try String(contentsOf: routes)
        XCTAssertFalse(remaining.contains(f.program.path))
        XCTAssertTrue(remaining.contains(otherRoot.path))
        XCTAssertTrue(CompatibilityFixes.isInstalled(.cursorVisibility, for: other))
        try CompatibilityFixes.undo(.cursorVisibility, for: other) { _ in }
        XCTAssertEqual(try String(contentsOf: routes), "")
    }

    func testGameInsideClientGamesFolderIsEligibleWithoutChangingTheClient() async throws {
        let f = try fixture(.ubisoft); defer { f.clean() }
        let client = try XCTUnwrap(f.host.custom.flatMap { BattleNet.unixPath($0.exe, prefix: f.host.prefix) })
        try NokPaths.ensure(client.deletingLastPathComponent())
        try EngineGraphicsTests().image([]).write(to: client)
        let root = client.deletingLastPathComponent().appendingPathComponent("games/Installed Game")
        try NokPaths.ensure(root)
        let program = root.appendingPathComponent("game.exe")
        try EngineGraphicsTests().image([]).write(to: program)
        let rootWindows = try XCTUnwrap(CustomGames.windowsPath(forUnix: root, prefix: f.host.prefix))
        let registry = #"""
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\123]
        "InstallDir"="
        """# + rootWindows.replacingOccurrences(of: "\\", with: "\\\\") + "\"\n\n"
        try registry.write(to: f.host.prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        var game = f.game
        game.hosted?.exe = rootWindows + #"\game.exe"#
        try JSONEncoder().encode(try XCTUnwrap(game.hosted)).write(to: HostedGameLink.url(game.contents))
        XCTAssertNil(CompatibilityFixes.unavailable(.cursorVisibility, for: game))
        let before = try Data(contentsOf: client)
        try await CompatibilityFixes.install(.cursorVisibility, for: game) { _ in }
        try CompatibilityFixes.undo(.cursorVisibility, for: game) { _ in }
        XCTAssertEqual(try Data(contentsOf: client), before)
    }

    func testBattleNetProfileChangesOnlyGameSettingsAndRestoresThem() async throws {
        let f = try fixture(.battleNet); defer { f.clean() }
        let client = try Data(contentsOf: CustomGameConfig.url(in: f.host.contents))
        var profile = GameProfile(title: "Scoped Battle.net profile", match: .init(battleNetUID: "testgame"), source: "battlenet", rating: .works)
        profile.graphics = .dxmt; profile.environment = ["DXVK_HUD": "fps"]; profile.fixes = [CompatibilityFix.cursorVisibility.id]
        let result = try await Profiles.applyComplete(profile, to: f.game, includeShared: false)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(BattleNetGraphics.choice(f.game), .dxmt)
        XCTAssertEqual(BattleNetGraphics.environment(f.game), ["DXVK_HUD": "fps"])
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: f.host.contents)), client)
        let captured = Profiles.make(from: f.game, rating: .works, notes: nil, install: nil)
        XCTAssertEqual(captured.schema, 3)
        XCTAssertTrue(captured.problems.isEmpty)
        XCTAssertEqual(captured.graphics, .dxmt)
        XCTAssertEqual(captured.environment?["DXVK_HUD"], "fps")
        var laterClientPreference = Performance.settings(for: f.host); laterClientPreference.vsync = true
        try Performance.apply(laterClientPreference, for: f.host)
        try Profiles.undo(result.snapshot)
        XCTAssertEqual(Performance.settings(for: f.host), laterClientPreference)
        XCTAssertNil(BattleNetGraphics.choice(f.game))
        XCTAssertEqual(BattleNetGraphics.environment(f.game), [:])
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: f.host.contents)), client)
    }

    func testSteamProfileExtraSettingsArePerGameAndUndoable() async throws {
        let f = try fixture(.steam); defer { f.clean() }
        let client = try Data(contentsOf: CustomGameConfig.url(in: f.host.contents))
        var profile = GameProfile(title: "Scoped Steam settings", match: .init(steamAppID: 12345), source: "steam", rating: .works)
        profile.environment = ["DXVK_HUD": "fps"]
        let result = try await Profiles.applyComplete(profile, to: f.game, includeShared: false)
        XCTAssertEqual(result.issues, [])
        let current = try XCTUnwrap(GameLibrary.inspect(f.game.appURL))
        XCTAssertEqual(current.custom?.environment?["DXVK_HUD"], "fps")
        let routes = f.host.nokcanduState.appendingPathComponent("program-fixes.tsv")
        XCTAssertTrue(try String(contentsOf: routes).contains("DXVK_HUD=fps"))
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: f.host.contents)), client)
        try Profiles.undo(result.snapshot)
        XCTAssertEqual(GameLibrary.inspect(f.game.appURL)?.custom?.environment, f.game.custom?.environment)
        XCTAssertEqual(try String(contentsOf: routes), "")
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: f.host.contents)), client)
    }

    func testRenamingGameKeepsComponentsBoundToTheirOriginalProgram() async throws {
        let f = try fixture(.steam); defer { f.clean() }
        try await CompatibilityFixes.install(.cursorVisibility, for: f.game) { _ in }
        try EngineGraphicsTests().image([]).write(to: f.program.deletingLastPathComponent().appendingPathComponent("Renamed.exe"))
        let current = try XCTUnwrap(GameLibrary.inspect(f.game.appURL))
        var config = try XCTUnwrap(current.custom); config.name = "Renamed"
        try CustomGames.saveAll(config, to: current)
        let renamed = try XCTUnwrap(GameLibrary.inspect(f.game.appURL))
        XCTAssertEqual(CompatibilityFixes.programForFixes(renamed)?.resolvingSymlinksInPath(), f.program.resolvingSymlinksInPath())
        try CompatibilityFixes.undo(.cursorVisibility, for: renamed) { _ in }
    }

    func testInterruptedInstallDoesNotActivateRulesOrPublishAsWorkingFix() async throws {
        let f = try fixture(.ea); defer { f.clean() }
        let manual = f.root.appendingPathComponent("manual-routes.txt")
        let original = Data("keep this file\n".utf8); try original.write(to: manual)
        let routes = f.host.nokcanduState.appendingPathComponent("program-fixes.tsv")
        try FileManager.default.createSymbolicLink(at: routes, withDestinationURL: manual)
        do { try await CompatibilityFixes.install(.cursorVisibility, for: f.game) { _ in }; XCTFail("Linked routing file must be preserved") } catch {}
        XCTAssertEqual(try Data(contentsOf: manual), original)
        XCTAssertTrue(CompatibilityFixes.needsRecovery(.cursorVisibility, for: f.game))
        XCTAssertFalse(CompatibilityFixes.isEnabled(.cursorVisibility, for: f.game))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.game.nokcanduState.appendingPathComponent("cursor-visibility-fix").path))
        let captured = Profiles.make(from: f.game, rating: .works, notes: nil, install: nil)
        XCTAssertFalse(captured.fixes?.contains(CompatibilityFix.cursorVisibility.id) == true)
        var requested = captured; requested.fixes = [CompatibilityFix.cursorVisibility.id]
        XCTAssertTrue(Profiles.plan(requested, for: f.game).skipped.contains { $0.contains("incomplete installation") })
        try FileManager.default.removeItem(at: routes)
        try CompatibilityFixes.undo(.cursorVisibility, for: f.game) { _ in }
        XCTAssertFalse(CompatibilityFixes.isInstalled(.cursorVisibility, for: f.game))
    }

    func testSymlinkEscapeAndClientProgramCannotReceiveGameFixes() throws {
        let f = try fixture(.ea); defer { f.clean() }
        let outside = f.root.appendingPathComponent("other.exe")
        try EngineGraphicsTests().image([]).write(to: outside)
        XCTAssertThrowsError(try CompatibilityFixes.selectProgramForFixes(outside, for: f.game))
        let link = f.program.deletingLastPathComponent().appendingPathComponent("escape.exe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try CompatibilityFixes.selectProgramForFixes(link, for: f.game))
        XCTAssertNotNil(CompatibilityFixes.unavailable(.ipxNetworking, for: f.game))
    }
}

extension SharedGameCompatibilityTests {
    func testBF1942SharedProfileInstallsAllFiveComponentsAndUndoes() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1", let resourcePath = ProcessInfo.processInfo.environment["NOKCANDU_RESOURCE_ROOT"] else {
            throw XCTSkip("Requires built helpers and verified official component packages")
        }
        let f = try fixture(.ea); defer { f.clean() }
        let oldResources = NokPaths.resourceOverride
        NokPaths.resourceOverride = URL(fileURLWithPath: resourcePath); defer { NokPaths.resourceOverride = oldResources }
        let root = f.program.deletingLastPathComponent()
        let program = root.appendingPathComponent("BF1942.exe")
        try EngineGraphicsTests().image(["d3d8.dll"]).write(to: program)
        try CompatibilityFixes.selectProgramForFixes(program, for: f.game)
        let settings = root.appendingPathComponent("Mods/bf1942/Settings"), sound = settings.appendingPathComponent("Profiles/Default/Sound.con")
        try NokPaths.ensure(sound.deletingLastPathComponent())
        try Data("run Profiles/Default/Sound.con\n".utf8).write(to: settings.appendingPathComponent("Sound.con"))
        let originalSound = Data("game.setHardware 1\ngame.setMasterVolume 63\n".utf8)
        try originalSound.write(to: sound)
        let renderer = f.host.support.appendingPathComponent("renderer/dxvk/wine/i386-windows/d3d9.dll")
        try NokPaths.ensure(renderer.deletingLastPathComponent()); try EngineGraphicsTests().image([]).write(to: renderer)
        let originalHost = try Data(contentsOf: CustomGameConfig.url(in: f.host.contents))
        let originalSettings = HostedSettings.load(f.game)
        let components: [CompatibilityFix] = [.shaderCompiler47, .directx9Extras, .d3d8to9, .borderless, .bf1942SoftwareAudio]
        var profile = GameProfile(title: "Shared BF1942 regression", match: .init(exeName: "BF1942.exe"), source: "folder", rating: .works)
        profile.graphics = .classic3D; profile.fixes = components.map(\.id)
        let result = try await Profiles.applyComplete(profile, to: f.game, includeShared: false) { print("[shared-profile]", $0) }
        XCTAssertEqual(result.issues, [])
        for component in components { XCTAssertTrue(CompatibilityFixes.isInstalled(component, for: f.game), component.id) }
        for file in ["d3d8", "d3dcompiler_47", "d3dcompiler_43", "d3dx9_43"] {
            XCTAssertEqual(PEFile.inspect(root.appendingPathComponent(file + ".dll"))?.is64Bit, false)
        }
        XCTAssertTrue(BF1942AudioFix.isConfigured(f.game))
        let routes = try String(contentsOf: f.host.nokcanduState.appendingPathComponent("program-fixes.tsv"))
        XCTAssertTrue(routes.contains("WINEDLLPATH_D9VK=")); XCTAssertTrue(routes.contains("d3d8=n"))
        let script = try String(contentsOf: f.game.contents.appendingPathComponent("MacOS/game-launcher"))
        XCTAssertTrue(script.contains("NOKCANDU_BORDERLESS_TARGET=")); XCTAssertTrue(script.contains("WINEDLLPATH_D9VK="))
        let captured = Profiles.make(from: f.game, rating: .works, notes: nil, install: nil)
        XCTAssertEqual(Set(captured.fixes ?? []), Set(components.map(\.id)))
        XCTAssertEqual(captured.schema, 3)
        XCTAssertEqual(captured.fixes?.count, components.count)
        XCTAssertTrue(captured.problems.isEmpty, captured.problems.joined(separator: ";"))
        XCTAssertFalse(captured.environment?.values.contains(where: { $0.contains(f.root.path) }) == true)
        try Profiles.undo(result.snapshot)
        for component in components { XCTAssertFalse(CompatibilityFixes.isInstalled(component, for: f.game)) }
        XCTAssertEqual(try Data(contentsOf: sound), originalSound)
        XCTAssertEqual(HostedSettings.load(f.game).environment, originalSettings.environment)
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: f.host.contents)), originalHost)
        XCTAssertEqual(try String(contentsOf: f.host.nokcanduState.appendingPathComponent("program-fixes.tsv")), "")
    }
    func testEditedLauncherIsPreservedBeforeComponentMutation() async throws {
        let f = try fixture(.ea); defer { f.clean() }
        let script = f.game.contents.appendingPathComponent("MacOS/game-launcher")
        let edited = try String(contentsOf: script) + "\n# user edit\n"
        try edited.write(to: script, atomically: true, encoding: .utf8)
        do { try await CompatibilityFixes.install(.cursorVisibility, for: f.game) { _ in }; XCTFail("Edited script must be preserved") } catch {}
        XCTAssertEqual(try String(contentsOf: script), edited)
        XCTAssertFalse(CompatibilityFixes.isInstalled(.cursorVisibility, for: f.game))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.game.nokcanduState.appendingPathComponent("cursor-visibility-fix").path))
    }
}
