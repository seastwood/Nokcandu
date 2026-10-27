import XCTest
@testable import NokcanduCore

final class CompatibilityFixTests: XCTestCase {
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
        p.fixes = CompatibilityFix.allCases.map(\.id)
        XCTAssertEqual(p.problems, [])
        XCTAssertEqual(try GameProfile.parse("```json\n" + p.json() + "\n```"), p)
        p.fixes = ["https://example.com/arbitrary.dll"]
        XCTAssertFalse(p.problems.isEmpty)
        let shared = InstalledGame(appURL: URL(fileURLWithPath: "/tmp/T.app"), name: "T", custom:
            CustomGameConfig(id: "t", name: "T", source: .steamLibrary, exe: "T.exe", graphics: .classic3D))
        for fix in CompatibilityFix.allCases { XCTAssertNotNil(CompatibilityFixes.unavailable(fix, for: shared)) }
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
