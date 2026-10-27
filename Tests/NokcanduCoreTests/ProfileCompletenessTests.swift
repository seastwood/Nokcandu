import XCTest
@testable import NokcanduCore

final class ProfileCompletenessTests: XCTestCase {
    func sample() -> GameProfile {
        var p = GameProfile(title: "BF1942", match: .init(exeName: "BF1942.exe"), source: "folder", rating: .playable)
        p.schema = 2; p.rawMouseFrameSync = true
        p.gameDisplay = .init(resolution: [1280, 800], menuCorrection: true)
        return p
    }
    func testNewSettingsRoundTripAndOldProfilesRemainValid() throws {
        let p = sample()
        XCTAssertEqual(p.problems, [])
        XCTAssertEqual(try GameProfile.parse(p.json()), p)
        var legacy = p; legacy.schema = 1; legacy.rawMouseFrameSync = nil; legacy.gameDisplay = nil
        XCTAssertEqual(legacy.problems, [])
        let decoded = try GameProfile.parse(legacy.json())
        XCTAssertNil(decoded.rawMouseFrameSync); XCTAssertNil(decoded.gameDisplay)
        var wrong = p; wrong.schema = 1
        XCTAssertFalse(wrong.problems.isEmpty, "old clients must not silently accept settings they cannot apply")
    }
    func testOnlyBuiltInBF1942RecipeAndResolutionsCanBeShared() {
        var p = sample(); p.gameDisplay?.recipe = "https://example.com/patch.exe"
        XCTAssertFalse(p.problems.isEmpty)
        p = sample(); p.gameDisplay?.resolution = [99999]
        XCTAssertFalse(p.problems.isEmpty)
        p = sample(); p.match.exeName = "OtherGame.exe"
        XCTAssertFalse(p.problems.isEmpty)
        let other = InstalledGame(appURL: URL(fileURLWithPath: "/tmp/Other.app"), name: "Other")
        XCTAssertFalse(Profiles.plan(sample(), for: other).appliesGameDisplay)
    }
    func fixture() throws -> InstalledGame {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("profile-display-" + UUID().uuidString + ".app")
        let g = InstalledGame(appURL: app, name: "Profile display test")
        try NokPaths.ensure(g.nokcanduState); try NokPaths.ensure(g.contents.appendingPathComponent("MacOS"))
        try NokPaths.ensure(g.prefix.appendingPathComponent("dosdevices"))
        try FileManager.default.createSymbolicLink(atPath: g.prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        let root = g.prefix.appendingPathComponent("drive_c/Games/BF1942")
        try NokPaths.ensure(root.appendingPathComponent("Mods/bf1942/Settings/Profiles/Default"))
        try Data("unknown EXE (resolution-only test)".utf8).write(to: root.appendingPathComponent("BF1942.exe"))
        try Data("run Profiles/Default/Video.con\n".utf8).write(to: root.appendingPathComponent("Mods/bf1942/Settings/Video.con"))
        try Data("game.setGameDisplayMode 800 600 32 60\nrem keep\n".utf8).write(to: root.appendingPathComponent("Mods/bf1942/Settings/Profiles/Default/Video.con"))
        let c = CustomGameConfig(id: "profile-display-test", name: g.name, source: .folder, exe: #"C:\Games\BF1942\BF1942.exe"#, graphics: .classic3D)
        try c.encoded().write(to: CustomGameConfig.url(in: g.contents))
        let info: [String: Any] = ["CFBundleName": g.name, "CFBundleExecutable": "game-launcher", "CFBundleIdentifier": "local.test." + UUID().uuidString]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: g.contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(GameLibrary.inspect(app))
    }
    func testProfileUndoRestoresDisplayFilesAndExistingRecipeBaseline() async throws {
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let video = g.prefix.appendingPathComponent("drive_c/Games/BF1942/Mods/bf1942/Settings/Profiles/Default/Video.con")
        let original = try Data(contentsOf: video)
        var p = sample(); p.rawMouseFrameSync = nil; p.gameDisplay?.menuCorrection = false; p.gameDisplay?.resolution = [1920, 1080]
        let snap = try Profiles.apply(p, to: g, includeShared: false)
        try await Profiles.applyGameDisplay(p, to: g, snapshot: snap) { _ in }
        XCTAssertTrue(try String(contentsOf: video).contains("1920 1080 32 60"))
        // Restore the profile's file checkpoint; the existing profile Undo also restores normal settings.
        try snap.displayCheckpoint?.restore()
        XCTAssertEqual(try Data(contentsOf: video), original)
        XCTAssertFalse(BF1942DisplayFix.hasChanges(for: g))
        // If a display recipe existed already, profile Undo must restore it, not remove its history.
        try await BF1942DisplayFix.apply(to: CompatibilityFixes.fresh(g), size: [1024, 768], recommended: false) { _ in }
        let baseline = try Data(contentsOf: BF1942DisplayFix.record(g))
        let snap2 = try Profiles.apply(p, to: CompatibilityFixes.fresh(g), includeShared: false)
        try await Profiles.applyGameDisplay(p, to: g, snapshot: snap2) { _ in }
        try snap2.displayCheckpoint?.restore()
        XCTAssertEqual(BF1942DisplayFix.resolution(for: g), [1024, 768])
        XCTAssertEqual(try Data(contentsOf: BF1942DisplayFix.record(g)), baseline)
        try BF1942DisplayFix.undo(for: CompatibilityFixes.fresh(g)) { _ in }
        XCTAssertEqual(try Data(contentsOf: video), original)
    }
    func testProfileUndoDoesNotOverwriteChangesMadeAfterApplying() async throws {
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        var p = sample(); p.rawMouseFrameSync = nil; p.gameDisplay?.menuCorrection = false
        let snap = try Profiles.apply(p, to: g, includeShared: false)
        try await Profiles.applyGameDisplay(p, to: g, snapshot: snap) { _ in }
        let video = g.prefix.appendingPathComponent("drive_c/Games/BF1942/Mods/bf1942/Settings/Profiles/Default/Video.con")
        try Data("user edits\n".utf8).write(to: video)
        XCTAssertThrowsError(try snap.displayCheckpoint?.restore())
        XCTAssertEqual(try String(contentsOf: video), "user edits\n")
    }
}
