import XCTest
@testable import NokcanduCore

/// Opt-in: the official runtime cache and a disposable clone; the original game stays untouched.
final class WineSelectionE2ETests: XCTestCase {
    func testHistoricalSikarugirSelectionAndExactRollback() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1" else { throw XCTSkip("set NOKCANDU_E2E=1") }
        let fm = FileManager.default, source = NokPaths.gameAppsFolder.appendingPathComponent("Worms Armageddon.app")
        guard fm.fileExists(atPath: source.path) else { throw XCTSkip("no clone source") }
        let root = fm.temporaryDirectory.appendingPathComponent("nok-wine-choice-" + UUID().uuidString)
        let app = root.appendingPathComponent("Wine Selection Test.app")
        try fm.cloneItem(at: source, to: app)
        defer { try? fm.removeItem(at: root) }
        try? fm.removeItem(at: app.appendingPathComponent("Contents/SharedSupport/Logs/game.lock"))
        var game = try XCTUnwrap(GameLibrary.inspect(app))
        if EngineUpdate.state(for: game)?.status == .trying { try EngineUpdate.keep(game); game = try XCTUnwrap(GameLibrary.inspect(app)) }
        let originalWine = try Hashing.sha256(file: game.support.appendingPathComponent("wine/bin/wine"))
        let originalRegistry = try Hashing.sha256(file: game.prefix.appendingPathComponent("system.reg"))
        let originalVersion = game.wineVersion
        let id = try await WineSelection.prepare(WineSelection.minimum) { print($0) }
        XCTAssertEqual(RuntimeManager.manifest(for: id)?.selfTest, true)
        try EngineUpdate.setHeld(game, true)
        try await EngineUpdate.apply(game, runtimeID: id, explicitChoice: true) { print($0) }
        game = try XCTUnwrap(GameLibrary.inspect(app))
        XCTAssertEqual(EngineUpdate.current(game), WineSelection.minimum)
        XCTAssertTrue(EngineUpdate.isHeld(game))
        let result = try await Shell.runAsync(game.support.appendingPathComponent("wine/bin/wine").path, ["cmd", "/c", "ver"], env: WineTools.environment(contents: game.contents), timeout: 120)
        XCTAssertTrue(result.stdout.contains("Windows"), "The selected Sikarugir engine must run Windows programs")
        _ = try? await Shell.runAsync(game.support.appendingPathComponent("wine/bin/wineserver").path, ["-k"], env: WineTools.environment(contents: game.contents), timeout: 30)
        try await EngineUpdate.rollBack(game) { print($0) }
        game = try XCTUnwrap(GameLibrary.inspect(app))
        XCTAssertEqual(game.wineVersion, originalVersion)
        XCTAssertEqual(try Hashing.sha256(file: game.support.appendingPathComponent("wine/bin/wine")), originalWine)
        XCTAssertEqual(try Hashing.sha256(file: game.prefix.appendingPathComponent("system.reg")), originalRegistry)
        print("Selected Wine 10.0 and rolled back the isolated clone exactly.")
    }
}

extension WineSelectionE2ETests {
    func testFreshRecipeUsesSelectedSikarugirAndItsBuiltinDLLs() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1" else { throw XCTSkip("set NOKCANDU_E2E=1") }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nok-wine-fresh-" + UUID().uuidString)
        let app = root.appendingPathComponent("Fresh Selection Test.app")
        try NokPaths.ensure(app)
        defer { try? fm.removeItem(at: root) }
        _ = try await WineSelection.prepare(WineSelection.minimum) { print($0) }
        var state = InstallState(installID: "not-persisted-" + UUID().uuidString, recipeID: RecipeCatalog.zeroHour.id, targetApp: app.path)
        state.createdTarget = true
        try WineSelection.freeze(&state, choice: WineSelection.minimum)
        let context = InstallContext(recipe: RecipeCatalog.zeroHour, state: state, library: [], log: { print($0) })
        try await ZeroHourInstall.CreateApp().run(context)
        try await ZeroHourInstall.Prefix().run(context)
        XCTAssertTrue(ZeroHourInstall.Prefix().isDone(context))
        XCTAssertTrue(ZeroHourInstall.Graphics().systemDLLsOriginal(context), "Recipe checks must use the selected Sikarugir engine's builtin D3D files")
        let installed = InstalledGame(appURL: app, name: "Fresh selection")
        XCTAssertEqual(EngineUpdate.state(for: installed)?.runtimeID, WineSelection.spec(for: WineSelection.minimum).id)
        _ = try? await Shell.runAsync(context.support.appendingPathComponent("wine/bin/wineserver").path, ["-k"], env: context.wineEnvironment, timeout: 30)
    }
}
