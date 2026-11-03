import XCTest
@testable import NokcanduCore

final class AppPrivacyTests: XCTestCase {
    func info(_ g: InstalledGame) throws -> [String: Any] {
        try XCTUnwrap(NSDictionary(contentsOf: g.contents.appendingPathComponent("Info.plist")) as? [String: Any])
    }
    func write(_ value: [String: Any], _ g: InstalledGame) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: g.contents.appendingPathComponent("Info.plist"))
    }
    func testOffMigrationOnOptInAndNativeEntryUndoStayConsistent() throws {
        let resources = try LauncherEntryTests().entryResourceFixture()
        defer { LauncherEntry.resourceForTesting = nil; try? FileManager.default.removeItem(at: resources) }
        let g = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let bin = g.support.appendingPathComponent("wine/bin")
        try NokPaths.ensure(bin)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("wine"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        var metadata = try info(g)
        metadata[AppPrivacy.microphoneKey] = AppPrivacy.microphonePurpose
        metadata["UserSetting"] = "keep"
        try write(metadata, g)
        try CustomGames.save(g.custom!, to: g)
        XCTAssertTrue(AppPrivacy.ensure(g.appURL))
        XCTAssertNil(try info(g)[AppPrivacy.microphoneKey])
        XCTAssertEqual(try info(g)["UserSetting"] as? String, "keep")
        try GameMicrophone.set(true, for: GameLibrary.inspect(g.appURL)!)
        XCTAssertNotNil(try info(g)[AppPrivacy.microphoneKey])
        XCTAssertTrue(GameMicrophone.isOn(GameLibrary.inspect(g.appURL)!))
        XCTAssertEqual(try String(contentsOf: g.nokcanduState.appendingPathComponent(GameMicrophone.policyFile), encoding: .utf8), "0\n")
        try GameMicrophone.set(false, for: GameLibrary.inspect(g.appURL)!)
        XCTAssertNil(try info(g)[AppPrivacy.microphoneKey])
        XCTAssertEqual(try String(contentsOf: g.nokcanduState.appendingPathComponent(GameMicrophone.policyFile), encoding: .utf8), "1\n")
        try LauncherEntry.undo(GameLibrary.inspect(g.appURL)!)
        XCTAssertNil(try info(g)[AppPrivacy.microphoneKey])
        XCTAssertEqual(try info(g)["UserSetting"] as? String, "keep")
        XCTAssertEqual(try info(g)["CFBundleExecutable"] as? String, "game-launcher")
    }
    func testManualEntryMetadataIsKeptAndFailureIsVisibleToLaunchPreparation() throws {
        let resources = try LauncherEntryTests().entryResourceFixture()
        defer { LauncherEntry.resourceForTesting = nil; try? FileManager.default.removeItem(at: resources) }
        let g = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        var metadata = try info(g); metadata[AppPrivacy.microphoneKey] = AppPrivacy.microphonePurpose; try write(metadata, g)
        try CustomGames.save(g.custom!, to: g)
        metadata = try info(g); metadata["ManualEdit"] = true; try write(metadata, g)
        let before = try Data(contentsOf: g.contents.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try AppPrivacy.prepare(GameLibrary.inspect(g.appURL)!))
        XCTAssertEqual(try Data(contentsOf: g.contents.appendingPathComponent("Info.plist")), before)
    }
    func testSharedParentDeclarationFollowsLaunchingIntentWithoutChangingOtherChoices() throws {
        let host = try IPXNetworkingTests().fixture()
        let off = try IPXNetworkingTests().fixture(), on = try IPXNetworkingTests().fixture()
        defer { for g in [host, off, on] { try? FileManager.default.removeItem(at: g.appURL) } }
        let wine = host.support.appendingPathComponent("wine/bin/wine")
        try NokPaths.ensure(wine.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: wine, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        for (game, enabled) in [(off, false), (on, true)] {
            let link = BattleNetLink(hostApp: host.appURL.path, uid: enabled ? "on" : "off", code: "TEST", name: game.name)
            try JSONEncoder().encode(link).write(to: BattleNetLink.url(game.contents))
            if enabled { try Data("1\n".utf8).write(to: game.nokcanduState.appendingPathComponent(GameMicrophone.sharedChoice)) }
        }
        let offGame = GameLibrary.inspect(off.appURL)!, onGame = GameLibrary.inspect(on.appURL)!
        let games = [host, offGame, onGame]
        try AppPrivacy.prepare(offGame, games: games)
        XCTAssertNil(try info(host)[AppPrivacy.microphoneKey]) // An unlaunched On sibling does not opt the host in.
        try AppPrivacy.prepare(onGame, games: games)
        XCTAssertNotNil(try info(host)[AppPrivacy.microphoneKey])
        XCTAssertNotNil(try info(on)[AppPrivacy.microphoneKey])
        XCTAssertEqual(try info(host)[AppPrivacy.microphoneIntentKey] as? Bool, true)
        try AppPrivacy.prepare(offGame, games: games)
        XCTAssertNil(try info(host)[AppPrivacy.microphoneKey])
        XCTAssertFalse(GameMicrophone.isOn(offGame)); XCTAssertTrue(GameMicrophone.isOn(onGame))
    }
    func testNewWrappersDeclareMicrophoneOnlyWhenEnabled() {
        XCTAssertTrue(AppPrivacy.keys.isEmpty)
        XCTAssertNil(GameApp.plist(name: "Game", icon: false)[AppPrivacy.microphoneKey])
        XCTAssertNotNil(GameApp.plist(name: "Game", icon: false, microphone: true)[AppPrivacy.microphoneKey])
    }
}
