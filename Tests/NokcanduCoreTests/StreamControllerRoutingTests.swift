import XCTest
@testable import NokcanduCore

final class StreamControllerRoutingTests: XCTestCase {
    let selected = PadProfiles.Profile(id: "selected", name: "Stream profile")
    var everywhere: PadProfiles.Profile {
        var p = PadProfiles.Profile(id: "everywhere", name: "Everywhere")
        p.controllerSource = .steamUSB; p.presentAs = .dualShock4
        return p
    }
    func resolve(_ settings: StreamProfile.Controller, id: String? = "everywhere", enabled: Bool = true,
                 profiles: [PadProfiles.Profile]? = nil) -> StreamControllerRouting {
        StreamControllerRouting(settings: settings, everywhereID: id, profilesEnabled: enabled,
                                profiles: profiles ?? [selected, everywhere])
    }
    func settings(override: Bool = true, selectedID: String? = "selected") -> StreamProfile.Controller {
        var s = StreamProfile.Controller(); s.profileID = selectedID; s.allowEverywhereOverride = override
        return s
    }
    func testLegacyStreamSettingsKeepTheirOwnProfile() throws {
        let data = Data(#"{"profileID":"selected","sendAs":"xbox","multipleControllers":false}"#.utf8)
        let restored = try JSONDecoder().decode(StreamProfile.Controller.self, from: data)
        XCTAssertFalse(restored.allowEverywhereOverride)
        XCTAssertEqual(resolve(restored).settings.profileID, "selected")
        XCTAssertEqual(resolve(restored).settings.sendAs, .xbox)
        XCTAssertFalse(resolve(restored).settings.multipleControllers)
        XCTAssertFalse(StreamProfile.Controller().allowEverywhereOverride)
    }
    func testOptInOverridesSelectedAndAsItIsChoicesWithoutChangingSavedSettings() {
        for id in [String? ("selected"), nil] {
            let saved = settings(selectedID: id)
            let active = resolve(saved)
            XCTAssertEqual(active.settings.profileID, everywhere.id)
            XCTAssertTrue(active.usesEverywhere)
            XCTAssertTrue(active.readsSteam)
            XCTAssertEqual(active.presentedController, .dualShock4)
            XCTAssertEqual(saved.profileID, id)
        }
    }
    func testDisabledOptionNeverOverrides() {
        let resolved = resolve(settings(override: false))
        XCTAssertEqual(resolved.settings.profileID, selected.id)
        XCTAssertFalse(resolved.usesEverywhere)
        XCTAssertFalse(resolved.readsSteam)
        XCTAssertNil(resolved.presentedController)
        XCTAssertNil(resolve(settings(override: false, selectedID: nil)).settings.profileID)
    }
    func testStoppedDisabledOrMissingEverywhereFallsBackImmediately() {
        let saved = settings()
        for resolved in [resolve(saved, id: nil), resolve(saved, enabled: false), resolve(saved, id: "deleted")] {
            XCTAssertEqual(resolved.settings.profileID, selected.id)
            XCTAssertFalse(resolved.usesEverywhere)
            XCTAssertFalse(resolved.readsSteam)
        }
        XCTAssertNil(resolve(settings(selectedID: nil), id: nil).settings.profileID)
        XCTAssertEqual(resolve(saved).settings.profileID, everywhere.id, "Reactivating Everywhere restores the opt-in override")
    }
    func testDeletedSelectedProfileFallsBackToRawInsteadOfReservingAnUnmappedPlayer() {
        XCTAssertNil(resolve(settings(override: false, selectedID: "deleted")).settings.profileID)
        XCTAssertEqual(resolve(settings(selectedID: "deleted")).settings.profileID, everywhere.id)
        XCTAssertNil(resolve(settings(selectedID: "deleted"), profiles: []).settings.profileID)
    }
    func testOverridePreservesExplicitStreamControllerOptions() throws {
        var saved = settings()
        saved.sendAs = .profileOnly; saved.multipleControllers = false; saved.swapFaceButtons = true; saved.motion = false
        var expected = saved; expected.profileID = everywhere.id
        XCTAssertEqual(resolve(saved).settings, expected)
        let roundTrip = try JSONDecoder().decode(StreamProfile.Controller.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(roundTrip, saved)
        XCTAssertEqual(roundTrip.profileID, selected.id)
        XCTAssertTrue(roundTrip.allowEverywhereOverride)
    }
    func testIdentityAndPhysicalReaderFollowInheritedEffectiveProfile() {
        let child = PadProfiles.Profile(id: "child", name: "Child", buildsOn: [everywhere.id])
        let resolved = resolve(settings(), id: child.id, profiles: [selected, everywhere, child])
        XCTAssertEqual(resolved.settings.profileID, child.id)
        XCTAssertTrue(resolved.readsSteam)
        XCTAssertEqual(resolved.presentedController, .dualShock4)
        var edited = everywhere; edited.controllerSource = .automatic; edited.presentAs = .xbox
        let next = resolve(settings(), id: child.id, profiles: [selected, edited, child])
        XCTAssertNotEqual(next, resolved, "A same-ID source/identity edit must reconfigure controller routing")
        XCTAssertFalse(next.readsSteam)
        XCTAssertEqual(next.presentedController, .xbox)
    }
    func testOverrideChoiceIsLiveAndIndependentForEachStream() throws {
        let first = StreamProfile(hostID: "h", name: "Home")
        var second = first; second.controller.allowEverywhereOverride = true
        XCTAssertEqual(second.settingChanges(from: first).live, ["let use everywhere override"])
        XCTAssertTrue(second.settingChanges(from: first).nextStream.isEmpty)
        XCTAssertFalse(first.controller.allowEverywhereOverride)
        let oldData = try JSONEncoder().encode(first)
        let newData = try JSONEncoder().encode(second)
        XCTAssertFalse(try JSONDecoder().decode(StreamProfile.self, from: oldData).controller.allowEverywhereOverride)
        XCTAssertTrue(try JSONDecoder().decode(StreamProfile.self, from: newData).controller.allowEverywhereOverride)
    }
}
