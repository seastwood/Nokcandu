import XCTest
@testable import NokcanduCore

final class CompatibilityFixTests: XCTestCase {
    func testBundledRuntimeAndCrossProcessFixesAreSharedOptInAndUndoable() async throws {
        var g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let exe = try XCTUnwrap(CompatibilityFixes.program(g)), pe = OpenUASettingsTests().pe()
        try pe.write(to: exe)
        try pe.write(to: exe.deletingLastPathComponent().appendingPathComponent("msvcp140.dll"))
        try Data("invalid DLL".utf8).write(to: exe.deletingLastPathComponent().appendingPathComponent("concrt140.dll"))
        var c = try XCTUnwrap(g.custom); c.graphics = .dxmt
        c.environment = ["KEEP": "original", "WINEDLLOVERRIDES": "dsound=n", "DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN": "0"]
        try CustomGames.save(c, to: g); g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(CompatibilityFixes.bundledVCRules(g), ["msvcp140": "n,b"])
        XCTAssertFalse(CompatibilityFixes.isInstalled(.bundledVC, for: g))
        try await CompatibilityFixes.install(.bundledVC, for: g) { _ in }
        try await CompatibilityFixes.install(.crossProcessWindows, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment?["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"], "1")
        XCTAssertEqual(CompatibilityFixes.overrides(g.custom?.environment?["WINEDLLOVERRIDES"])["dsound"], "n")
        var rebuilt = try XCTUnwrap(g.custom); rebuilt.environment = nil
        let retained = CompatibilityFixes.preservingInstalledSettings(rebuilt, for: g)
        XCTAssertEqual(retained.environment?["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"], "1")
        XCTAssertEqual(CompatibilityFixes.overrides(retained.environment?["WINEDLLOVERRIDES"])["msvcp140"], "n,b")
        let profile = Profiles.make(from: g, rating: .playable, notes: nil, install: nil)
        XCTAssertTrue(profile.fixes?.contains("bundled-vc-runtime") == true)
        XCTAssertTrue(profile.fixes?.contains("cross-process-windows") == true)
        try CompatibilityFixes.undo(.crossProcessWindows, for: g) { _ in }
        try CompatibilityFixes.undo(.bundledVC, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment?["DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN"], "0")
        XCTAssertEqual(g.custom?.environment?["KEEP"], "original")
        XCTAssertEqual(g.custom?.environment?["WINEDLLOVERRIDES"], "dsound=n")
        XCTAssertEqual(try Data(contentsOf: exe), pe)
    }

    func testMicrosoftShaderCompilerBothArchitecturesInstallAndUndoE2E() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1",
              let root = ProcessInfo.processInfo.environment["NOKCANDU_RESOURCE_ROOT"] else {
            throw XCTSkip("Requires official Microsoft downloads and built app resources")
        }
        let fm = FileManager.default, previousDirectory = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(root))
        defer { _ = fm.changeCurrentDirectoryPath(previousDirectory) }
        for is64 in [false, true] {
            var g = try ProfileCompletenessTests().fixture()
            defer { try? fm.removeItem(at: g.appURL) }
            let exe = try XCTUnwrap(CompatibilityFixes.program(g))
            var pe = OpenUASettingsTests().pe(); pe[0x99] = is64 ? 2 : 1
            try pe.write(to: exe)
            let dll = exe.deletingLastPathComponent().appendingPathComponent("d3dcompiler_47.dll")
            let original = Data("preserve previous DLL".utf8)
            try original.write(to: dll)
            var config = try XCTUnwrap(g.custom)
            config.environment = ["KEEP": "yes", "WINEDLLOVERRIDES": "d3dcompiler_47=b;dsound=n"]
            try CustomGames.save(config, to: g); g = CompatibilityFixes.fresh(g)
            try await CompatibilityFixes.install(.shaderCompiler47, for: g) { print("[shader47]", $0) }
            g = CompatibilityFixes.fresh(g)
            XCTAssertEqual(PEFile.inspect(dll)?.is64Bit, is64)
            XCTAssertEqual(CompatibilityFixes.overrides(g.custom?.environment?["WINEDLLOVERRIDES"])["d3dcompiler_47"], "n,b")
            XCTAssertEqual(g.custom?.environment?["KEEP"], "yes")
            let profile = Profiles.make(from: g, rating: .playable, notes: nil, install: nil)
            XCTAssertTrue(profile.fixes?.contains("shader-compiler-47") == true)
            try CompatibilityFixes.undo(.shaderCompiler47, for: g) { _ in }
            XCTAssertEqual(try Data(contentsOf: dll), original)
            let after = CompatibilityFixes.fresh(g)
            XCTAssertEqual(CompatibilityFixes.overrides(after.custom?.environment?["WINEDLLOVERRIDES"])["d3dcompiler_47"], "b")
            XCTAssertEqual(CompatibilityFixes.overrides(after.custom?.environment?["WINEDLLOVERRIDES"])["dsound"], "n")
        }
    }

    func testGroupedOverridesPreserveOtherComponents() {
        let prior = CompatibilityFixes.overrides("d3d8,d3d9=b;dsound=n;d3dx9_43=n,b")
        XCTAssertEqual(prior["d3d9"], "b")
        var c = CustomGameConfig(id: "test", name: "Test", source: .folder, exe: #"C:\Games\T\T.exe"#, graphics: .classic3D)
        c.environment = ["OTHER": "value"]
        var rules = prior; rules["d3d8"] = "n"
        CompatibilityFixes.setOverrides(rules, in: &c)
        XCTAssertEqual(c.environment?["OTHER"], "value")
        XCTAssertEqual(CompatibilityFixes.overrides(c.environment?["WINEDLLOVERRIDES"])["dsound"], "n")
        XCTAssertEqual(CompatibilityFixes.overrides(c.environment?["WINEDLLOVERRIDES"])["d3d9"], "b")
    }

    func testOptInLauncherKeepsTargetAndQuotesArguments() throws {
        var c = CustomGameConfig(id: "test", name: "Test", source: .folder, exe: #"C:\Games\A Game\T.exe"#, graphics: .classic3D)
        c.arguments = #"+name "A B" +restart 1"#
        let original = CustomGames.launcherScript(for: c)
        XCTAssertFalse(original.contains("NOKCANDU_BORDERLESS_TARGET"))
        c.borderless = true; c.legacyD3D9 = true
        let script = CustomGames.launcherScript(for: c)
        XCTAssertTrue(script.contains(#"export NOKCANDU_BORDERLESS_TARGET="$GAME_EXE""#))
        XCTAssertTrue(script.contains("renderer/dxvk/wine"))
        XCTAssertEqual(c.exe, #"C:\Games\A Game\T.exe"#)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sh")
        defer { try? FileManager.default.removeItem(at: path) }
        try script.write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", path.path]).ok)
        // New optional switches are absent in old game.json, which must still decode.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: c.encoded()) as? [String: Any])
        json.removeValue(forKey: "borderless"); json.removeValue(forKey: "legacyD3D9")
        let old = try ChangeJournal.decoder.decode(CustomGameConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.borderless); XCTAssertNil(old.legacyD3D9)
    }

    func testProfilesReferenceOnlyBuiltInComponents() throws {
        var p = GameProfile(title: "T", match: .init(exeName: "T.exe"), source: "folder", rating: .playable)
        p.fixes = CompatibilityFix.allCases.filter { $0 != .openUA }.map(\.id)
        XCTAssertEqual(p.problems, [])
        XCTAssertEqual(try GameProfile.parse("```json\n" + p.json() + "\n```"), p)
        p.fixes = ["https://example.com/arbitrary.dll"]
        XCTAssertFalse(p.problems.isEmpty)
        let shared = InstalledGame(appURL: URL(fileURLWithPath: "/tmp/T.app"), name: "T", custom:
            CustomGameConfig(id: "t", name: "T", source: .steamLibrary, exe: "T.exe", graphics: .classic3D))
        for fix in CompatibilityFix.allCases { XCTAssertNotNil(CompatibilityFixes.unavailable(fix, for: shared)) }
    }
    func testCursorFixIsOptInShareableAndIndependentlyUndoable() async throws {
        var g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let bfGame = g
        var config = try XCTUnwrap(g.custom)
        config.exe = #"C:\Games\BF1942\CursorGame.exe"#
        try config.encoded().write(to: CustomGameConfig.url(in: g.contents))
        g = try XCTUnwrap(GameLibrary.inspect(g.appURL))
        let exe = try XCTUnwrap(CompatibilityFixes.program(g))
        var pe = Data(repeating: 0, count: 512)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[0x3c] = 0x80
        pe[0x80] = 0x50; pe[0x81] = 0x45; pe[0x94] = 0xe0
        pe[0x98] = 0x0b; pe[0x99] = 0x01
        try pe.write(to: try XCTUnwrap(CompatibilityFixes.program(bfGame)))
        XCTAssertTrue(CompatibilityFixes.unavailable(.cursorVisibility, for: bfGame)?.contains("flicker") == true,
                      "A valid BF1942 executable must still be protected from the reported flicker")
        try pe.write(to: exe)
        let flag = g.nokcanduState.appendingPathComponent("cursor-visibility-fix")
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
        XCTAssertNil(CompatibilityFixes.unavailable(.cursorVisibility, for: g))
        try await CompatibilityFixes.install(.cursorVisibility, for: g) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: flag.path))
        XCTAssertEqual(try Data(contentsOf: exe), pe)
        XCTAssertEqual(CompatibilityFixes.installedIDs(for: g), ["cursor-visibility"])
        XCTAssertFalse(RawMouse.settings(for: g).enabled)
        let profile = Profiles.make(from: CompatibilityFixes.fresh(g), rating: .playable, notes: nil, install: nil)
        XCTAssertTrue(profile.fixes?.contains("cursor-visibility") == true)
        try CompatibilityFixes.undo(.cursorVisibility, for: g) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: flag.path))
        XCTAssertEqual(try Data(contentsOf: exe), pe)
    }
    func testUndoChecksFilesBeforeChangingSettingsAndKeepsOtherFixes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fix-undo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var g = InstalledGame(appURL: root.appendingPathComponent("T.app"), name: "Test-" + UUID().uuidString)
        var c = CustomGameConfig(id: "t", name: g.name, source: .folder, exe: #"C:\Games\T\T.exe"#, graphics: .classic3D)
        c.createdAt = Date(timeIntervalSince1970: 1000)
        c.environment = ["WINEDLLOVERRIDES": "d3d8=n;d3d9=b;d3dx9_43=n,b;dsound=n"]
        c.legacyD3D9 = true
        g.custom = c
        try NokPaths.ensure(g.nokcanduState)
        try NokPaths.ensure(g.contents.appendingPathComponent("MacOS"))
        let original = g.prefix.appendingPathComponent("drive_c/Games/T/d3dx9_43.dll")
        try NokPaths.ensure(original.deletingLastPathComponent())
        try Data("original DLL".utf8).write(to: original)
        let j = CompatibilityFixes.journal(.directx9Extras, g)
        try j.write(Data("Microsoft DLL".utf8), to: original, reason: "test")
        let st = CompatibilityFixes.State(executable: c.exe, previousOverrides: ["d3d8": "n", "d3d9": "b", "dsound": "n"],
            appliedOverrides: ["d3dx9_43": "n,b"], previousLegacy: true)
        try JSONEncoder().encode(st).write(to: CompatibilityFixes.marker(.directx9Extras, g))
        var p = GameProfile(title: "Other settings", match: .init(exeName: "T.exe"), source: "folder", rating: .playable)
        p.graphics = .modern3D; p.program = #"C:\Games\T\Other.exe"#
        let plan = Profiles.plan(p, for: g)
        XCTAssertTrue(plan.skipped.contains { $0.contains("Older 3D games stays selected") })
        XCTAssertTrue(plan.skipped.contains { $0.contains("before changing the program") })
        try c.encoded().write(to: CustomGameConfig.url(in: g.contents))
        try Data("user changed DLL".utf8).write(to: original)
        XCTAssertThrowsError(try CompatibilityFixes.undo(.directx9Extras, for: g) { _ in })
        XCTAssertEqual(CustomGameConfig.load(contents: g.contents), c)
        XCTAssertEqual(try String(contentsOf: original), "user changed DLL")
        // Put the managed bytes back; Undo must restore the prior DLL while preserving d3d8 + audio.
        try Data("Microsoft DLL".utf8).write(to: original)
        try CompatibilityFixes.undo(.directx9Extras, for: g) { _ in }
        let restored = try XCTUnwrap(CustomGameConfig.load(contents: g.contents))
        let rules = CompatibilityFixes.overrides(restored.environment?["WINEDLLOVERRIDES"])
        XCTAssertNil(rules["d3dx9_43"])
        XCTAssertEqual(rules["d3d8"], "n"); XCTAssertEqual(rules["dsound"], "n")
        XCTAssertEqual(restored.legacyD3D9, true)
        XCTAssertEqual(try String(contentsOf: original), "original DLL")
        XCTAssertFalse(CompatibilityFixes.isInstalled(.directx9Extras, for: g))
    }

}
