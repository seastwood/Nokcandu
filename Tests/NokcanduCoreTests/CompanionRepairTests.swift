import XCTest
@testable import NokcanduCore

final class CompanionRepairTests: XCTestCase {
    func testOnlyInstalledOwnedMissingHelpersRestoreAndEditedFilesArePreserved() throws {
        let game = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let target = game.prefix.appendingPathComponent("drive_c/nokcandu/test/window.dll")
        let bytes = Data("verified helper".utf8)
        let ledger = CompatibilityFixes.journal(.borderless, game)
        try ledger.write(bytes, to: target, reason: "fixture")
        XCTAssertTrue(CompanionRepair.entries(game).isEmpty) // no installed marker
        let state = CompatibilityFixes.State(executable: game.custom!.exe, previousOverrides: [:], appliedOverrides: [:])
        try JSONEncoder().encode(state).write(to: CompatibilityFixes.marker(.borderless, game))
        CompanionRepair.snapshot(game)
        try FileManager.default.removeItem(at: target)
        XCTAssertEqual(CompanionRepair.repair(game).first?.outcome, .fixed)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try Data("external edit".utf8).write(to: target)
        XCTAssertEqual(CompanionRepair.repair(game).first?.outcome, .skipped)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external edit")
        try FileManager.default.removeItem(at: target)
        try Data("corrupt cache".utf8).write(to: CompanionRepair.cache(game).appendingPathComponent(Hashing.sha256(data: bytes)))
        XCTAssertEqual(CompanionRepair.repair(game).first?.outcome, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testLayeredFixUsesNewestOwnershipAndUndoRetainsOriginal() throws {
        let game = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let target = game.prefix.appendingPathComponent("drive_c/nokcandu/test/dpwsockx.dll")
        try NokPaths.ensure(target.deletingLastPathComponent())
        try Data("original".utf8).write(to: target)
        let state = CompatibilityFixes.State(executable: game.custom!.exe, previousOverrides: [:], appliedOverrides: [:])
        for (fix, text) in [(CompatibilityFix.ipxNetworking, "base"), (.nativeIPXNetworking, "native")] {
            try JSONEncoder().encode(state).write(to: CompatibilityFixes.marker(fix, game))
            try CompatibilityFixes.journal(fix, game).write(Data(text.utf8), to: target, reason: "fixture")
        }
        CompanionRepair.snapshot(game)
        try FileManager.default.removeItem(at: target)
        XCTAssertEqual(CompanionRepair.repair(game).first?.outcome, .fixed)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "native")
        let result = CompatibilityFixes.journal(.nativeIPXNetworking, game).revertAll()
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "base")
    }
}
