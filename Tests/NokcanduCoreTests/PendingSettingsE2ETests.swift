import XCTest
@testable import NokcanduCore

final class PendingSettingsE2ETests: XCTestCase {
    func testWineChoiceDefersDuringAnActiveProgramThenAppliesWithoutReopeningGame() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E"] == "1" else { throw XCTSkip("set NOKCANDU_E2E=1") }
        let fm = FileManager.default, source = NokPaths.gameAppsFolder.appendingPathComponent("Worms Armageddon.app")
        guard fm.fileExists(atPath: source.path) else { throw XCTSkip("no clone source") }
        let root = fm.temporaryDirectory.appendingPathComponent("nok-pending-wine-" + UUID().uuidString)
        let app = root.appendingPathComponent("Pending Settings Test.app")
        try fm.cloneItem(at: source, to: app)
        PendingSettings.stateRootOverride = root.appendingPathComponent("Saved Requests")
        defer { PendingSettings.stateRootOverride = nil; if fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) } }
        try? fm.removeItem(at: app.appendingPathComponent("Contents/SharedSupport/Logs/game.lock"))
        var game = try XCTUnwrap(GameLibrary.inspect(app))
        if EngineUpdate.state(for: game)?.status == .trying { try EngineUpdate.keep(game) }
        fputs("clone inspected\n", stderr)
        let before = try Hashing.sha256(file: game.support.appendingPathComponent("wine/bin/wine"))
        let env = WineTools.environment(contents: game.contents)
        let wine = game.support.appendingPathComponent("wine/bin/wine").path
        fputs("starting temporary Windows command\n", stderr)
        let active = Task { try await Shell.runAsync(wine, ["cmd", "/c", "ping -t 127.0.0.1"], env: env, timeout: 40) }
        for _ in 0..<80 {
            if PendingSettings.activity(for: game) == .active { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(PendingSettings.activity(for: game), .active)
        fputs("active session detected\n", stderr)
        let id = try await WineSelection.prepare(WineSelection.minimum) { print($0) }
        try PendingSettings.save(.wine(id), title: "Wine version", for: game)
        fputs("request saved\n", stderr)
        let deferred = try await PendingSettings.apply(for: game)
        XCTAssertEqual(deferred, .deferred)
        XCTAssertEqual(try Hashing.sha256(file: game.support.appendingPathComponent("wine/bin/wine")), before)
        XCTAssertEqual(PendingSettings.entries(for: game).count, 1)
        fputs("deferred confirmed; stopping temporary session\n", stderr)
        try await WineTools.stopAll(for: game)
        _ = try? await active.value
        fputs("applying while closed\n", stderr)
        let outcome = try await PendingSettings.apply(for: game) { print($0) }
        XCTAssertEqual(outcome, .applied)
        game = try XCTUnwrap(GameLibrary.inspect(app))
        XCTAssertEqual(EngineUpdate.current(game), WineSelection.minimum)
        XCTAssertEqual(GameLauncher.runState(of: game), .notRunning)
        XCTAssertTrue(PendingSettings.entries(for: game).isEmpty)
        try await EngineUpdate.rollBack(game) { print($0) }
        XCTAssertEqual(try Hashing.sha256(file: game.support.appendingPathComponent("wine/bin/wine")), before)
    }
}
