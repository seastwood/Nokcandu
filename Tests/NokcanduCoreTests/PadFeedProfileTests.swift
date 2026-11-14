import XCTest
@testable import NokcanduCore
import NokcanduPadEngine

/// November 13, 2026: a profile reading the Steam Controller directly with an emulated Xbox controller should give
/// games that controller with the profile's inputs, not the raw controller mapped Wine's way.
final class PadFeedProfileTests: XCTestCase {
    func testAProfileThatReadsTheControllerItselfSaysSoToWinesDriver() throws {
        var p = PadProfiles.Profile(id: "s", name: "Steam Controller xbox")
        p.controllerSource = .steamUSB; p.presentAs = .xbox
        p.layers[0][.lt] = .as(.trigger(right: true))
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.contains("\npresent xbox\n"))
        XCTAssertTrue(text.contains("\nsource steam\n"), "the driver looks for this exact line")
        let engine = try XCTUnwrap(text.withCString { pe_create($0, pe_sink()) }, "the engine skips the line")
        pe_destroy(engine)
        p.controllerSource = .automatic
        XCTAssertFalse(PadProfiles.compile(p, all: [p]).contains("source steam"))
        p.controllerSource = .steamUSB; p.routingMode = .native
        XCTAssertEqual(PadProfiles.compile(p, all: [p]), "nokpad 1\npresent xbox\nsource steam\n")
    }

    func testGameRumbleDefaultsGentlerAndIsSavedPerProfile() throws {
        var p = PadProfiles.Profile(id: "s", name: "S")
        XCTAssertNil(p.gameRumble)
        XCTAssertLessThan(PadProfiles.Profile.defaultGameRumble, 1)
        p.gameRumble = 0.25
        let back = try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.gameRumble, 0.25)
    }
}
