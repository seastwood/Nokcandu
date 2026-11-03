import XCTest
@testable import NokcanduCore

final class HelperRepairTests: XCTestCase {
    func fixture() throws -> InstalledGame {
        let game = try IPXNetworkingTests().fixture()
        let bin = game.support.appendingPathComponent("wine/bin")
        try NokPaths.ensure(bin)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("wine"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        return game
    }
    func testMissingStaleAndCorruptOwnedHelperIsRestoredWithoutChangingSettings() throws {
        let game = try fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let source = game.support.appendingPathComponent("verified-test-helper")
        let bytes = Data("current verified helper fixture".utf8)
        try bytes.write(to: source)
        let configuration = try Data(contentsOf: CustomGameConfig.url(in: game.contents))
        let destination = game.nokcanduState.appendingPathComponent(RawMouse.dylibName)
        for previous: Data? in [nil, Data("older version".utf8), Data([0, 255, 13])] {
            try? FileManager.default.removeItem(at: destination)
            if let previous { try previous.write(to: destination) }
            let steps = Repair.helperSteps(game, source: source, relatedGames: [game])
            XCTAssertEqual(steps.first?.outcome, .fixed)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: game.contents)), configuration)
        }
        XCTAssertEqual(Repair.helperSteps(game, source: source, relatedGames: [game]).first?.outcome, .ok)
    }
    func testLinkedHelperIsPreservedAndRepairReportsFailure() throws {
        let game = try fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let source = game.support.appendingPathComponent("verified-test-helper")
        let external = game.support.appendingPathComponent("user-owned-file")
        try Data("new helper".utf8).write(to: source)
        try Data("preserve".utf8).write(to: external)
        let destination = game.nokcanduState.appendingPathComponent(RawMouse.dylibName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: external)
        XCTAssertEqual(Repair.helperSteps(game, source: source, relatedGames: [game]).first?.outcome, .failed)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "preserve")
    }
    func testSharedShortcutRepairsItsHostRatherThanItsOwnBundle() throws {
        let host = try fixture()
        var child = try fixture()
        defer { try? FileManager.default.removeItem(at: host.appURL); try? FileManager.default.removeItem(at: child.appURL) }
        child.hosted = HostedGameLink(hostApp: host.appURL.path, launcher: .ea, id: "test", name: "Test", exe: #"C:\Games\Game.exe"#)
        try JSONEncoder().encode(child.hosted!).write(to: HostedGameLink.url(child.contents))
        let source = host.support.appendingPathComponent("verified-test-helper")
        try Data("current helper".utf8).write(to: source)
        let local = child.nokcanduState.appendingPathComponent(RawMouse.dylibName)
        try Data("shortcut file preserved".utf8).write(to: local)
        let steps = Repair.helperSteps(child, source: source, relatedGames: [host, child])
        XCTAssertEqual(steps.first?.outcome, .fixed)
        XCTAssertEqual(try String(contentsOf: host.nokcanduState.appendingPathComponent(RawMouse.dylibName), encoding: .utf8), "current helper")
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "shortcut file preserved")
    }
    func testRepairPreservesManualLauncher() throws {
        let game = try fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let launcher = try XCTUnwrap(game.launcherURL)
        try NokPaths.ensure(launcher.deletingLastPathComponent())
        let manual = Data("#!/bin/bash\n# manually edited\n".utf8)
        try manual.write(to: launcher)
        XCTAssertEqual(Repair.launcherSteps(game).first?.outcome, .skipped)
        XCTAssertEqual(try Data(contentsOf: launcher), manual)
    }
}

extension HelperRepairTests {
    func testScreenToolRestoresBytesAndExecutablePermissionButRefusesLinks() throws {
        let game = try fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let source = game.support.appendingPathComponent("screen-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        let target = game.nokcanduState.appendingPathComponent("screen-size")
        XCTAssertTrue(try RawMouse.ensureScreenTool(contents: game.contents, source: source))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        XCTAssertTrue(try RawMouse.ensureScreenTool(contents: game.contents, source: source))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.path))
        try Data("corrupt".utf8).write(to: target)
        XCTAssertTrue(try RawMouse.ensureScreenTool(contents: game.contents, source: source))
        XCTAssertFalse(try RawMouse.ensureScreenTool(contents: game.contents, source: source))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        XCTAssertThrowsError(try RawMouse.ensureScreenTool(contents: game.contents, source: source))
    }
}
