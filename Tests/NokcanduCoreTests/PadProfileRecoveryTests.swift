import XCTest
@testable import NokcanduCore
final class PadProfileRecoveryTests: XCTestCase {
    func testOwnProfileNewFeaturesBackUpOriginalExactlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = root.appendingPathComponent("Game.app/Contents")
        var p = PadProfiles.Profile(name: "Own")
        try PadProfiles.set(.own, contents: c, own: p)
        let file = PadProfiles.ownFile(c), before = try Data(contentsOf: file)
        p.controlRoutes = ["rt": .both]; p.routingMode = .selective
        try PadProfiles.set(.own, contents: c, own: p)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), before)
        p.base[.a] = .as(.keyToggle(12))
        try PadProfiles.set(.own, contents: c, own: p)
        XCTAssertEqual(PadProfiles.own(contents: c), p)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-controller-v2")), before)
    }
    func testUnreadableProfileDataIsNeverReplacedWithNewDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(root); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("profiles.json")
        let bytes = Data("{unrecognized or damaged data".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try PadProfiles.store(PadProfiles.Profile(name: "New"), environments: [], file: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let c = root.appendingPathComponent("Game.app/Contents")
        try NokPaths.ensure(PadProfiles.ownFile(c).deletingLastPathComponent())
        try bytes.write(to: PadProfiles.ownFile(c))
        XCTAssertThrowsError(try PadProfiles.set(.own, contents: c, own: PadProfiles.Profile(name: "New own")))
        XCTAssertEqual(try Data(contentsOf: PadProfiles.ownFile(c)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PadProfiles.choiceFile(c).path))
    }
}

final class PadOwnEditScopeTests: XCTestCase {
    func testSharedGameResolvesPendingOwnProfileToActualLauncherScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("Host.app/Contents"), game = root.appendingPathComponent("Game.app/Contents")
        for c in [host, game] { try NokPaths.ensure(PadProfiles.choiceFile(c).deletingLastPathComponent()) }
        try Data("own\n".utf8).write(to: PadProfiles.choiceFile(host))
        XCTAssertEqual(PadProfiles.ownSource(contents: game, shared: true, inheritedHost: host), host)
        try Data("own\n".utf8).write(to: PadProfiles.choiceFile(game))
        XCTAssertEqual(PadProfiles.ownSource(contents: game, shared: true, inheritedHost: host), game)
        try Data("none\n".utf8).write(to: PadProfiles.choiceFile(game))
        XCTAssertNil(PadProfiles.ownSource(contents: game, shared: true, inheritedHost: host))
        XCTAssertNil(PadProfiles.ownSource(contents: game, shared: false, inheritedHost: host))
    }
}
