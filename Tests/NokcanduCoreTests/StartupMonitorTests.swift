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
}
