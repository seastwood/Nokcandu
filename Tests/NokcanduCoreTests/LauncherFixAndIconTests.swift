import XCTest
@testable import NokcanduCore

final class LauncherFixAndIconTests: XCTestCase {
    func testSoftwareSoundFixIsProfilePortableAndUndoKeepsLaterVolumeEdits() async throws {
        var g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let exe = try XCTUnwrap(CompatibilityFixes.program(g))
        try EngineGraphicsTests().image(["d3d8.dll"]).write(to: exe)
        let settings = exe.deletingLastPathComponent().appendingPathComponent("Mods/bf1942/Settings")
        let routing = settings.appendingPathComponent("Sound.con"), sound = settings.appendingPathComponent("Profiles/Default/Sound.con")
        try Data("run Profiles/Default/Sound.con\r\n".utf8).write(to: routing)
        try Data("rem keep\r\ngame.setHardware 1\r\ngame.setMasterVolume 80\r\n".utf8).write(to: sound)
        XCTAssertTrue(BF1942AudioFix.supports(g))
        try await CompatibilityFixes.install(.bf1942SoftwareAudio, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertTrue(BF1942AudioFix.isConfigured(g))
        XCTAssertTrue(Profiles.make(from: g, rating: .works, notes: nil, install: nil).fixes!.contains("bf1942-software-audio"))
        var text = try String(contentsOf: sound, encoding: .utf8)
        XCTAssertTrue(text.contains("rem keep\r\n"))
        text = text.replacingOccurrences(of: "game.setMasterVolume 80", with: "game.setMasterVolume 45")
        try Data(text.utf8).write(to: sound)
        try CompatibilityFixes.undo(.bf1942SoftwareAudio, for: g) { _ in }
        text = try String(contentsOf: sound, encoding: .utf8)
        XCTAssertTrue(text.contains("game.setHardware 1")); XCTAssertTrue(text.contains("game.setMasterVolume 45"))
        try Data("run Profiles/../Sound.con\n".utf8).write(to: routing)
        XCTAssertFalse(BF1942AudioFix.supports(g))
    }

    func testCompleteProfileInstallsComponentsReportsSkippedFixAndUndoesOnlyNewComponents() async throws {
        var g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let wine = g.support.appendingPathComponent("wine/bin/wine")
        try NokPaths.ensure(wine.deletingLastPathComponent())
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try EngineGraphicsTests().image(["d3d11.dll"]).write(to: XCTUnwrap(CompatibilityFixes.program(g)))
        let before = try XCTUnwrap(g.custom)
        var p = GameProfile(title: "With components", match: .init(exeName: "BF1942.exe"), source: "folder", rating: .playable)
        p.graphics = .dxmt; p.fixes = [CompatibilityFix.crossProcessWindows.id, CompatibilityFix.d3d8to9.id]
        let result = try await Profiles.applyComplete(p, to: g, includeShared: false)
        g = CompatibilityFixes.fresh(g)
        XCTAssertTrue(CompatibilityFixes.isInstalled(.crossProcessWindows, for: g))
        XCTAssertEqual(g.custom?.environment?["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"], "1")
        XCTAssertTrue(result.issues.contains { $0.contains(CompatibilityFix.d3d8to9.title) })
        XCTAssertFalse(CompatibilityFixes.isInstalled(.d3d8to9, for: g))
        let again = try await Profiles.applyComplete(p, to: g, includeShared: false)
        XCTAssertTrue(again.snapshot.addedComponents.isEmpty)
        try Profiles.undo(again.snapshot)
        XCTAssertTrue(CompatibilityFixes.isInstalled(.crossProcessWindows, for: CompatibilityFixes.fresh(g)))
        try Profiles.undo(result.snapshot)
        g = CompatibilityFixes.fresh(g)
        XCTAssertFalse(CompatibilityFixes.isInstalled(.crossProcessWindows, for: g))
        XCTAssertEqual(g.custom?.graphics, before.graphics)
        XCTAssertEqual(g.custom?.environment, before.environment)
    }

    func testResolutionOnlyReceiptDoesNotLockProgramAndUndoKeepsNewLauncher() async throws {
        var g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let program = try XCTUnwrap(CompatibilityFixes.program(g)), root = program.deletingLastPathComponent()
        try EngineGraphicsTests().image(["d3d8.dll"]).write(to: program)
        let video = root.appendingPathComponent("Mods/bf1942/Settings/Profiles/Default/Video.con")
        let originalVideo = try Data(contentsOf: video)
        try await BF1942DisplayFix.apply(to: g, size: [1280, 800], recommended: false) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertFalse(BF1942DisplayFix.ownsProgram(for: g))
        let wrapper = root.appendingPathComponent("Borderless1942.exe")
        try EngineGraphicsTests().image(["kernel32.dll"], is64: true).write(to: wrapper)
        var config = try XCTUnwrap(g.custom)
        config.exe = try XCTUnwrap(CustomGames.windowsPath(forUnix: wrapper, prefix: g.prefix))
        try CustomGames.save(config, to: g)
        g = CompatibilityFixes.fresh(g)
        XCTAssertTrue(BF1942DisplayFix.supports(g))
        XCTAssertTrue(BF1942DisplayFix.hasChanges(for: g))
        XCTAssertEqual(BF1942DisplayFix.resolution(for: g), [1280, 800])
        try BF1942DisplayFix.undo(for: g) { _ in }
        XCTAssertEqual(CompatibilityFixes.fresh(g).custom?.exe, config.exe)
        XCTAssertEqual(try Data(contentsOf: video), originalVideo)
        XCTAssertFalse(BF1942DisplayFix.hasChanges(for: g))
    }

    func testDirectX8Behind64BitLauncherAndAmbiguousOrEscapingCandidates() throws {
        var g = try ProfileCompletenessTests().fixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: g.appURL) }
        let game = try XCTUnwrap(CompatibilityFixes.program(g))
        let root = game.deletingLastPathComponent(), launcher = root.appendingPathComponent("Borderless1942.exe")
        let image = EngineGraphicsTests()
        try image.image(["d3d8.dll"]).write(to: game)
        try image.image(["kernel32.dll"], is64: true).write(to: launcher)
        var config = try XCTUnwrap(g.custom)
        config.exe = try XCTUnwrap(CustomGames.windowsPath(forUnix: launcher, prefix: g.prefix))
        g.custom = config
        let renderer = g.support.appendingPathComponent("renderer/dxvk/wine/i386-windows/d3d9.dll")
        try NokPaths.ensure(renderer.deletingLastPathComponent()); try Data([1]).write(to: renderer)
        XCTAssertEqual(CompatibilityFixes.directX8Program(g), game)
        XCTAssertNil(CompatibilityFixes.unavailable(.d3d8to9, for: g))
        XCTAssertEqual(g.custom?.exe, config.exe)
        let second = root.appendingPathComponent("AnotherGame.exe")
        try image.image(["D3D8.DLL"]).write(to: second)
        XCTAssertNil(CompatibilityFixes.directX8Program(g))
        try fm.removeItem(at: second)
        try image.image(["d3d11.dll"]).write(to: game)
        XCTAssertNil(CompatibilityFixes.directX8Program(g))
        let external = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".exe")
        defer { try? fm.removeItem(at: external) }
        try image.image(["d3d8.dll"]).write(to: external)
        try fm.createSymbolicLink(at: second, withDestinationURL: external)
        XCTAssertNil(CompatibilityFixes.directX8Program(g))
    }

    func testIconChangeUndoAndManualEditProtectionPreserveLaunchSettings() throws {
        let g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let config = try Data(contentsOf: CustomGameConfig.url(in: g.contents))
        let info = try Data(contentsOf: g.contents.appendingPathComponent("Info.plist"))
        let icon = Data("icns-test-icon".utf8)
        try GameIcon.apply(icon, for: g)
        let updated = try XCTUnwrap(GameLibrary.inspect(g.appURL))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(updated.iconURL)), icon)
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: g.contents)), config)
        try GameIcon.apply(Data("icns-second-icon".utf8), for: updated)
        try GameIcon.undo(updated)
        XCTAssertEqual(try Data(contentsOf: g.contents.appendingPathComponent("Info.plist")), info)
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: g.contents)), config)
        try GameIcon.apply(icon, for: g)
        let selected = try XCTUnwrap(GameLibrary.inspect(g.appURL)), target = try XCTUnwrap(selected.iconURL)
        try Data("manual icon edit".utf8).write(to: target)
        XCTAssertThrowsError(try GameIcon.undo(selected))
        XCTAssertThrowsError(try GameIcon.apply(icon, for: selected))
        XCTAssertEqual(try Data(contentsOf: target), Data("manual icon edit".utf8))
        XCTAssertThrowsError(try GameIcon.set(from: g.appURL.appendingPathComponent("missing.exe"), for: g))
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: g.contents)), config)
    }

    func testInstalledBF1942LauncherAndIconExtractionWhenAvailable() throws {
        let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Sikarugir/Battlefield 1942 (Moongamers).app")
        guard let actual = GameLibrary.inspect(app) else { throw XCTSkip("Reported installation unavailable") }
        XCTAssertNil(CompatibilityFixes.unavailable(.d3d8to9, for: actual))
        let target = try XCTUnwrap(CompatibilityFixes.directX8Program(actual))
        XCTAssertEqual(target.lastPathComponent.lowercased(), "bf1942.exe")
        let g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let config = try Data(contentsOf: CustomGameConfig.url(in: g.contents))
        try GameIcon.set(from: target, for: g)
        let updated = try XCTUnwrap(GameLibrary.inspect(g.appURL))
        XCTAssertGreaterThan(try Data(contentsOf: XCTUnwrap(updated.iconURL)).count, 8)
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: g.contents)), config)
        try GameIcon.undo(updated)
    }
}
