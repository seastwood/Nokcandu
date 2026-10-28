import XCTest
@testable import NokcanduCore

final class HostedSettingsTests: XCTestCase {
    func testWineRegistryUnicodeEscapesPreservePaths() {
        XCTAssertEqual(WineRegistry.decode(#"Battlefield\x2122 2"#), "Battlefield™ 2")
        XCTAssertEqual(WineRegistry.decode(#"C:\\x2122\\Game\"Name"#), #"C:\x2122\Game"Name"#)
        XCTAssertEqual(WineRegistry.decode(#"\xd83d\xde80"#), "🚀")
        XCTAssertEqual(WineRegistry.decode(#"\xnope\q"#), #"\xnope\q"#)
    }
    func testSettingsRemainWithGameAndProfilesRoundTrip() throws {
        let fm = FileManager.default, (host, _) = try EASetupRecoveryTests().fixture()
        defer { try? fm.removeItem(at: host.appURL) }
        let app = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? fm.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        try NokPaths.ensure(contents.appendingPathComponent("MacOS"))
        try NokPaths.ensure(contents.appendingPathComponent("SharedSupport/nokcandu"))
        let link = HostedGameLink(hostApp: host.appURL.path, launcher: .ea, id: "test", name: "Test", exe: #"C:\Games\Test.exe"#)
        let game = InstalledGame(appURL: app, name: "Test", executableName: CustomGames.launcherName, hosted: link)
        try Data(PCLaunchers.legacyLauncherScript(link).utf8).write(to: game.launcherURL!)
        var settings = HostedSettings.Settings(); settings.graphics = .classic3D; settings.arguments = #"-name "two words""#
        settings.environment = ["WINEDLLOVERRIDES": "d3dx9_42=n,b"]
        try HostedSettings.save(settings, for: game)
        XCTAssertEqual(WineTools.hostContents(for: game), host.contents)
        let hostRaw = RawMouse.flag(host.contents), gameRaw = RawMouse.flag(game.contents)
        try Data("2.00\n".utf8).write(to: hostRaw)
        XCTAssertFalse(RawMouse.settings(for: game).enabled)
        try Data("1.25\nsmooth\n".utf8).write(to: gameRaw)
        XCTAssertEqual(RawMouse.settings(for: game).scale, 1.25)
        XCTAssertEqual(RawMouse.settings(for: host).scale, 2)
        try RawMouse.apply(.init(enabled: false, scale: 1), for: game)
        XCTAssertTrue(RawMouse.settings(for: host).enabled)
        XCTAssertFalse(RawMouse.settings(for: game).enabled)
        let original = try Data(contentsOf: CustomGameConfig.url(in: host.contents))
        var perf = Performance.Settings(); perf.fpsLimit = 60
        try Performance.apply(perf, for: game)
        XCTAssertEqual(Performance.settings(for: game), perf)
        XCTAssertNotEqual(Performance.settings(for: host), perf)
        let script = try String(contentsOf: game.launcherURL!, encoding: .utf8)
        XCTAssertTrue(script.contains("WINEDLLPATH_D9VK"))
        XCTAssertTrue(script.contains("GAME_STATE/perf.env"))
        XCTAssertTrue(script.contains("'two words'"))
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", game.launcherURL!.path]).ok)
        let profile = Profiles.make(from: game, rating: .works, notes: nil, install: nil)
        XCTAssertEqual(profile.graphics, .classic3D)
        XCTAssertEqual(profile.arguments, settings.arguments)
        XCTAssertEqual(profile.match.exeName, "Test.exe")
        XCTAssertEqual(profile.rawMouse, 0); XCTAssertNil(profile.audioBuffer)
        XCTAssertTrue(Profiles.matches(profile, game))
        var changed = profile; changed.graphics = .compatible; changed.arguments = "-window"
        let snapshot = try Profiles.apply(changed, to: game, includeShared: false)
        XCTAssertEqual(HostedSettings.load(game).graphics, .compatible)
        try Profiles.undo(snapshot)
        XCTAssertEqual(HostedSettings.load(game).graphics, .classic3D)
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: host.contents)), original)
        try Data((script + "\n# manually edited\n").utf8).write(to: game.launcherURL!)
        XCTAssertThrowsError(try HostedSettings.save(settings, for: game))
    }
    func testBC2RecipePreservesUnrelatedAndLaterEditsAndSharesOnlyForBC2() throws {
        let fm = FileManager.default, (host, _) = try EASetupRecoveryTests().fixture()
        defer { try? fm.removeItem(at: host.appURL) }
        let exe = host.prefix.appendingPathComponent("drive_c/Games/BFBC2Game.exe")
        try NokPaths.ensure(exe.deletingLastPathComponent()); try OpenUASettingsTests().pe().write(to: exe)
        let app = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? fm.removeItem(at: app) }
        try NokPaths.ensure(app.appendingPathComponent("Contents/SharedSupport/nokcandu"))
        let link = HostedGameLink(hostApp: host.appURL.path, launcher: .ea, id: "bc2", name: "BC2", exe: #"C:\Games\BFBC2Game.exe"#)
        let game = InstalledGame(appURL: app, name: "BC2", hosted: link)
        let ini = try BC2DisplaySettings.ini(game)
        try NokPaths.ensure(ini.deletingLastPathComponent())
        let original = "[WindowSettings]\r\nWidth=1024\r\nHeight=768\r\nFullscreen=true\r\n[Graphics]\r\nDxVersion=auto\r\nTexture=high\r\n[Sound]\r\nQuality=high\r\n"
        try Data(original.utf8).write(to: ini)
        try BC2DisplaySettings.apply(game, resolution: [1280, 800])
        let applied = try String(contentsOf: ini, encoding: .utf8)
        XCTAssertEqual(GameINI.value("WindowSettings/Fullscreen", in: applied), "false")
        XCTAssertEqual(GameINI.value("Graphics/DxVersion", in: applied), "9")
        XCTAssertTrue(applied.contains("Texture=high\r\n"))
        let profile = Profiles.make(from: game, rating: .works, notes: nil, install: nil)
        XCTAssertEqual(profile.gameDisplay?.recipe, "bfbc2"); XCTAssertEqual(profile.problems, [])
        var wrong = profile; wrong.match.exeName = "Other.exe"
        XCTAssertFalse(wrong.problems.isEmpty)
        let edited = GameINI.setting(["Sound/Quality": "low", "WindowSettings/Width": "1600"], in: applied)
        try Data(edited.utf8).write(to: ini)
        try BC2DisplaySettings.undo(game)
        let undone = try String(contentsOf: ini, encoding: .utf8)
        XCTAssertEqual(GameINI.value("WindowSettings/Width", in: undone), "1600")
        XCTAssertEqual(GameINI.value("WindowSettings/Height", in: undone), "768")
        XCTAssertEqual(GameINI.value("WindowSettings/Fullscreen", in: undone), "true")
        XCTAssertEqual(GameINI.value("Graphics/DxVersion", in: undone), "auto")
        XCTAssertEqual(GameINI.value("Sound/Quality", in: undone), "low")
        XCTAssertNil(BC2DisplaySettings.resolution(game))
        XCTAssertEqual(HostedSettings.borderlessPath(link, ext: "dll"), #"C:\nokcandu\borderless\x86\window.dll"#)
    }
    func testEAChildRendererKeepsBrowserAndExplicitOverrides() throws {
        var config = CustomGameConfig(id: "ea", name: "EA", source: .installer, steamAppID: nil, exe: EAAppInstaller.program, graphics: .dxmt)
        config.environment = ["WINEDLLOVERRIDES": "d3dcompiler_47=n,b;d3d9=n"]
        let exports = EAAppInstaller.gameRendererExports(config)
        XCTAssertTrue(exports.contains("WINEDLLPATH_D9VK")); XCTAssertFalse(exports.contains("d3d9=b"))
        let script = CustomGames.launcherScript(for: config)
        XCTAssertTrue(script.contains("WINEDLLPATH_DXMT")); XCTAssertTrue(script.contains("WINEDLLPATH_D9VK"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sh")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(script.utf8).write(to: file)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", file.path]).ok)
        config.exe = #"C:\Games\Other.exe"#
        XCTAssertTrue(EAAppInstaller.gameRendererExports(config).isEmpty)
    }

    func testHostedStorageUsesRegisteredRootInsteadOfExecutableSubfolder() throws {
        let fm = FileManager.default, (host, _) = try EASetupRecoveryTests().fixture()
        defer { try? fm.removeItem(at: host.appURL) }
        let root = host.prefix.appendingPathComponent("drive_c/EA Games/A Big Game")
        let bin = root.appendingPathComponent("bin_ship")
        try NokPaths.ensure(bin)
        try OpenUASettingsTests().pe().write(to: bin.appendingPathComponent("Game.exe"))
        try Data(repeating: 0x31, count: 1024 * 1024).write(to: root.appendingPathComponent("GameData.bin"))
        let reg = #"""
        WINE REGISTRY Version 2

        [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\BIG] 1700000000
        "DisplayName"="A Big Game"
        "DisplayIcon"="C:\\EA Games\\A Big Game\\bin_ship\\Game.exe"
        "InstallLocation"="C:\\EA Games\\A Big Game\\"
        "Publisher"="Electronic Arts"
        """#
        try Data(reg.utf8).write(to: host.prefix.appendingPathComponent("system.reg"))
        let app = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try NokPaths.ensure(app); defer { try? fm.removeItem(at: app) }
        let link = HostedGameLink(hostApp: host.appURL.path, launcher: .ea, id: "A Big Game", name: "A Big Game", exe: #"C:\EA Games\A Big Game\bin_ship\Game.exe"#)
        let game = InstalledGame(appURL: app, name: "Big Game", hosted: link)
        XCTAssertEqual(PCLaunchers.installFolder(link, host: host)?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(WineTools.places(for: game).first { $0.title == "Game folder" }?.url.standardizedFileURL, root.standardizedFileURL)
        let usage = Storage.usage(for: game)
        let files = try XCTUnwrap(usage.parts.first { $0.title == "Game files" })
        XCTAssertEqual(files.url.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        XCTAssertEqual(files.bytes, Storage.size(root))
        XCTAssertGreaterThan(files.bytes ?? 0, Storage.size(bin))
    }
    func testBC2DesktopProfileResolvesCurrentDesktopAndRequiresBC2() throws {
        let expected = BC2DisplaySettings.values(BC2DisplaySettings.desktop)
        XCTAssertEqual(expected["WindowSettings/Fullscreen"], "true")
        XCTAssertGreaterThan(Int(expected["WindowSettings/Width"] ?? "0") ?? 0, 0)
        var profile = GameProfile(title: "BC2", match: .init(exeName: "BFBC2Game.exe"), source: "installer", rating: .works)
        profile.schema = 2
        profile.gameDisplay = .init(recipe: "bfbc2-desktop", resolution: [0,0], menuCorrection: false)
        XCTAssertEqual(profile.problems, [])
        profile.match.exeName = "Other.exe"
        XCTAssertFalse(profile.problems.isEmpty)
    }

}
