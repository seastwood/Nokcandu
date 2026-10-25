import XCTest
@testable import NokcanduCore

final class UpdatesTests: XCTestCase {
    func testEngineVersions() {
        let a = EngineVersion(assetName: "WS12WineSikarugir11.0_1.tar.xz")
        XCTAssertEqual(a, EngineVersion(major: 11, minor: 0, revision: 1))
        XCTAssertEqual(EngineVersion(assetName: "WS12WineSikarugir10.0.tar.xz")?.revision, 0)
        XCTAssertNil(EngineVersion(assetName: "WS12WineSikarugir10.0-battle.net.tar.xz"))
        XCTAssertNil(EngineVersion(assetName: "WS12WineCX24.0.7_7.tar.xz"))
        XCTAssertEqual(EngineVersion.tested, EngineVersion(major: 10, minor: 0, revision: 8))
        XCTAssertEqual(EngineVersion(versionString: "wine sikarugir 11.0 (revision 1)"), a)
        XCTAssertEqual(a?.versionString, "wine sikarugir 11.0 (revision 1)")
        XCTAssertEqual(a?.engineName, "WS12WineSikarugir11.0_1")
        XCTAssertTrue(EngineVersion.tested < a!)
        XCTAssertTrue(EngineVersion(major: 10, minor: 0, revision: 10) > EngineVersion(major: 10, minor: 0, revision: 8))
    }

    func testTemplateVersions() {
        XCTAssertEqual(TemplateVersion(assetName: "Template-1.0.24.tar.xz"), TemplateVersion.tested)
        XCTAssertTrue(TemplateVersion([1, 0, 9]) < TemplateVersion([1, 0, 24]))
        XCTAssertEqual(RuntimeManager.runtimeID(engine: .tested, template: .tested), RecipeCatalog.sikarugirWine10.id)
    }

    func testLatestPicksVerifiedNewest() {
        func asset(_ n: String, _ sha: String?) -> ReleaseAsset { ReleaseAsset(name: n, size: 1, url: URL(string: "https://x/\(n)")!, sha256: sha, updated: nil) }
        let cat = UpdateCatalog(checkedAt: Date(), engines: [asset("WS12WineSikarugir10.0_8.tar.xz", "a"), asset("WS12WineSikarugir11.0_1.tar.xz", "b"),
                                                            asset("WS12WineSikarugir12.0.tar.xz", nil), asset("WS12WineCX99.0.tar.xz", "c")],
                                templates: [], lav: nil, nativeEngines: [])
        XCTAssertEqual(cat.latestEngine?.version, EngineVersion(major: 11, minor: 0, revision: 1))
    }
}

final class AppUpdateTests: XCTestCase {
    func testVersionOrdering() {
        XCTAssertTrue(AppUpdate.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(AppUpdate.isNewer("1.0.0", than: "1.0.0-beta.2"))
        XCTAssertFalse(AppUpdate.isNewer("1.0.0-beta", than: "1.0.0"))
        XCTAssertFalse(AppUpdate.isNewer("0.9.0", than: "0.9.0"))
        XCTAssertTrue(AppUpdate.isNewer("0.9.1", than: "0.9"))
    }

    func testTestedDownloadsArePinned() {
        XCTAssertEqual(Setup.testedEngine.sha256?.count, 64)
        XCTAssertEqual(EngineVersion(assetName: Setup.testedEngine.name), .tested)
        XCTAssertEqual(TemplateVersion(assetName: Setup.testedTemplate.name), .tested)
    }
}
