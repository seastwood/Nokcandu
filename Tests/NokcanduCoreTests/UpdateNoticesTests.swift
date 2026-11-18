import XCTest
@testable import NokcanduCore

final class UpdateNoticesTests: XCTestCase {
    let app = UpdateNotice(kind: .app, version: "0.15.0")
    let engine = UpdateNotice(kind: .engine, target: "game-a", version: "wine-11-template-24")
    let cinematic = UpdateNotice(kind: .cinematic, target: "game-a", version: "0.80")

    func summary(_ notices: [UpdateNotice], games: Bool = true, ignored: Set<UpdateNotice> = []) -> UpdateNoticeSummary {
        UpdateNoticeSummary(notices: notices, features: AppFeatures(enabled: games ? Set(AppFeature.allCases) : [.profiles, .streams]),
                            preferences: UpdateNoticePreferences(ignored: ignored))
    }
    func testAppBadgeIsRedPriorityAndComponentsAreOrange() {
        XCTAssertEqual(summary([engine]).badge, .components)
        XCTAssertEqual(summary([app, engine]).badge, .app)
        XCTAssertEqual(summary([app, engine]).count, 2)
        XCTAssertEqual(summary([app, engine], ignored: [app]).badge, .components)
        XCTAssertEqual(summary([app, engine], ignored: [app, engine]).badge, .none)
    }
    func testGamesHiddenSuppressesAllComponentsButKeepsApp() {
        let store = UpdateNotice(kind: .store, target: "game-b", version: "2")
        XCTAssertEqual(summary([engine, cinematic, store], games: false).count, 0)
        XCTAssertEqual(summary([app, engine, cinematic, store], games: false).count, 1)
        XCTAssertEqual(summary([app], games: false).badge, .app)
    }
    func testIgnoreAppliesOnlyToThisVersionAndThisGame() {
        let next = UpdateNotice(kind: .engine, target: engine.target, version: "wine-12-template-25")
        let other = UpdateNotice(kind: .engine, target: "game-b", version: engine.version)
        XCTAssertEqual(summary([engine, next, other], ignored: [engine]).count, 2)
        XCTAssertEqual(summary([app, .init(kind: .app, version: "0.16.0")], ignored: [app]).count, 1)
    }
    func testIgnoredNotificationsPersistAndRestoreWithoutChangingFeaturePreferences() throws {
        let suite = "nokcandu-update-notices-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppFeatures(enabled: [.streams]).save(to: defaults)
        var prefs = UpdateNoticePreferences(defaults: defaults)
        prefs.setIgnored(app, true); prefs.setIgnored(engine, true); prefs.save(to: defaults)
        var restored = UpdateNoticePreferences(defaults: defaults)
        XCTAssertEqual(restored.ignored, [app, engine])
        restored.setIgnored(engine, false); restored.save(to: defaults)
        XCTAssertEqual(UpdateNoticePreferences(defaults: defaults).ignored, [app])
        restored.reset(); restored.save(to: defaults)
        XCTAssertTrue(UpdateNoticePreferences(defaults: defaults).ignored.isEmpty)
        XCTAssertEqual(AppFeatures(defaults: defaults).visible, [.streams])
    }
    func testDuplicateNotificationsOnlyCountOnce() {
        XCTAssertEqual(summary([engine, engine, app, app]).count, 2)
    }
    func testMalformedPreferencesRecover() throws {
        let suite = "nokcandu-update-invalid-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: UpdateNoticePreferences.defaultsKey)
        XCTAssertTrue(UpdateNoticePreferences(defaults: defaults).ignored.isEmpty)
    }
    func testAvailableEngineNoticesRespectHeldVersionsAndDoNotModifyGames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var game = InstalledGame(appURL: root.appendingPathComponent("Fixture.app"), name: "Fixture")
        game.wineVersion = EngineVersion.tested.versionString
        try FileManager.default.createDirectory(at: game.prefix, withIntermediateDirectories: true)
        let wine = game.contents.appendingPathComponent("SharedSupport/wine/bin/wine")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture only".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let save = game.prefix.appendingPathComponent("save.dat"), launcher = game.contents.appendingPathComponent("manual-launcher.sh")
        let saved = Data("save and launcher must survive".utf8)
        try saved.write(to: save); try saved.write(to: launcher)
        let asset = ReleaseAsset(name: "WS12WineSikarugir11.0_1.tar.xz", size: 1, url: URL(string: "https://example.invalid/asset")!, sha256: "fixture")
        let catalog = UpdateCatalog(checkedAt: Date(), engines: [asset], templates: [], nativeEngines: [])
        let notices = UpdateNotice.available(games: [game], catalog: catalog, app: nil, includeGames: true, failedEngine: { _ in false })
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.target, game.id)
        XCTAssertEqual(UpdateNotice.available(games: [game], catalog: catalog, app: nil, includeGames: true, failedEngine: { _ in true }), [])
        XCTAssertEqual(UpdateNotice.available(games: [game], catalog: catalog, app: nil, includeGames: false, failedEngine: { _ in false }), [])
        try EngineUpdate.setHeld(game, true)
        XCTAssertEqual(UpdateNotice.available(games: [game], catalog: catalog, app: nil, includeGames: true, failedEngine: { _ in false }), [])
        try EngineUpdate.setHeld(game, false)
        XCTAssertEqual(UpdateNotice.available(games: [game], catalog: catalog, app: nil, includeGames: true, failedEngine: { _ in false }), notices)
        XCTAssertEqual(try Data(contentsOf: save), saved)
        XCTAssertEqual(try Data(contentsOf: launcher), saved)
    }
    func testEngineAndTemplateMakeDistinctNotificationVersions() {
        let game = InstalledGame(appURL: URL(fileURLWithPath: "/tmp/fixture.app"), name: "Fixture")
        let a = UpdateNotice.engine(game, engine: .tested, template: .tested)
        let b = UpdateNotice.engine(game, engine: .tested, template: TemplateVersion([1, 0, 99]))
        XCTAssertNotEqual(a, b)
    }
    func testStoreNoticesDoNotDependOnWineCatalogAndIgnoreOnlyCurrentBuild() {
        let notice = UpdateNotice(kind: .store, target: "store-game", version: "build-100")
        let next = UpdateNotice(kind: .store, target: "store-game", version: "build-101")
        let update = StoreUpdates.Available(link: StoreLink(store: .gog, id: "fixture"), installed: "build-99", latest: "build-100", mac: false)
        XCTAssertEqual(UpdateNotice.available(games: [], catalog: nil, app: nil, includeGames: true, storeUpdates: ["store-game": update]), [notice])
        XCTAssertEqual(UpdateNotice.available(games: [], catalog: nil, app: nil, includeGames: false, storeUpdates: ["store-game": update]), [])
        XCTAssertEqual(summary([notice, next], ignored: [notice]).count, 1)
        XCTAssertEqual(summary([notice, next], games: false).count, 0)
    }
    func testSuccessfulAppCheckSurvivesRelaunchAndInstalledVersionClearsIt() throws {
        let suite = "nokcandu-app-availability-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let asset = ReleaseAsset(name: "Nokcandu.dmg", size: 1, url: URL(string: "https://example.invalid/app")!)
        let release = AppUpdate.Release(version: "0.15.0", tag: "v0.15.0", notes: "fixture", dmg: asset, page: asset.url)
        AppUpdateAvailability.save(release, defaults: defaults)
        XCTAssertEqual(AppUpdateAvailability.load(defaults: defaults, currentVersion: "0.14.4"), release)
        XCTAssertNil(AppUpdateAvailability.load(defaults: defaults, currentVersion: "0.15.0"))
        XCTAssertNil(AppUpdateAvailability.load(defaults: defaults, currentVersion: "0.16.0"))
        AppUpdateAvailability.save(nil, defaults: defaults)
        XCTAssertNil(AppUpdateAvailability.load(defaults: defaults, currentVersion: "0.14.4"))
    }
}
