import XCTest
@testable import NokcanduCore

final class RecipeSettingsTests: XCTestCase {
    func fixture() throws -> InstalledGame {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-" + UUID().uuidString).resolvingSymlinksInPath()
        let app = root.appendingPathComponent("Recipe Game.app")
        for path in ["Contents/MacOS", "Contents/SharedSupport/GameFiles", "Contents/SharedSupport/prefix/drive_c/Games", "Contents/SharedSupport/wine/bin", "Contents/SharedSupport/renderer/d9vk/wine"] {
            try NokPaths.ensure(app.appendingPathComponent(path))
        }
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/generals-launcher")
        try FileManager.default.copyItem(at: resource, to: app.appendingPathComponent("Contents/MacOS/generals-launcher"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/Games/Zero Hour").path, withDestinationPath: "../../../GameFiles")
        let wine = app.appendingPathComponent("Contents/SharedSupport/wine/bin/wine")
        try "#!/bin/bash\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        return InstalledGame(appURL: app, name: "Recipe Game", recipe: RecipeCatalog.zeroHour, executableName: "generals-launcher")
    }
    func testRecipeMovesDedicatedContentAndKeepsWindowsPathAndCanMoveBack() throws {
        let g = try fixture(), fm = FileManager.default, root = g.appURL.deletingLastPathComponent()
        defer { try? fm.removeItem(at: root) }
        let source = try XCTUnwrap(GameMover.gameFilesFolder(g)), external = root.appendingPathComponent("External")
        try NokPaths.ensure(external)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("GeneralsOnlineZH.exe"))
        let launcher = try Data(contentsOf: g.launcherURL!)
        XCTAssertNil(GameMover.filesBlocker(g))
        let moved = try GameMover.moveFiles(g, to: external)
        XCTAssertEqual(moved.lastPathComponent, "Recipe Game")
        let windows = g.prefix.appendingPathComponent("drive_c/Games/Zero Hour/GeneralsOnlineZH.exe")
        XCTAssertEqual(try Data(contentsOf: windows), Data([1, 2, 3]))
        XCTAssertEqual(GameMover.externalFiles(g), moved)
        XCTAssertEqual(try Data(contentsOf: g.launcherURL!), launcher)
        try GameMover.moveFiles(g, to: nil)
        XCTAssertNil(GameMover.externalFiles(g))
        XCTAssertEqual(try Data(contentsOf: windows), Data([1, 2, 3]))
        XCTAssertFalse(fm.fileExists(atPath: moved.path))
    }
    func testBothRecipeLayoutsAndRelativeExternalLinks() throws {
        var g = try fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL.deletingLastPathComponent()) }
        g.recipe = RecipeCatalog.worms
        XCTAssertEqual(GameMover.gameFilesFolder(g)?.path, g.gameDirectory?.path)
        let source = try XCTUnwrap(GameMover.gameFilesFolder(g))
        try NokPaths.ensure(source.deletingLastPathComponent())
        let target = source.deletingLastPathComponent().appendingPathComponent("Other")
        try NokPaths.ensure(target)
        try Data([4]).write(to: target.appendingPathComponent("WA.exe"))
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "Other")
        try GameMover.moveFiles(g, to: nil)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("WA.exe")), Data([4]))
    }
    func testOverridesRetainRecipeOwnershipAndRejectManualEdits() throws {
        let g = try fixture(), fm = FileManager.default
        defer { try? fm.removeItem(at: g.appURL.deletingLastPathComponent()) }
        let original = try String(contentsOf: g.launcherURL!, encoding: .utf8)
        var value = RecipeSettings.Settings()
        value.arguments = #"-foo "two words" '$(touch /tmp/should-not-run)'"#
        value.environment = ["DOTNET_SYSTEM_GLOBALIZATION_USENLS": "0"]
        try RecipeSettings.save(value, for: g)
        let patched = try String(contentsOf: g.launcherURL!, encoding: .utf8)
        XCTAssertEqual(HelperPatch.strip(patched), original)
        XCTAssertEqual(DisplayController.launcherState(g), .original)
        XCTAssertNil(HelperPatch.add(to: patched, recipe: true))
        XCTAssertEqual(RecipeSettings.load(g), value)
        XCTAssertFalse(GameMicrophone.isOn(g))
        try GameMicrophone.set(true, for: g)
        XCTAssertTrue(GameMicrophone.isOn(g))
        try RecipeSettings.save(.init(), for: g)
        XCTAssertEqual(RecipeSettings.load(g), .init())
        let manual = patched + "# manual change\n"
        try manual.write(to: g.launcherURL!, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RecipeSettings.save(value, for: g))
        XCTAssertEqual(try String(contentsOf: g.launcherURL!, encoding: .utf8), manual)
    }
    func testActualShellArgumentsEnvironmentPerformanceAndProgramOverride() throws {
        let g = try fixture(), fm = FileManager.default, root = g.appURL.deletingLastPathComponent()
        defer { try? fm.removeItem(at: root) }
        let wine = g.support.appendingPathComponent("wine/bin/wine")
        try NokPaths.ensure(wine.deletingLastPathComponent())
        try #"""
#!/bin/bash
printf 'value=%s;perf=%s;mic=%s\n' "$RECIPE_TEST" "$DXVK_FRAME_RATE" "$NOKCANDU_NO_MICROPHONE"
printf '<%s>\n' "$@"
"""#.write(to: wine, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        var settings = RecipeSettings.Settings()
        settings.arguments = #"-flag "two words" '$(printf injected)'"#
        settings.environment = ["RECIPE_TEST": "$(printf injected); literal"]
        let env = try RecipeSettings.environment(settings, recipe: RecipeCatalog.zeroHour)
        try NokPaths.ensure(g.nokcanduState)
        try env.write(to: g.nokcanduState.appendingPathComponent("recipe-settings.env"), atomically: true, encoding: .utf8)
        var perf = Performance.Settings(); perf.fpsLimit = 42
        try Performance.apply(perf, for: g)
        let original = "#!/bin/bash\nset -euo pipefail\nSUPPORT=" + CustomGames.shellQuote(g.support.path) + "\nexport PATH=/usr/bin:/bin\n" + #""$SUPPORT/wine/bin/wine" 'original-program.exe' 'recipe required argument'"# + "\n"
        let script = RecipeSettings.patch(original), path = root.appendingPathComponent("test.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        var result = try Shell.run("/bin/bash", [path.path])
        XCTAssertTrue(result.ok, result.combined)
        XCTAssertTrue(result.stdout.contains("value=$(printf injected); literal;perf=42;mic=1"), result.stdout)
        XCTAssertTrue(result.stdout.contains("<original-program.exe>\n<recipe required argument>\n<-flag>\n<two words>\n<$(printf injected)>"), result.stdout)
        settings.program = #"C:\Games\Other.exe"#
        try RecipeSettings.environment(settings, recipe: RecipeCatalog.zeroHour).write(to: g.nokcanduState.appendingPathComponent("recipe-settings.env"), atomically: true, encoding: .utf8)
        result = try Shell.run("/bin/bash", [path.path])
        XCTAssertTrue(result.ok, result.combined)
        XCTAssertTrue(result.stdout.contains("<C:\\Games\\Other.exe>"), result.stdout)
        XCTAssertFalse(result.stdout.contains("original-program.exe"))
        // Empty overrides preserve all original recipe arguments too.
        try RecipeSettings.environment(.init(), recipe: RecipeCatalog.zeroHour).write(to: g.nokcanduState.appendingPathComponent("recipe-settings.env"), atomically: true, encoding: .utf8)
        result = try Shell.run("/bin/bash", [path.path])
        XCTAssertTrue(result.ok, result.combined)
        XCTAssertTrue(result.stdout.contains("<original-program.exe>\n<recipe required argument>"))
    }
    func testGraphicsKeepsNonGraphicsRecipeDependencies() throws {
        var settings = RecipeSettings.Settings(); settings.graphics = .compatible
        let text = try RecipeSettings.environment(settings, recipe: RecipeCatalog.zeroHour)
        XCTAssertTrue(text.contains("icu=n"))
        XCTAssertFalse(text.contains("d3d9=b"))
        XCTAssertTrue(text.contains("unset WINEDLLPATH_D9VK"))
        settings.environment = ["BAD-NAME": "x"]
        XCTAssertThrowsError(try RecipeSettings.environment(settings, recipe: RecipeCatalog.zeroHour))
    }
    func testProfileIncludesRecipeOverridesAndUndoRestoresThem() throws {
        let g = try fixture(), fm = FileManager.default
        defer { try? fm.removeItem(at: g.appURL.deletingLastPathComponent()) }
        var original = RecipeSettings.Settings(); original.arguments = "-old"; original.environment = ["WINEMSYNC": "0"]
        try RecipeSettings.save(original, for: g)
        let profile = Profiles.make(from: g, rating: .works, notes: nil, install: nil)
        XCTAssertEqual(profile.arguments, "-old")
        XCTAssertEqual(profile.environment?["WINEMSYNC"], "0")
        XCTAssertEqual(profile.match.exeName, RecipeCatalog.zeroHour.primaryExecutable)
        var changed = profile; changed.arguments = "-new"
        let snapshot = try Profiles.apply(changed, to: g, includeShared: false)
        XCTAssertEqual(RecipeSettings.load(g).arguments, "-new")
        try Profiles.undo(snapshot)
        XCTAssertEqual(RecipeSettings.load(g), original)
    }
}
