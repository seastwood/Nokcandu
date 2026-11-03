import XCTest
@testable import NokcanduCore

final class LauncherEntryTests: XCTestCase {
    func entryResourceFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("entry-resource-" + UUID().uuidString)
        try NokPaths.ensure(root)
        let target = root.appendingPathComponent("native-entry")
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/launcher-entry/main.c")
        let result = try Shell.run("/usr/bin/xcrun", ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-framework", "CoreFoundation", source.path, "-o", target.path], timeout: 30)
        XCTAssertTrue(result.ok, result.combined)
        LauncherEntry.resourceForTesting = target
        return root
    }

    func testNativeEntryPreservesScriptArgumentsStatusAndUndo() throws {
        let resources = try entryResourceFixture()
        defer { LauncherEntry.resourceForTesting = nil; try? FileManager.default.removeItem(at: resources) }

        var g = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let script = g.launcherURL!, plist = g.contents.appendingPathComponent("Info.plist")
        let text = "#!/bin/bash\nprintf '%s\\n' \"$@\"\nexit 23\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        var config = g.custom!; config.launcherSHA = Hashing.sha256(data: Data(text.utf8))
        try config.encoded().write(to: CustomGameConfig.url(in: g.contents))
        let original = try Data(contentsOf: plist)
        g = GameLibrary.inspect(g.appURL)!
        try LauncherEntry.ensure(g)
        let info = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(info["CFBundleExecutable"] as? String, LauncherEntry.name)
        XCTAssertEqual(GameLibrary.inspect(g.appURL)?.launcherURL, script)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), text)
        let helper = g.contents.appendingPathComponent("MacOS/" + LauncherEntry.name)
        let result = try Shell.run(helper.path, ["two words", "quote'", "$(literal)"], timeout: 10)
        XCTAssertEqual(result.status, 23, result.combined)
        XCTAssertEqual(result.stdout, "two words\nquote'\n$(literal)\n")
        let status = try JSONDecoder().decode(StartupMonitor.Receipt.self, from: Data(contentsOf: g.logs.appendingPathComponent("launcher-status.json")))
        XCTAssertEqual(status.phase, "exited"); XCTAssertEqual(status.exitCode, 23)

        try LauncherEntry.ensure(GameLibrary.inspect(g.appURL)!)
        // Upgrade an already-installed CFBundleExecutable: signing in place
        // incorrectly treats its sibling shell script as unsigned nested code.
        let marker = g.nokcanduState.appendingPathComponent(LauncherEntry.record)
        var recorded = try JSONDecoder().decode(LauncherEntry.State.self, from: Data(contentsOf: marker))
        recorded.sourceSHA = "previous bundled source"
        try JSONEncoder().encode(recorded).write(to: marker)
        try LauncherEntry.ensure(GameLibrary.inspect(g.appURL)!)
        let upgraded = try JSONDecoder().decode(LauncherEntry.State.self, from: Data(contentsOf: marker))
        XCTAssertNotEqual(upgraded.sourceSHA, recorded.sourceSHA)
        XCTAssertEqual(upgraded.original, original)
        try LauncherEntry.undo(g)
        XCTAssertEqual(try Data(contentsOf: plist), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.path))
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), text)
    }
    func testManualLauncherAndEditedEntryArePreserved() throws {
        let resources = try entryResourceFixture()
        defer { LauncherEntry.resourceForTesting = nil; try? FileManager.default.removeItem(at: resources) }

        let g = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let script = g.launcherURL!, before = Data("#!/bin/bash\nexit 0\n".utf8)
        try before.write(to: script)
        var config = g.custom!; config.launcherSHA = Hashing.sha256(data: before)
        try config.encoded().write(to: CustomGameConfig.url(in: g.contents))
        let managed = GameLibrary.inspect(g.appURL)!
        try Data("manual".utf8).write(to: script)
        try LauncherEntry.ensure(managed)
        let helper = g.contents.appendingPathComponent("MacOS/" + LauncherEntry.name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.path))
        try before.write(to: script)
        try LauncherEntry.ensure(managed)
        try Data("edited helper".utf8).write(to: helper)
        XCTAssertThrowsError(try LauncherEntry.undo(g))
        try LauncherEntry.ensure(managed)
        XCTAssertEqual(try Data(contentsOf: helper), Data("edited helper".utf8))
    }
    func testAllocatedUsageIncludesClonedRuntimeButDoesNotFollowExternalLinks() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("allocated-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("app"), source = root.appendingPathComponent("engine"), external = root.appendingPathComponent("external")
        try NokPaths.ensure(app); try NokPaths.ensure(external)
        try Data(repeating: 7, count: 4_000_000).write(to: source)
        try fm.copyItem(at: source, to: app.appendingPathComponent("runtime"))
        try Data(repeating: 8, count: 8_000_000).write(to: external.appendingPathComponent("game"))
        try fm.createSymbolicLink(at: app.appendingPathComponent("game-link"), withDestinationURL: external)
        XCTAssertGreaterThan(Storage.allocatedSize(app), 3_900_000)
        XCTAssertLessThan(Storage.allocatedSize(app), 4_100_000)
        XCTAssertGreaterThanOrEqual(Storage.allocatedSize(app), Storage.size(app))
    }
}

extension LauncherEntryTests {
    func testRepairRestoresMissingOwnedEntryAndPreservesManualReplacement() throws {
        let resources = try entryResourceFixture()
        defer { LauncherEntry.resourceForTesting = nil; try? FileManager.default.removeItem(at: resources) }
        let g = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let script = g.launcherURL!, text = Data("#!/bin/bash\nexit 0\n".utf8)
        try text.write(to: script)
        var config = g.custom!; config.launcherSHA = Hashing.sha256(data: text)
        try config.encoded().write(to: CustomGameConfig.url(in: g.contents))
        let managed = try XCTUnwrap(GameLibrary.inspect(g.appURL))
        try LauncherEntry.ensure(managed)
        let entry = g.contents.appendingPathComponent("MacOS/" + LauncherEntry.name)
        try FileManager.default.removeItem(at: entry)
        try LauncherEntry.ensure(managed, repairMissing: true)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: entry.path))
        XCTAssertEqual(try Data(contentsOf: script), text)
        let manual = Data("manual replacement".utf8)
        try manual.write(to: entry)
        try LauncherEntry.ensure(managed, repairMissing: true)
        XCTAssertEqual(try Data(contentsOf: entry), manual)
    }
}
