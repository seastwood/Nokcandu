import XCTest
@testable import NokcanduCore

final class HelperScopeTests: XCTestCase {
    func testLegacyRecipeUpgradesWithoutChangingFingerprint() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/generals-launcher")
        let original = try String(contentsOf: url, encoding: .utf8)
        var lines = original.components(separatedBy: "\n")
        let insertion = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("export PATH=") }) + 1
        lines.insert(contentsOf: HelperPatch.legacyBlock.components(separatedBy: "\n").dropLast(), at: insertion)
        let legacy = lines.joined(separator: "\n")
        let upgraded = try XCTUnwrap(HelperPatch.add(to: legacy))
        XCTAssertEqual(HelperPatch.strip(legacy), original)
        XCTAssertEqual(HelperPatch.strip(upgraded), original)
        XCTAssertNil(HelperPatch.add(to: upgraded))
        XCTAssertFalse(upgraded.contains(HelperPatch.globalExport))
        XCTAssertTrue(upgraded.contains(HelperPatch.scopedPrefix + #""$SUPPORT/wine/bin/wine" "#))
    }
    func testNativeToolsReceiveNoHelperWhileWineReceivesIt() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("helper scope " + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        try NokPaths.ensure(support.appendingPathComponent("wine/bin")); try NokPaths.ensure(support.appendingPathComponent("nokcandu"))
        try Data().write(to: support.appendingPathComponent("nokcandu/nokcandu-rawmouse.dylib"))
        let native = root.appendingPathComponent("native"), wine = support.appendingPathComponent("wine/bin/wine")
        try #"""
#!/bin/bash
[ -z "${NOK_TEST_INJECTION:-}" ] || exit 91
printf 'native-ok\n'
"""#.write(to: native, atomically: true, encoding: .utf8)
        try #"""
#!/bin/bash
[ "$NOK_TEST_INJECTION" = "$SUPPORT/nokcandu/nokcandu-rawmouse.dylib" ] || exit 92
printf 'wine-ok\n'
"""#.write(to: wine, atomically: true, encoding: .utf8)
        for tool in [native, wine] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path) }
        for exec in [false, true] {
            let original = "#!/bin/bash\nset -eu\nexport SUPPORT=" + CustomGames.shellQuote(support.path) + "\nexport PATH=/usr/bin:/bin\n" + CustomGames.shellQuote(native.path) + "\n" + (exec ? "exec " : "") + #""$SUPPORT/wine/bin/wine" --test"# + "\n"
            let script = try XCTUnwrap(HelperPatch.add(to: original)).replacingOccurrences(of: "DYLD_INSERT_LIBRARIES", with: "NOK_TEST_INJECTION")
            // Probe the environment assignment without loading a dummy dylib into the test process.
            let path = root.appendingPathComponent("launcher")
            try script.write(to: path, atomically: true, encoding: .utf8)
            let result = try Shell.run("/bin/bash", [path.path])
            XCTAssertTrue(result.ok, result.combined)
            XCTAssertTrue(result.stdout.contains("native-ok")); XCTAssertTrue(result.stdout.contains("wine-ok"))
        }
    }
    func testAllGeneratedLaunchersScopeHelperAndKeepWineRegistryEnvironment() {
        let config = CustomGameConfig(id: "t", name: "T", source: .folder, exe: #"C:\Games\T\T.exe"#, graphics: .classic3D)
        let custom = CustomGames.launcherScript(for: config), steam = SharedSteam.helperScript()
        for script in [custom, steam] {
            XCTAssertFalse(script.contains(HelperPatch.globalExport))
            XCTAssertTrue(script.contains(HelperPatch.scopedPrefix))
            XCTAssertEqual(HelperPatch.scopeWineLibrary(script), script)
        }
        XCTAssertTrue(steam.contains(HelperPatch.scopedPrefix + #""$WINE" "#))
        XCTAssertTrue(custom.contains(#"WANT="$(DYLD_INSERT_LIBRARIES="${NOKCANDU_HELPER_LIBRARY:-}";"#))
    }
    func testOwnedCustomLaunchersMigrateButUserEditsAreKept() throws {
        let fm = FileManager.default
        var game = try ProfileCompletenessTests().fixture()
        defer { try? fm.removeItem(at: game.appURL) }
        let launcher = game.contents.appendingPathComponent("MacOS/" + CustomGames.launcherName)
        let legacy = "#!/bin/bash\n" + HelperPatch.globalExport + "\n"
        try legacy.write(to: launcher, atomically: true, encoding: .utf8)
        var config = try XCTUnwrap(game.custom); config.launcherSHA = Hashing.sha256(data: Data(legacy.utf8))
        try config.encoded().write(to: CustomGameConfig.url(in: game.contents)); game.custom = config
        XCTAssertEqual(HelperPatch.refresh([game]), [game.name])
        let migrated = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertFalse(migrated.contains(HelperPatch.globalExport))
        XCTAssertEqual(CustomGameConfig.load(contents: game.contents)?.exe, config.exe)
        try legacy.write(to: launcher, atomically: true, encoding: .utf8)
        XCTAssertEqual(HelperPatch.refresh([try XCTUnwrap(GameLibrary.inspect(game.appURL))]), [])
        XCTAssertEqual(try String(contentsOf: launcher, encoding: .utf8), legacy)
    }
}
