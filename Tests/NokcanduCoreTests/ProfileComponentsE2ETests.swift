import XCTest
@testable import NokcanduCore

final class ProfileComponentsE2ETests: XCTestCase {
    func testBF1942ProfileInstallsAllFiveComponentsAndUndo() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1",
              let resources = ProcessInfo.processInfo.environment["NOKCANDU_RESOURCE_ROOT"] else {
            throw XCTSkip("Requires verified official component downloads and built app resources")
        }
        let fm = FileManager.default, previousResources = NokPaths.resourceOverride
        NokPaths.resourceOverride = URL(fileURLWithPath: resources)
        defer { NokPaths.resourceOverride = previousResources }
        var g = try ProfileCompletenessTests().fixture()
        defer { try? fm.removeItem(at: g.appURL) }
        let exe = try XCTUnwrap(CompatibilityFixes.program(g)), root = exe.deletingLastPathComponent()
        try EngineGraphicsTests().image(["d3d8.dll"]).write(to: exe)
        let wine = g.support.appendingPathComponent("wine/bin/wine")
        try NokPaths.ensure(wine.deletingLastPathComponent())
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        // Eligibility needs a bundled renderer; the installer doesn't execute it here.
        let renderer = g.support.appendingPathComponent("renderer/dxvk/wine/i386-windows/d3d9.dll")
        try NokPaths.ensure(renderer.deletingLastPathComponent())
        try EngineGraphicsTests().image([]).write(to: renderer)
        let settings = root.appendingPathComponent("Mods/bf1942/Settings")
        let sound = settings.appendingPathComponent("Profiles/Default/Sound.con")
        try Data("run Profiles/Default/Sound.con\n".utf8).write(to: settings.appendingPathComponent("Sound.con"))
        let originalSound = Data("game.setHardware 1\ngame.setMasterVolume 63\n".utf8)
        try originalSound.write(to: sound)
        let video = settings.appendingPathComponent("Profiles/Default/Video.con")
        let originalVideo = try Data(contentsOf: video)
        let before = try XCTUnwrap(g.custom)
        let components: [CompatibilityFix] = [.shaderCompiler47, .directx9Extras, .d3d8to9, .borderless, .bf1942SoftwareAudio]
        var profile = GameProfile(title: "BF1942 component regression", match: .init(exeName: "BF1942.exe"), source: "folder", rating: .works)
        profile.schema = 2
        profile.program = before.exe
        profile.graphics = .classic3D
        profile.fixes = components.map(\.id)
        profile.gameDisplay = .init(resolution: [1920, 1200], menuCorrection: false)
        let result = try await Profiles.applyComplete(profile, to: g, includeShared: false) { print("[profile-e2e]", $0) }
        XCTAssertEqual(result.issues, [])
        g = CompatibilityFixes.fresh(g)
        for fix in components { XCTAssertTrue(CompatibilityFixes.isInstalled(fix, for: g), fix.id) }
        for name in ["d3dcompiler_47", "d3dcompiler_43", "d3dx9_43", "d3d8"] {
            XCTAssertEqual(PEFile.inspect(root.appendingPathComponent(name + ".dll"))?.is64Bit, false, name)
        }
        XCTAssertTrue(fm.fileExists(atPath: g.prefix.appendingPathComponent("drive_c/nokcandu/borderless/launcher.exe").path))
        XCTAssertTrue(BF1942AudioFix.isConfigured(g))
        XCTAssertEqual(BF1942DisplayFix.resolution(for: g), [1920, 1200])
        let captured = Profiles.make(from: g, rating: .works, notes: nil, install: nil)
        for fix in components { XCTAssertTrue(captured.fixes?.contains(fix.id) == true) }
        try Profiles.undo(result.snapshot)
        g = CompatibilityFixes.fresh(g)
        for fix in components { XCTAssertFalse(CompatibilityFixes.isInstalled(fix, for: g), fix.id) }
        XCTAssertEqual(try Data(contentsOf: sound), originalSound)
        XCTAssertEqual(try Data(contentsOf: video), originalVideo)
        XCTAssertEqual(g.custom?.exe, before.exe)
        XCTAssertEqual(g.custom?.environment, before.environment)
    }
}
