import XCTest
@testable import NokcanduCore

/// Opt-in (NOKCANDU_E2E=1, `touch .e2e-engine`): clones Worms Armageddon.app to a temp folder, moves the clone
/// to the newest engine, checks Wine runs, rolls back, and checks the clone is exactly as before.
/// Never touches the real game apps (the clone is APFS copy-on-write and removed afterwards).
final class EngineUpdateE2ETests: XCTestCase {
    func testTryAndRollBack() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1" else { throw XCTSkip("set NOKCANDU_E2E=1") }
        let fm = FileManager.default
        let src = NokPaths.gameAppsFolder.appendingPathComponent("Worms Armageddon.app")
        guard fm.fileExists(atPath: src.path) else { throw XCTSkip("no Worms app to clone") }
        let tmp = fm.temporaryDirectory.appendingPathComponent("nokcandu-engine-e2e-\(UUID().uuidString.prefix(6))")
        let app = tmp.appendingPathComponent("Engine Test.app")
        try fm.cloneItem(at: src, to: app)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.removeItem(at: app.appendingPathComponent("Contents/SharedSupport/Logs/game.lock"))

        let g = try XCTUnwrap(GameLibrary.inspect(app))
        let wine = app.appendingPathComponent("Contents/SharedSupport/wine/bin/wine")
        let origSHA = try Hashing.sha256(file: wine)
        let origSystemReg = try Hashing.sha256(file: g.prefix.appendingPathComponent("system.reg"))
        let origVersion = g.wineVersion
        print("Start: \(origVersion ?? "?")")

        let cat = try await Updates.check()
        let latest = try XCTUnwrap(cat.latestEngine?.version)
        let template = cat.latestTemplate?.version ?? .tested
        print("Newest: \(latest) + template \(template)")
        var id: String = ""
        var target = latest
        do { id = try await RuntimeManager.build(engine: latest, template: template, catalog: cat) { print($0) } }
        catch {
            print("Newest engine rejected by self-test: \(error.localizedDescription)")
            XCTAssertTrue(EngineSelfTests.failed(RuntimeManager.runtimeID(engine: latest, template: template)))
            XCTAssertFalse(RuntimeManager.isCached(id: RuntimeManager.runtimeID(engine: latest, template: template)))
            XCTAssertEqual(try Hashing.sha256(file: wine), origSHA)
            // Still exercise the switch + roll back machinery with the tested runtime from the cache.
            guard RuntimeManager.isCached(id: RecipeCatalog.sikarugirWine10.id) else { return }
            target = .tested
            id = RecipeCatalog.sikarugirWine10.id
        }
        XCTAssertTrue(RuntimeManager.isCached(id: id))

        try await EngineUpdate.apply(g, runtimeID: id) { print($0) }
        let g2 = try XCTUnwrap(GameLibrary.inspect(app))
        XCTAssertEqual(EngineUpdate.current(g2), target)
        XCTAssertEqual(EngineUpdate.state(for: g2)?.status, .trying)
        XCTAssertTrue(fm.fileExists(atPath: EngineUpdate.rollbackDir(g2.contents).path))

        // The new engine actually runs Windows programs in this prefix.
        let r = try await Shell.runAsync(wine.path, ["cmd", "/c", "ver"], env: WineTools.environment(contents: g2.contents), timeout: 300)
        print("ver: \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) status \(r.status)")
        XCTAssertTrue(r.stdout.contains("Windows"), r.combined)
        _ = try? await Shell.runAsync(g2.contents.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-k"],
                                      env: WineTools.environment(contents: g2.contents), timeout: 60)

        try await EngineUpdate.rollBack(g2) { print($0) }
        let g3 = try XCTUnwrap(GameLibrary.inspect(app))
        XCTAssertEqual(g3.wineVersion, origVersion)
        XCTAssertEqual(try Hashing.sha256(file: wine), origSHA)
        XCTAssertEqual(try Hashing.sha256(file: g3.prefix.appendingPathComponent("system.reg")), origSystemReg)
        XCTAssertNil(EngineUpdate.state(for: g3))
        XCTAssertFalse(fm.fileExists(atPath: EngineUpdate.rollbackDir(g3.contents).path))
        print("Rolled back to \(g3.wineVersion ?? "?") — identical to the start.")
    }
}
