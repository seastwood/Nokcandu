import XCTest
@testable import NokcanduCore

final class SteamScriptRepairTests: XCTestCase {
    func testMissingOwnedHostScriptsRecoverButManualLauncherIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-repair-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Steam.app/Contents")
        let state = contents.appendingPathComponent("SharedSupport/nokcandu")
        try NokPaths.ensure(state)
        try Data("{}".utf8).write(to: state.appendingPathComponent(SharedSteam.hostMarker))
        XCTAssertEqual(SharedSteam.repairHostScripts(contents: contents).filter { $0.outcome == .fixed }.count, 2)
        let helper = contents.appendingPathComponent("Resources/" + SharedSteam.helperName)
        let launcher = contents.appendingPathComponent("MacOS/" + SharedSteam.hostLauncher)
        try FileManager.default.removeItem(at: helper)
        let manual = Data("#!/bin/bash\n# My launcher\n".utf8)
        try manual.write(to: launcher)
        let result = SharedSteam.repairHostScripts(contents: contents)
        XCTAssertEqual(result.filter { $0.outcome == .fixed }.count, 1)
        XCTAssertEqual(result.filter { $0.outcome == .skipped }.count, 1)
        XCTAssertEqual(try Data(contentsOf: launcher), manual)
        XCTAssertEqual(try String(contentsOf: helper, encoding: .utf8), SharedSteam.helperScript())
    }
}
