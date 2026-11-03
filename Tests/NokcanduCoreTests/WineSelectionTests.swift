import XCTest
@testable import NokcanduCore

final class WineSelectionTests: XCTestCase {
    let newer = EngineVersion(major: 11, minor: 0, revision: 1)
    func testDefaultStartsAtOriginalAndDoesNotFollowNewestRelease() throws {
        let suite = "nok-wine-selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WineSelection.defaultEngine(in: defaults), .tested)
        try WineSelection.setDefault(newer, in: defaults)
        XCTAssertEqual(WineSelection.defaultEngine(in: defaults), newer)
        XCTAssertThrowsError(try WineSelection.setDefault(EngineVersion(major: 9, minor: 0, revision: 0), in: defaults))
        XCTAssertEqual(WineSelection.defaultEngine(in: defaults), newer)
    }
    func testNewInstallSnapshotsDefaultAndExplicitChoiceWinsWithoutChangingDefault() throws {
        let suite = "nok-wine-selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var state = InstallState(installID: "fixture", recipeID: "custom", targetApp: "/tmp/fixture.app")
        try WineSelection.freeze(&state, choice: nil, defaults: defaults)
        try WineSelection.setDefault(newer, in: defaults)
        XCTAssertEqual(try WineSelection.engine(for: state), .tested)
        try WineSelection.freeze(&state, choice: WineSelection.minimum, defaults: defaults)
        XCTAssertEqual(try WineSelection.engine(for: state), WineSelection.minimum)
        XCTAssertEqual(WineSelection.defaultEngine(in: defaults), newer)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try WineSelection.engine(for: JSONDecoder().decode(InstallState.self, from: data)), WineSelection.minimum)
    }
    func testLegacyResumeAndInvalidSavedVersionsNeverSilentlyUseNewDefault() throws {
        var state = InstallState(installID: "fixture", recipeID: "custom", targetApp: "/tmp/fixture.app")
        XCTAssertEqual(try WineSelection.engine(for: state), .tested)
        for invalid in ["9.0", "11.0; exit", "latest", "", "10.0/../11.0"] {
            state.inputs[WineSelection.inputKey] = invalid
            XCTAssertThrowsError(try WineSelection.engine(for: state))
        }
    }
    func testOptionsIncludeVerifiedHistoricalWine10AndExcludeOtherFamiliesOrUnverifiedAssets() {
        func asset(_ name: String, _ sha: String? = String(repeating: "a", count: 64)) -> ReleaseAsset {
            ReleaseAsset(name: name, size: 1, url: URL(string: "https://example.invalid/asset")!, sha256: sha)
        }
        let catalog = UpdateCatalog(checkedAt: Date(), engines: [asset("WS12WineSikarugir10.0.tar.xz"), asset("WS12WineSikarugir11.0_1.tar.xz"), asset("WS12WineSikarugir9.0.tar.xz"), asset("WS12WineSikarugir12.0.tar.xz", nil), asset("WS12WineCX24.0.tar.xz")], templates: [], nativeEngines: [])
        XCTAssertEqual(WineSelection.versions(catalog: catalog, cached: []), [newer, .tested, WineSelection.minimum])
    }
    func testRuntimeSpecRetainsVerifiedTemplateAndDistinctRevisions() {
        let original = WineSelection.spec(for: .tested), chosen = WineSelection.spec(for: newer)
        XCTAssertEqual(original.id, RecipeCatalog.sikarugirWine10.id)
        XCTAssertEqual(chosen.wineVersionString, newer.versionString)
        XCTAssertEqual(chosen.id, RuntimeManager.runtimeID(engine: newer, template: .tested))
        XCTAssertEqual(chosen.template, original.template)
    }
    func testSelectedFreshInstallRecordsProvenanceForRepairAndNextRollback() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let spec = WineSelection.spec(for: newer)
        try WineSelection.recordInstalled(spec, contents: f.host.contents)
        let record = try XCTUnwrap(EngineUpdate.state(for: f.host))
        XCTAssertEqual(record.runtimeID, spec.id); XCTAssertEqual(record.status, .kept)
        XCTAssertEqual(record.previousRuntimeID, spec.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EngineUpdate.rollbackDir(f.host.contents).path))
    }
    func testCannotChangeAnInstallationAfterWineIsPrepared() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let state = InstallState(installID: "never-saved", recipeID: "custom", targetApp: f.host.appURL.path)
        let executor = InstallExecutor(recipe: RecipeCatalog.zeroHour, state: state, library: [], stages: [], log: { _ in })
        XCTAssertThrowsError(try executor.selectEngine(newer))
        XCTAssertNil(executor.ctx.state.inputs[WineSelection.inputKey])
    }
    func testSharedGameResolvesHostAndNativeIPXBlocksIncompatibleEngine() throws {
        let f = try LauncherRemovalTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(WineSelection.host(for: f.game, in: [f.host, f.game])?.id, f.host.id)
        var host = f.host
        host.custom?.environment = [NativeIPXNetworking.flag: "1"]
        XCTAssertNotNil(WineSelection.incompatibility(host: host, target: .tested, games: [host]))
        XCTAssertNil(WineSelection.incompatibility(host: host, target: newer, games: [host]))
    }
    func testCacheCleanupProtectsDefaultAndUnfinishedInstallationChoices() throws {
        var pending = InstallState(installID: "pending", recipeID: "custom", targetApp: "/tmp/pending.app")
        try WineSelection.freeze(&pending, choice: newer)
        var finished = pending; finished.finishedAt = Date()
        let protected = WineSelection.protectedRuntimeIDs(defaultEngine: WineSelection.minimum, installs: [pending])
        XCTAssertTrue(protected.contains(WineSelection.spec(for: newer).id))
        XCTAssertTrue(protected.contains(WineSelection.spec(for: WineSelection.minimum).id))
        XCTAssertTrue(protected.contains(RecipeCatalog.sikarugirWine10.id))
        XCTAssertFalse(WineSelection.protectedRuntimeIDs(defaultEngine: .tested, installs: [finished]).contains(WineSelection.spec(for: newer).id))
    }
}


extension WineSelectionTests {
    func testRepairNeverSubstitutesRecipeEngineWhenSelectedCacheIsMissing() throws {
        let fixture = try LauncherRemovalTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = EngineVersion(major: 987654, minor: 0, revision: 1)
        try WineSelection.recordInstalled(WineSelection.spec(for: selected), contents: fixture.host.contents)
        let wine = fixture.host.support.appendingPathComponent("wine/bin/wine")
        let before = try Data(contentsOf: wine)
        let steps = Repair.engineSteps(fixture.host)
        XCTAssertEqual(steps.first?.outcome, .failed)
        XCTAssertTrue(steps.first?.detail.contains(selected.versionString) == true)
        XCTAssertEqual(try Data(contentsOf: wine), before)
        XCTAssertEqual(EngineUpdate.state(for: fixture.host)?.engine, selected.versionString)
    }
}
