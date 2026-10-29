import XCTest
@testable import NokcanduCore

final class SettingsRestartTests: XCTestCase {
    func testRunningProbeAndApplyWaitForHostThenReopenOnSuccessAndFailure() async throws {
        let (host, _) = try EASetupRecoveryTests().fixture()
        defer { try? FileManager.default.removeItem(at: host.appURL) }
        let server = host.support.appendingPathComponent("wine/bin/wineserver")
        let events = host.appURL.appendingPathComponent("events")
        let script = "#!/bin/sh\necho \"$1\" >> " + CustomGames.shellQuote(events.path) + "\nexit 0\n"
        try Data(script.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let idle = await WineTools.environmentIsRunning(for: host)
        XCTAssertFalse(idle)
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: server)
        let active = await WineTools.environmentIsRunning(for: host)
        XCTAssertTrue(active)
        try Data(script.utf8).write(to: server)
        try Data().write(to: events)
        var steps: [String] = []
        try await WineTools.applySettings(for: host, restart: true, edit: { _ in
            let text = try String(contentsOf: events, encoding: .utf8)
            XCTAssertEqual(text, "-k\n-w\n")
            steps.append("edit")
        }, reopen: { _ in steps.append("reopen") })
        XCTAssertEqual(steps, ["edit", "reopen"])
        do {
            try await WineTools.applySettings(for: host, restart: true, edit: { _ in throw NokError("test failure") }, reopen: { _ in steps.append("recovered") })
            XCTFail("Must report failure")
        } catch { XCTAssertEqual(error.localizedDescription, "test failure") }
        XCTAssertEqual(steps.last, "recovered")
    }
    func testRestartClosesOrphanedWineWithoutTouchingOtherPrograms() async throws {
        let (host, _) = try EASetupRecoveryTests().fixture()
        defer { try? FileManager.default.removeItem(at: host.appURL) }
        let source = host.appURL.appendingPathComponent("wait.c")
        try "#include <unistd.h>\nint main(void){for(;;)pause();}\n".write(to: source, atomically: true, encoding: .utf8)
        let wine = host.support.appendingPathComponent("wine/bin/wine")
        let compiled = try Shell.run("/usr/bin/clang", [source.path, "-o", wine.path])
        XCTAssertTrue(compiled.ok, compiled.combined)
        let server = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try "#!/bin/sh\nexit 0\n".write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let orphan = Process(); orphan.executableURL = wine
        try orphan.run()
        defer { if orphan.isRunning { orphan.terminate(); orphan.waitUntilExit() } }
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        XCTAssertTrue(WineTools.owns(pid: orphan.processIdentifier, contents: host.contents))
        XCTAssertFalse(WineTools.owns(pid: unrelated.processIdentifier, contents: host.contents))
        XCTAssertFalse(WineTools.owns(executable: host.contents.path + "-other/SharedSupport/wine/bin/wine", contents: host.contents))
        let active = await WineTools.environmentIsRunning(for: host)
        XCTAssertTrue(active, "A native orphan must still trigger the restart confirmation")
        try await WineTools.stopAll(for: host)
        orphan.waitUntilExit()
        XCTAssertFalse(orphan.isRunning)
        XCTAssertTrue(unrelated.isRunning)
    }
    func testStartupSelectsLastGameAndIgnoresLauncherAndSidebarOrder() throws {
        let (ea, _) = try EASetupRecoveryTests().fixture()
        defer { try? FileManager.default.removeItem(at: ea.appURL) }
        let army = InstalledGame(appURL: URL(fileURLWithPath: "/tmp/Army.app"), name: "Army Men")
        let bf = InstalledGame(appURL: URL(fileURLWithPath: "/tmp/BC2.app"), name: "Battlefield")
        XCTAssertEqual(LibraryOrganizer.mostRecentlyPlayed([army, ea, bf], dates: [army.id: Date(timeIntervalSince1970: 1), bf.id: Date(timeIntervalSince1970: 10), ea.id: Date(timeIntervalSince1970: 100)])?.id, bf.id)
        XCTAssertEqual(LibraryOrganizer.mostRecentlyPlayed([bf, army], dates: [:])?.id, army.id)
        XCTAssertEqual(LibraryOrganizer.mostRecentlyPlayed([ea], dates: [:])?.id, ea.id)
        let history = LibraryOrganizer.startupHistory([army, bf], recorded: [LibraryOrganizer.key(bf): Date(timeIntervalSince1970: 10)],
            legacy: [army.id: Date(timeIntervalSince1970: 100)])
        XCTAssertNil(history[army.id])
        XCTAssertEqual(LibraryOrganizer.mostRecentlyPlayed([army, bf], dates: history)?.id, bf.id)

    }
}
