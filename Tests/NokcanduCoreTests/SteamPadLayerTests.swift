import XCTest
@testable import NokcanduCore
import NokcanduPadEngine

final class SteamPadLayerTests: XCTestCase {
    func testALayerCanHaveItsOwnPadSettingsAndOthersFollowTheBase() throws {
        var p = PadProfiles.Profile(name: "Steam")
        p.steamRightTrackpad = PadSteamTrackpadSettings(mode: .trackball)
        p.layers.append(PadProfiles.Layer(name: "Aim")); p.layers.append(PadProfiles.Layer(name: "Menu"))
        var slow = PadSteamTrackpadSettings(mode: .mouse); slow.sensitivity = 300; slow.edge = 0.3
        p.layers[1].steamRightTrackpad = slow
        XCTAssertEqual(PadProfiles.steamTrackpad(1, profile: p, all: [p]).mode, .trackball)
        let aim = PadProfiles.steamTrackpad(1, profile: p, all: [p], layer: "aim")
        XCTAssertEqual(aim.mode, .mouse); XCTAssertEqual(aim.sensitivity, 300); XCTAssertEqual(aim.edge, 0.3)
        XCTAssertEqual(aim.rotation, 15, "defaults are filled in for a layer too")
        XCTAssertEqual(PadProfiles.steamTrackpad(1, profile: p, all: [p], layer: "Menu").mode, .trackball)
        XCTAssertEqual(PadProfiles.steamTrackpad(1, profile: p, all: [p], layer: "Missing").mode, .trackball)
        XCTAssertEqual(PadProfiles.steamTrackpad(0, profile: p, all: [p], layer: "Aim").mode, .existing, "the other pad is untouched")
        // A profile built on this one inherits the layer's pad settings, and can replace them.
        var child = PadProfiles.Profile(name: "Child"); child.buildsOn = [p.id]
        XCTAssertEqual(PadProfiles.steamTrackpad(1, profile: child, all: [p, child], layer: "Aim").mode, .mouse)
        child.layers.append(PadProfiles.Layer(name: "Aim")); child.layers[1].steamRightTrackpad = PadSteamTrackpadSettings(mode: .directions)
        XCTAssertEqual(PadProfiles.steamTrackpad(1, profile: child, all: [p, child], layer: "Aim").mode, .directions)
        XCTAssertEqual(try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(p)), p)
    }

    func testSteamStarterIsPlayableAsItComes() throws {
        let p = PadProfiles.steamStarter()
        XCTAssertEqual(p.controllerSource, .steamUSB)
        XCTAssertEqual(p.base[.rt]?.press, [.mouse(.left)], "a new Steam Controller profile has a click")
        XCTAssertEqual(PadProfiles.steamTrackpad(0, profile: p, all: [p]).mode, .directions)
        XCTAssertEqual(p.base[.lpedge]?.press, [.key(56)])
        let engine = try XCTUnwrap(PadProfiles.compile(p, all: [p]).withCString { pe_create($0, pe_sink()) })
        pe_destroy(engine)
    }

    func testRoutingChoicesHaveNamesAndCoverEveryMode() {
        XCTAssertEqual(Set(PadProfiles.RoutingMode.shown), Set(PadProfiles.RoutingMode.allCases))
        XCTAssertEqual(Set(PadProfiles.RoutingMode.allCases.map(\.title)).count, PadProfiles.RoutingMode.allCases.count)
        XCTAssertEqual(Set(PadProfiles.ButtonRoute.allCases.map(\.title)).count, 4)
    }

    func testCategoriesCanBeDraggedIntoPlace() throws {
        LibraryOrganizer.save(LibraryOrganizer.Saved())
        defer { LibraryOrganizer.save(LibraryOrganizer.Saved()) }
        for n in ["A", "B", "C"] { try LibraryOrganizer.addCategory(n) }
        LibraryOrganizer.moveCategory("C", before: "A")
        XCTAssertEqual(LibraryOrganizer.categories, ["C", "A", "B"])
        LibraryOrganizer.moveCategory("C", before: "B")
        XCTAssertEqual(LibraryOrganizer.categories, ["A", "C", "B"])
        LibraryOrganizer.moveCategory("A", before: "A"); LibraryOrganizer.moveCategory("X", before: "A")
        XCTAssertEqual(LibraryOrganizer.categories, ["A", "C", "B"])
    }
}
