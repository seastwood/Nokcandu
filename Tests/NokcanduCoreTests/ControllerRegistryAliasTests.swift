import XCTest
@testable import NokcanduCore

final class ControllerRegistryAliasTests: XCTestCase {
    func fixture(target: String = #"\Registry\Machine\System\ControlSet002"#) throws -> (URL, URL, String) {
        let contents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Game.app/Contents")
        let system = contents.appendingPathComponent("SharedSupport/prefix/system.reg")
        try NokPaths.ensure(system.deletingLastPathComponent())
        addTeardownBlock { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent().deletingLastPathComponent()) }
        let bytes = Array((target + "\0").utf16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
        let hex = bytes.map { String(format: "%02x", $0) }
        let wrapped = stride(from: 0, to: hex.count, by: 16).map { hex[$0..<min(hex.count, $0+16)].joined(separator: ",") }.joined(separator: ",\\\n  ")
        let text = """
        WINE REGISTRY Version 2

        [System\\\\CurrentControlSet] 1
        #link
        "SymbolicLinkValue"=hex(6):\(wrapped)

        [System\\\\ControlSet002\\\\Services\\\\WineBus] 1
        "DisableInput"=dword:00000001
        "Keep"="unchanged"

        [System\\\\ControlSet002\\\\Services\\\\WineBus\\\\Devices\\\\057e] 1
        "Hidraw"=dword:00000000

        [Software\\\\Other] 1
        "Keep"="me"
        """
        try text.write(to: system, atomically: true, encoding: .utf8)
        return (contents, system, text)
    }
    func testNativeAndAutomaticUseRealControlSetAndPreserveUnrelatedValues() throws {
        let (_, system, _) = try fixture()
        try Controllers.apply(Controllers.plan(.native, steam: false), system: system)
        try Controllers.applyHidden(false, system: system)
        var text = try String(contentsOf: system)
        XCTAssertFalse(text.contains("[System\\\\CurrentControlSet\\\\Services"))
        XCTAssertTrue(text.contains("[System\\\\ControlSet002\\\\Services\\\\WineBus\\\\Devices\\\\28de]"))
        XCTAssertEqual(text.components(separatedBy: "\"Hidraw\"=dword:00000001").count - 1, 3)
        XCTAssertFalse(text.contains("\"DisableInput\""))
        XCTAssertTrue(text.contains("\"Keep\"=\"unchanged\"")); XCTAssertTrue(text.contains("\"Keep\"=\"me\""))
        try Controllers.apply(Controllers.plan(.automatic, steam: false), system: system)
        text = try String(contentsOf: system)
        XCTAssertFalse(text.contains("\"Hidraw\""))
    }
    func testInvalidAliasDoesNotCreateShadowKeysOrChangeRegistry() throws {
        let (_, system, text) = try fixture(target: #"\Registry\User\Other"#)
        XCTAssertThrowsError(try Controllers.apply(Controllers.plan(.native, steam: false), system: system))
        XCTAssertEqual(try String(contentsOf: system), text)
    }
    func testUnknownProcessObservationRefusesSetAndRefreshWithoutWrites() throws {
        let (contents, system, original) = try fixture()
        let unknown = ProcessSnapshot(rows: [], reliable: false)
        XCTAssertThrowsError(try Controllers.set(.native, contents: contents, snapshot: unknown))
        Controllers.refresh(contents: contents, snapshot: unknown)
        XCTAssertEqual(try String(contentsOf: system), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Controllers.settingsURL(contents).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.appendingPathExtension("pre-controller-routing-v2").path))
    }
    func testIdleMigrationReappliesOldMarkerAndPreservesFirstBackup() throws {
        let (contents, system, original) = try fixture()
        try NokPaths.ensure(Controllers.settingsURL(contents).deletingLastPathComponent())
        try Data(#"{"mode":"native"}"#.utf8).write(to: Controllers.settingsURL(contents))
        let marker = contents.appendingPathComponent("SharedSupport/nokcandu/controllers-applied")
        try Data("native".utf8).write(to: marker)
        let closed = ProcessSnapshot(rows: [], reliable: true)
        Controllers.refresh(contents: contents, snapshot: closed)
        XCTAssertEqual(try String(contentsOf: marker), "v2:native")
        XCTAssertEqual(try String(contentsOf: system.appendingPathExtension("pre-controller-routing-v2")), original)
        let first = try Data(contentsOf: system)
        Controllers.refresh(contents: contents, snapshot: closed)
        XCTAssertEqual(try Data(contentsOf: system), first)
        XCTAssertEqual(try String(contentsOf: system.appendingPathExtension("pre-controller-routing-v2")), original)
    }
}

extension ControllerRegistryAliasTests {
    func testExplicitNativeWinsOverAnotherSharedProfileDriver() throws {
        let (contents, system, _) = try fixture()
        let folder = Controllers.settingsURL(contents).deletingLastPathComponent()
        try NokPaths.ensure(folder)
        try Data("nokpad 1\nbind 0 a press=key:12".utf8).write(to: folder.appendingPathComponent("pad-map"))
        XCTAssertEqual(Controllers.effective(.automatic, contents: contents), .xbox)
        XCTAssertEqual(Controllers.effective(.native, contents: contents), .native)
        XCTAssertEqual(Controllers.effective(.xbox, contents: contents), .xbox)
        XCTAssertEqual(Controllers.effective(.hidden, contents: contents), .hidden)
        try Data(#"{"mode":"native"}"#.utf8).write(to: Controllers.settingsURL(contents))
        try Data("v2:xbox".utf8).write(to: folder.appendingPathComponent("controllers-applied"))
        Controllers.refresh(contents: contents, snapshot: ProcessSnapshot(rows: [], reliable: true))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("controllers-applied")), "v2:native")
        XCTAssertEqual(try String(contentsOf: system).components(separatedBy: "\"Hidraw\"=dword:00000001").count - 1, 3)
    }
}

extension ControllerRegistryAliasTests {
    func testWindowsToolAppliesSavedRouteBeforeStartingItsFirstProcess() throws {
        guard GameLauncher.freshProcessStatus().reliable else { throw XCTSkip("Process inspection unavailable; unknown-prefix refusal is covered separately") }
        let game = try LauncherRemovalTests().fixture().host
        defer { try? FileManager.default.removeItem(at: game.appURL.deletingLastPathComponent()) }
        let contents = try XCTUnwrap(WineTools.hostContents(for: game))
        let system = contents.appendingPathComponent("SharedSupport/prefix/system.reg")
        try NokPaths.ensure(system.deletingLastPathComponent())
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: system)
        try NokPaths.ensure(Controllers.settingsURL(contents).deletingLastPathComponent())
        try Data(#"{"mode":"native"}"#.utf8).write(to: Controllers.settingsURL(contents))
        let result = game.appURL.deletingLastPathComponent().appendingPathComponent("tool-observed-route")
        let tool = contents.appendingPathComponent("SharedSupport/wine/bin/wine")
        try NokPaths.ensure(tool.deletingLastPathComponent())
        try Data(("#!/bin/sh\n/usr/bin/grep -c '\"Hidraw\"=dword:00000001' \"$WINEPREFIX/system.reg\" > " + CustomGames.shellQuote(result.path) + "\n").utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try WineTools.run(["control", "joy.cpl"], for: game)
        let deadline = Date().addingTimeInterval(2)
        // The shell creates the redirected file before grep writes its count.
        // Wait for receipt rather than treating an empty created file as completion.
        while ((try? String(contentsOf: result).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "").isEmpty,
              Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(try String(contentsOf: result).trimmingCharacters(in: .whitespacesAndNewlines), "3")
        XCTAssertEqual(try String(contentsOf: contents.appendingPathComponent("SharedSupport/nokcandu/controllers-applied")), "v2:native")
    }
}
