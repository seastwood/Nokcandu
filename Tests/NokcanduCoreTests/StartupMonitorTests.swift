import XCTest
@testable import NokcanduCore

final class StartupMonitorTests: XCTestCase {
    func testEarlyFailurePendingPermissionsHandoffsAndStaleReceipts() {
        let date = Date(timeIntervalSince1970: 1000)
        func check(_ receipt: StartupMonitor.Receipt?, elapsed: Double = 4, running: Bool = false, window: Bool = false, handoff: Bool = false) -> StartupMonitor.Observation {
            StartupMonitor.evaluate(name: "Game", receipt: receipt, since: date, elapsed: elapsed, running: running, window: window, handoff: handoff, detail: "Diagnostic detail")
        }
        let failed = StartupMonitor.Receipt(startedAt: 1000, phase: "exited", exitCode: 1, pid: 100)
        XCTAssertEqual(check(failed), .failed("Game couldn't start (launcher exit 1). Diagnostic detail"))
        XCTAssertEqual(check(failed, window: true), .opened)
        let waiting = StartupMonitor.Receipt(startedAt: 1000, phase: "starting", exitCode: 0, pid: 100)
        XCTAssertEqual(check(waiting), .pending)
        if case .waiting = check(waiting, elapsed: 20) {} else { XCTFail("An authorization dialog must not be reported as a failed game") }
        if case .waiting = check(nil, elapsed: 20) {} else { XCTFail("A launch macOS is still checking must not be reported as failed") }
        if case .failed = check(nil, elapsed: 61) {} else { XCTFail("A launch that never starts is reported") }
        let old = StartupMonitor.Receipt(startedAt: 900, phase: "exited", exitCode: 1, pid: 100)
        XCTAssertEqual(check(old), .pending)
        let exited = StartupMonitor.Receipt(startedAt: 1000, phase: "exited", exitCode: 0, pid: 100)
        XCTAssertEqual(check(exited, handoff: true), .pending)
        XCTAssertEqual(check(exited, running: true), .pending)
        XCTAssertEqual(check(exited), .failed("Game closed before startup was confirmed. Diagnostic detail"))
    }
    func testPrivateBootstrapChildrenRemainGameProcesses() {
        XCTAssertTrue(GameLauncher.privateGameCommand(#"C:\Games\Example\realgame.exe -run"#))
        XCTAssertTrue(GameLauncher.privateGameCommand("c:/Games/Example/child.exe"))
        XCTAssertFalse(GameLauncher.privateGameCommand(#"C:\windows\system32\services.exe"#))
        XCTAssertFalse(GameLauncher.privateGameCommand("/engine/bin/wineserver"))
        var game = InstalledGame(appURL: URL(fileURLWithPath: "/tmp/Example.app"), name: "Example")
        XCTAssertTrue(GameLauncher.hasPrivateGamePrefix(game))
        game.hosted = HostedGameLink(hostApp: "/tmp/EA.app", launcher: .ea, id: "test", name: "Example", exe: nil)
        XCTAssertFalse(GameLauncher.hasPrivateGamePrefix(game))
    }
    func testKnownDisplayCopiesAreIncludedInGameWindowMatching() throws {
        var game = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        game.custom?.bf1942MenuCopy = true
        XCTAssertTrue(StuckGames.programs(of: game).contains(BF1942DisplayFix.copyName.lowercased()))
        XCTAssertTrue(StuckGames.programs(of: game).contains(BF1942DisplayFix.restartCopyName.lowercased()))
    }

    func testStoreClientThatNeverStartsTheGameIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-stall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var g = InstalledGame(appURL: root.appendingPathComponent("Overwatch.app"), name: "Overwatch")
        g.battleNet = BattleNetLink(hostApp: root.appendingPathComponent("Battle.net.app").path, uid: "prometheus", code: "Pro", name: "Overwatch")
        try FileManager.default.createDirectory(at: g.logs, withIntermediateDirectories: true)
        let since = Date().addingTimeInterval(-200)
        let receipt = StartupMonitor.Receipt(startedAt: since.timeIntervalSince1970 + 1, phase: "exited", exitCode: 0, pid: 99_999)
        let file = g.logs.appendingPathComponent("launcher-status.json")
        try JSONEncoder().encode(receipt).write(to: file)

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: file.path)
        if case .stalled = StartupMonitor.observe(g, since: since, elapsed: 200) { XCTFail("too soon after the hand-off") }

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: file.path)
        XCTAssertEqual(StartupMonitor.observe(g, since: since, elapsed: 200),
                       .stalled("Battle.net is open but hasn't started Overwatch. It may be updating the game or waiting for you in its window (an update, a sign-in or its own Play button)."))
    }
}
