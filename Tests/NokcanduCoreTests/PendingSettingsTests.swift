import XCTest
@testable import NokcanduCore

final class PendingSettingsTests: XCTestCase {
    var stateRoot: URL!
    override func setUpWithError() throws {
        stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pending-state-tests-" + UUID().uuidString)
        PendingSettings.stateRootOverride = stateRoot
    }
    override func tearDownWithError() throws {
        PendingSettings.stateRootOverride = nil
        if FileManager.default.fileExists(atPath: stateRoot.path) { try FileManager.default.removeItem(at: stateRoot) }
    }
    func testActivitySeparatesIdleServicesFromGamesAndUnknownState() {
        XCTAssertEqual(PendingSettings.activity(reliable: true, ownedCommands: []), .closed)
        XCTAssertEqual(PendingSettings.activity(reliable: false, ownedCommands: []), .unknown)
        XCTAssertEqual(PendingSettings.activity(reliable: true, ownedCommands: [#"C:\windows\system32\services.exe"#, #"C:\windows\explorer.exe"#, "/Applications/My Game.app/Contents/SharedSupport/wine/bin/wineserver -p"]), .backgroundOnly)
        for command in [#"C:\Games\The Falconeer\TheFalconeer.exe"#, #"C:\windows\system32\cmd.exe"#, "unknown program"] {
            XCTAssertEqual(PendingSettings.activity(reliable: true, ownedCommands: [command]), .active)
        }
    }
    func testSavingCoalescesOnlySameSettingAndPreservesActualVersion() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try PendingSettings.save(.wine("old-runtime"), title: "Wine", for: f.host)
        try PendingSettings.save(.audioBuffer(20), title: "Audio buffer", for: f.host)
        try PendingSettings.save(.wine("new-runtime"), title: "Wine", for: f.host)
        let entries = try PendingSettings.read(f.host.contents)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { if case .wine("new-runtime") = $0.change { return true }; return false })
        XCTAssertEqual(GameLibrary.inspect(f.host.appURL)?.wineVersion, f.host.wineVersion)
        XCTAssertEqual(PendingSettings.audioBuffer(for: f.host), 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.files.path))
    }
    func testActiveOrUnknownSessionDefersWithoutExecutingOrStopping() async throws {
        for activity in [PendingSettings.Activity.active, .unknown] {
            let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            try PendingSettings.save(.audioBuffer(20), title: "Audio buffer", for: f.host)
            var stopped = false, executed = false
            let outcome = try await PendingSettings.applyPending(for: f.host, observe: { _ in activity }, stopIdle: { _ in stopped = true }, execute: { _, _ in executed = true })
            XCTAssertEqual(outcome, .deferred); XCTAssertFalse(stopped); XCTAssertFalse(executed)
            XCTAssertEqual(try PendingSettings.read(f.host.contents).count, 1)
        }
    }
    func testIdleServicesAreStoppedWithoutReopeningTheGame() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try PendingSettings.save(.audioBuffer(20), title: "Audio buffer", for: f.host)
        var events: [String] = []
        let outcome = try await PendingSettings.applyPending(for: f.host, observe: { _ in .backgroundOnly }, stopIdle: { _ in events.append("stop idle services") }, execute: { _, _ in events.append("apply") })
        XCTAssertEqual(outcome, .applied); XCTAssertEqual(events, ["stop idle services", "apply"])
        XCTAssertTrue(try PendingSettings.read(f.host.contents).isEmpty)
    }
    func testFailureRetainsDesiredChangeForRetryOrDiscard() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try PendingSettings.save(.windowStyle(.borderless), title: "Window style", for: f.host)
        do {
            _ = try await PendingSettings.applyPending(for: f.host, observe: { _ in .closed }, stopIdle: { _ in XCTFail("Not needed") }, execute: { _, _ in throw NokError("Fixture failure") })
            XCTFail("Expected a failed application")
        } catch {}
        XCTAssertEqual(try PendingSettings.read(f.host.contents).count, 1)
        try PendingSettings.discard(for: f.host)
        XCTAssertTrue(try PendingSettings.read(f.host.contents).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.files.path))
    }
    func testRealPerformanceApplicationPersistsAcrossReloadAndDoesNotStartWine() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var settings = Performance.Settings(); settings.fpsCounter = true
        try PendingSettings.save(.performance(settings), title: "Performance", for: f.host)
        XCTAssertEqual(PendingSettings.performance(for: f.host), settings)
        let reloaded = try XCTUnwrap(GameLibrary.inspect(f.host.appURL))
        let outcome = try await PendingSettings.apply(for: reloaded)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(Performance.settings(for: reloaded), settings)
        XCTAssertTrue(PendingSettings.entries(for: reloaded).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.logs.appendingPathComponent("game.lock").path))
    }
    func testQueuedChangeTravelsWithMovedPrivateApp() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var settings = Performance.Settings(); settings.fpsCounter = true
        try PendingSettings.save(.performance(settings), title: "Performance", for: f.host)
        XCTAssertEqual(try PendingSettings.read(f.host.contents).first?.gamePath, ".")
        let moved = f.root.appendingPathComponent("Moved Host.app")
        try FileManager.default.moveItem(at: f.host.appURL, to: moved)
        let game = try XCTUnwrap(GameLibrary.inspect(moved))
        let applied = try await PendingSettings.apply(for: game)
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(Performance.settings(for: game), settings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.files.path))
    }
    func testPreviewPreservesLiveMicrophoneAndDoesNotOverwriteConfiguration() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var desired = try XCTUnwrap(f.host.custom); desired.graphics = .modern3D; desired.microphone = false
        try PendingSettings.save(.custom(desired, force: false, changeProgram: false), title: "Game Settings", for: f.host)
        var live = desired; live.graphics = .classic3D; live.microphone = true
        try live.encoded().write(to: CustomGameConfig.url(in: f.host.contents))
        let actual = try XCTUnwrap(GameLibrary.inspect(f.host.appURL))
        let preview = PendingSettings.preview(actual)
        XCTAssertEqual(preview.custom?.graphics, .modern3D)
        XCTAssertEqual(preview.custom?.microphone, true)
        XCTAssertEqual(GameLibrary.inspect(f.host.appURL)?.custom?.graphics, .classic3D)
    }
    func testStaleReusedPIDCannotMarkAnUnrelatedProgramAsThisGame() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try NokPaths.ensure(f.host.logs.appendingPathComponent("game.lock"))
        try String(getpid()).write(to: f.host.logs.appendingPathComponent("game.lock/pid"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GameLauncher.runState(of: f.host, processes: [(getpid(), "/usr/bin/unrelated")]), .notRunning)
        XCTAssertFalse(GameLauncher.ownsLock(pid: getpid(), game: f.host, processes: [(getpid(), "/usr/bin/unrelated")]))
    }
    func testCorruptQueuedRequestIsPreservedAndReported() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = PendingSettings.directory(f.host.contents); try NokPaths.ensure(directory)
        let file = directory.appendingPathComponent("corrupt.json"); try Data("broken".utf8).write(to: file)
        do { _ = try await PendingSettings.apply(for: f.host); XCTFail("Corrupt settings must not be silently discarded") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
}

extension PendingSettingsTests {
    func testNewerSaveDuringApplicationIsAppliedWithoutLosingIt() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try PendingSettings.save(.audioBuffer(20), title: "Audio buffer", for: f.host)
        var values: [Int] = []
        let result = try await PendingSettings.applyPending(for: f.host, observe: { _ in .closed }, stopIdle: { _ in XCTFail("Not needed") }, execute: { entry, _ in
            guard case .audioBuffer(let value) = entry.change else { return XCTFail("Wrong operation") }
            values.append(value)
            if value == 20 { try PendingSettings.save(.audioBuffer(40), title: "Audio buffer", for: f.host) }
        })
        XCTAssertEqual(result, .applied); XCTAssertEqual(values, [20, 40])
        XCTAssertTrue(PendingSettings.entries(for: f.host).isEmpty)
    }
    func testSecondApplicationCannotExecuteTheSameRequest() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try PendingSettings.save(.audioBuffer(20), title: "Audio buffer", for: f.host)
        let result = try await PendingSettings.applyPending(for: f.host, observe: { _ in .closed }, stopIdle: { _ in XCTFail("Not needed") }, execute: { _, _ in
            let second = try await PendingSettings.applyPending(for: f.host, observe: { _ in .closed }, stopIdle: { _ in XCTFail("Not needed") }, execute: { _, _ in XCTFail("Double execution") })
            XCTAssertEqual(second, .deferred)
        })
        XCTAssertEqual(result, .applied)
    }
    func testLinkedRequestIsNeverFollowedAndDiscardPreservesItsTarget() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let target = f.root.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: target)
        let directory = PendingSettings.directory(f.host.contents); try NokPaths.ensure(directory)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.json"), withDestinationURL: target)
        XCTAssertThrowsError(try PendingSettings.read(f.host.contents))
        try PendingSettings.discard(for: f.host)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }
    func testNativeAppEntryAppliesSettingsBeforeScriptWhenNokcanduIsClosed() throws {
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/nokcandu-settings")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("Build the saved-settings helper") }
        let resources = try LauncherEntryTests().entryResourceFixture()
        defer { LauncherEntry.resourceForTesting = nil; try? FileManager.default.removeItem(at: resources) }
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let script = f.host.contents.appendingPathComponent("MacOS/game-launcher")
        let text = "#!/bin/bash\n[ -f \"$(dirname \"$0\")/../SharedSupport/nokcandu/perf.env\" ] || exit 71\nprintf 'applied before launch\\n'\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var config = try XCTUnwrap(f.host.custom); config.launcherSHA = Hashing.sha256(data: Data(text.utf8))
        try config.encoded().write(to: CustomGameConfig.url(in: f.host.contents))
        let game = try XCTUnwrap(GameLibrary.inspect(f.host.appURL))
        let wrapper = f.root.appendingPathComponent("settings-helper-fixture")
        let wrapperText = "#!/bin/sh\nexec " + CustomGames.shellQuote(helper.path) + " \"$@\" --state-root " + CustomGames.shellQuote(stateRoot.path) + "\n"
        try wrapperText.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try LauncherEntry.ensure(game)
        try PendingSettings.ensureHelper(for: game, source: wrapper)
        var settings = Performance.Settings(); settings.fpsCounter = true
        try PendingSettings.save(.performance(settings), title: "Performance", for: game)
        let result = try Shell.run(game.contents.appendingPathComponent("MacOS/" + LauncherEntry.name).path, [], timeout: 20)
        XCTAssertEqual(result.status, 0, result.combined)
        XCTAssertEqual(result.stdout, "applied before launch\n")
        XCTAssertEqual(Performance.settings(for: game), settings)
        XCTAssertTrue(PendingSettings.entries(for: game).isEmpty)
        XCTAssertEqual(try String(contentsOf: script), text)
    }
}

extension PendingSettingsTests {
    func testInactiveStatusDoesNotLaunchOrTimeOutAWineServerProbe() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let marker = f.root.appendingPathComponent("unwanted-probe")
        let server = f.host.support.appendingPathComponent("wine/bin/wineserver")
        try ("#!/bin/sh\ntouch " + CustomGames.shellQuote(marker.path) + "\nsleep 3\n").write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        let running = await WineTools.environmentIsRunning(for: f.host)
        XCTAssertFalse(running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testOfflinePendingGameDoesNotBlockOtherGamesStarting() async throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var settings = Performance.Settings(); settings.fpsCounter = true
        let entry = try PendingSettings.save(.performance(settings), title: "Performance", for: f.host)
        var changed = entry
        changed.gamePath = "/Volumes/Nokcandu-Disconnected-\(UUID().uuidString)/Other.app"
        changed.identity = "unavailable-game"
        let file = PendingSettings.directory(f.host.contents).appendingPathComponent(entry.id + ".json")
        try JSONEncoder().encode(changed).write(to: file)
        let outcome = try await PendingSettings.apply(for: f.host)
        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testInvalidIdentityAndLinkedFolderArePreserved() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var entry = try PendingSettings.save(.audioBuffer(20), title: "Audio", for: f.host)
        let file = PendingSettings.directory(f.host.contents).appendingPathComponent(entry.id + ".json")
        entry.id = "../keep"
        try JSONEncoder().encode(entry).write(to: file)
        XCTAssertThrowsError(try PendingSettings.read(f.host.contents))
        try FileManager.default.removeItem(at: PendingSettings.directory(f.host.contents))
        let external = f.root.appendingPathComponent("Keep Metadata"); try NokPaths.ensure(external)
        try FileManager.default.createSymbolicLink(at: PendingSettings.directory(f.host.contents), withDestinationURL: external)
        XCTAssertThrowsError(try PendingSettings.save(.audioBuffer(40), title: "Audio", for: f.host))
        XCTAssertThrowsError(try PendingSettings.discard(for: f.host))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: external.path)).isEmpty)
    }
}
