import XCTest
@testable import NokcanduCore

/// Opt-in (NOKCANDU_E2E=1): runs the general installer for real with the "Existing game folder"
/// source, using the Worms game folder as sample content, into a scratch apps folder, then removes it.
final class E2ETests: XCTestCase {
    func testFolderInstallEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1" else { throw XCTSkip("set NOKCANDU_E2E=1") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sample = home.appendingPathComponent("Applications/Sikarugir/Worms Armageddon.app/Contents/SharedSupport/prefix/drive_c/Games/Worms Armageddon")
        guard FileManager.default.fileExists(atPath: sample.path) else { throw XCTSkip("no sample folder") }
        let apps = home.appendingPathComponent("nokcandu/.e2e-apps")
        try? FileManager.default.removeItem(at: apps)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        setenv("NOKCANDU_GAME_APPS", apps.path, 1)
        defer { unsetenv("NOKCANDU_GAME_APPS") }

        let lib = GameLibrary.scan(folders: [home.appendingPathComponent("Applications/Sikarugir")])
        let ex = try InstallExecutor.makeCustom(name: "E2E Worms", source: .folder, library: lib) { print("[e2e]", $0) }
        ex.setInput("folderPath", sample.path)
        await ex.runUntilBlocked()
        XCTAssertEqual(ex.nextStage?.info.id, "exe", "should stop to choose the program")
        let candidates = CustomGames.findExecutables(prefix: ex.ctx.prefix, nameHint: "Worms Armageddon")
        print("[e2e] candidates:", candidates.map { "\($0.windowsPath) \($0.score)" })
        let wa = try XCTUnwrap(candidates.first { $0.url.lastPathComponent.lowercased() == "wa.exe" })
        XCTAssertEqual(candidates.first?.id, wa.id, "WA.exe should rank first")
        ex.setInput("exe", wa.windowsPath)
        await ex.runUntilBlocked()
        XCTAssertEqual(ex.nextStage?.info.id, "playtest")

        let game = try XCTUnwrap(GameLibrary.inspect(ex.ctx.targetApp))
        let cfg = try XCTUnwrap(game.custom)
        print("[e2e] graphics:", cfg.graphics, cfg.detectedAPIs, "64bit:", cfg.is64Bit as Any, "icon:", game.iconURL as Any)
        XCTAssertNotNil(game.iconURL)
        let pre = await GameLauncher.preflight(game)
        XCTAssertTrue(pre.ok, pre.combined)
        let diag = Diagnostics.collect(game)
        for c in diag.checks where c.status != .info { print("[e2e] diag", c.status, c.title, c.detail) }
        XCTAssertFalse(diag.checks.contains { $0.status == .failure })

        // Switch graphics and back: launcher regenerated, journaled, still valid.
        var c2 = cfg; c2.graphics = .compatible
        try CustomGames.save(c2, to: game)
        let g2 = try XCTUnwrap(GameLibrary.inspect(ex.ctx.targetApp))
        XCTAssertEqual(g2.custom?.graphics, .compatible)
        let pre2 = await GameLauncher.preflight(g2)
        XCTAssertTrue(pre2.ok, pre2.combined)

        // Cinematic fix: download (pinned), install, registry check, then undo.
        try await CinematicFix.install(for: g2, log: { print("[e2e] lav", $0) })
        XCTAssertTrue(CinematicFix.isPresent(for: g2))
        XCTAssertEqual(CinematicFix.state(for: g2)?.arches, [.x86])
        try await CinematicFix.undo(for: g2, log: { print("[e2e] lav", $0) })
        XCTAssertFalse(CinematicFix.isPresent(for: g2))
        let reg = try String(contentsOf: g2.prefix.appendingPathComponent("system.reg"), encoding: .utf8)
        XCTAssertFalse(reg.contains("LAV Filters\\\\LAVSplitter.ax"), "unregistered")

        print("[e2e] remove:", ex.removeUnfinishedInstall())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ex.ctx.targetApp.path))
        try? FileManager.default.removeItem(at: apps)
    }
}
