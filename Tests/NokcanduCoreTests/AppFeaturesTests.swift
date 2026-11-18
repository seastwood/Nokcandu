import XCTest
@testable import NokcanduCore

final class AppFeaturesTests: XCTestCase {
    func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "nokcandu-features-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testExistingInstallationKeepsAllFeaturesAndCurrentTab() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "welcomeDone")
            defaults.set("streams", forKey: "sidebarTab")
            let features = AppFeatures(defaults: defaults)
            XCTAssertEqual(features.visible, AppFeature.allCases)
            XCTAssertEqual(features.selection(.streams), .streams)
            XCTAssertNil(defaults.object(forKey: AppFeatures.defaultsKey))
        }
    }

    func testEveryCombinationPersistsAndChoosesOnlyVisibleTabs() throws {
        try withDefaults { defaults in
            for bits in 0..<8 {
                let enabled = Set(AppFeature.allCases.enumerated().compactMap { bits & (1 << $0.offset) != 0 ? $0.element : nil })
                let selection = AppFeatures(enabled: enabled)
                selection.save(to: defaults)
                let restored = AppFeatures(defaults: defaults)
                XCTAssertEqual(restored, selection)
                for feature in AppFeature.allCases {
                    if let tab = restored.selection(feature) { XCTAssertTrue(enabled.contains(tab)) }
                    else { XCTAssertTrue(enabled.isEmpty) }
                    if enabled.contains(feature) { XCTAssertEqual(restored.selection(feature), feature) }
                }
            }
        }
    }

    func testHideAndShowPreservesSavedFeatureDataAndExplicitPreferences() throws {
        try withDefaults { defaults in
            let data = Data("saved profile contents".utf8)
            defaults.set(data, forKey: "existingProfiles")
            defaults.set(["host": "paired PC", "certificate": "test fixture"], forKey: "existingHosts")
            defaults.set(["game": "installed", "wine": "10.0"], forKey: "existingGames")
            defaults.set(false, forKey: "steamControllerExclusiveAccess")
            let before = defaults.dictionaryRepresentation()
            AppFeatures(enabled: []).save(to: defaults)
            XCTAssertTrue(AppFeatures(defaults: defaults).enabled.isEmpty)
            AppFeatures().save(to: defaults)
            XCTAssertEqual(AppFeatures(defaults: defaults).visible, AppFeature.allCases)
            for key in ["existingProfiles", "existingHosts", "existingGames", "steamControllerExclusiveAccess"] {
                XCTAssertEqual(defaults.object(forKey: key) as? NSObject, before[key] as? NSObject)
            }
        }
    }

    func testUnknownFeaturesDoNotCreateInvalidNavigation() throws {
        try withDefaults { defaults in
            defaults.set(["futurePlugin", "streams"], forKey: AppFeatures.defaultsKey)
            XCTAssertEqual(AppFeatures(defaults: defaults).visible, [.streams])
            defaults.set(["futurePlugin"], forKey: AppFeatures.defaultsKey)
            XCTAssertNil(AppFeatures(defaults: defaults).selection(.games))
        }
    }

    func testHiddenEditorPausesDesktopProfilesButKeepsAssignedGameAndStreamProfiles() {
        let hidden = AppFeatures(enabled: [.games, .streams])
        XCTAssertFalse(hidden.allowsProfile(forGame: false, inStream: false))
        XCTAssertTrue(hidden.allowsProfile(forGame: true, inStream: false))
        XCTAssertTrue(hidden.allowsProfile(forGame: false, inStream: true))
        // Existing sessions retain their input even if their UI is hidden during play.
        XCTAssertTrue(AppFeatures(enabled: []).allowsProfile(forGame: false, inStream: true))
        XCTAssertTrue(AppFeatures().allowsProfile(forGame: false, inStream: false))
    }

    func testHiddenRemappingDoesNotTakeBackgroundOwnershipOrOverrideOptOut() {
        let streaming = AppFeatures(enabled: [.streams])
        XCTAssertFalse(streaming.ownsControllersInBackground(exclusivePreference: true))
        XCTAssertFalse(AppFeatures().ownsControllersInBackground(exclusivePreference: false))
        XCTAssertTrue(AppFeatures().ownsControllersInBackground(exclusivePreference: true))
        XCTAssertFalse(AppFeatures(enabled: []).ownsControllersInBackground(exclusivePreference: true))
    }
}
