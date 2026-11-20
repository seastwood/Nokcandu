import XCTest
@testable import NokcanduCore

/// End to end with a real engine, off unless NOKCANDU_ENGINE_FILE names one (an Apple silicon Wine app, .zip or
/// folder) and NOKCANDU_ENGINE_GAME names a game app to try it on (a clone of it is used; the game isn't touched).
/// Unit tests keep Nokcandu's support folder in a temporary place, so nothing real is installed either.
final class ExternalEngineIntegrationTests: XCTestCase {
    func testInstallAndSwitchAGame() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["NOKCANDU_ENGINE_FILE"], let gameApp = env["NOKCANDU_ENGINE_GAME"] else { throw XCTSkip("no engine given") }
        let probe = env["NOKCANDU_ENGINE_PROBE"]
        var lines: [String] = []
        let id = try await ExternalEngines.install(file: URL(fileURLWithPath: file), name: "Test Engine") { lines.append($0); print("install:", $0) }
        let m = try XCTUnwrap(RuntimeManager.manifest(for: id))
        XCTAssertEqual(m.selfTest, true, lines.joined(separator: "\n"))
        let layout = EngineLayout(contents: RuntimeManager.folder(for: id).appendingPathComponent("Contents"))
        XCTAssertEqual(layout.arch, .arm64); XCTAssertTrue(layout.isSealed); XCTAssertTrue(layout.runs64BitX86)
        let engine = try XCTUnwrap(WineSelection.parse(id))
        XCTAssertEqual(engine.external, id)
        XCTAssertTrue(WineSelection.versions(catalog: nil, cached: RuntimeManager.cachedRuntimes()).contains(engine))

        // A clone of the game (APFS: instant, no space).
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("engine-switch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let clone = dir.appendingPathComponent("Engine Test Copy.app")
        let cp = try Shell.run("/bin/cp", ["-c", "-R", gameApp, clone.path], timeout: 600)
        XCTAssertTrue(cp.ok, cp.combined)
        let g = try XCTUnwrap(GameLibrary.inspect(clone))
        print("game:", g.name, "was", g.wineVersion ?? "?")
        try await EngineUpdate.apply(g, runtimeID: id, explicitChoice: true) { print("apply:", $0) }
        let after = try XCTUnwrap(GameLibrary.inspect(clone))
        XCTAssertEqual(after.wineVersion, engine.versionString)
        XCTAssertTrue(EngineLayout(contents: after.contents).isSealed)
        GameApp.ensure(host: after.contents, wrappers: [.init(name: after.name, iconFrom: nil, isGame: true, microphone: false)], programs: [:], fallback: after.name)
        XCTAssertFalse(fm.fileExists(atPath: after.contents.appendingPathComponent("SharedSupport/\(GameApp.folderName)").path), "no wrapper for a sealed engine")
        if let probe {
            var e = ProcessInfo.processInfo.environment
            e["WINEPREFIX"] = after.prefix.path; e["WINEDEBUG"] = "-all"
            let wine = after.contents.appendingPathComponent("SharedSupport/wine/bin/wine").path
            let r = try await Shell.runAsync(wine, [probe], env: e, timeout: 300)
            print("probe:", r.combined)
            XCTAssertTrue(r.stdout.contains("native machine 0xaa64"), r.combined)
            _ = try? await Shell.runAsync(after.contents.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-k"], env: e, timeout: 60)
        }
        // Rolling back returns the game to its own engine.
        try await EngineUpdate.rollBack(after) { print("rollback:", $0) }
        XCTAssertEqual(GameLibrary.inspect(clone)?.wineVersion, g.wineVersion)
    }
}
