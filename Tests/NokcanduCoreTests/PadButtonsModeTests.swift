import XCTest
@testable import NokcanduCore

final class PadButtonsModeTests: XCTestCase {
    func testRadialZonesClockwiseFromTheTopWithAFreeMiddle() {
        XCTAssertEqual(PadSteamZoneLayout.ring4.zone(x: 0, y: 0.8), 0)      // up
        XCTAssertEqual(PadSteamZoneLayout.ring4.zone(x: 0.8, y: 0), 1)      // right
        XCTAssertEqual(PadSteamZoneLayout.ring4.zone(x: 0, y: -0.8), 2)     // down
        XCTAssertEqual(PadSteamZoneLayout.ring4.zone(x: -0.8, y: 0), 3)     // left
        XCTAssertNil(PadSteamZoneLayout.ring4.zone(x: 0.1, y: 0.1))         // the middle
        XCTAssertEqual(PadSteamZoneLayout.ring8.zone(x: 0.6, y: 0.6), 1)    // up right
        XCTAssertEqual(PadSteamZoneLayout.ring8.zone(x: -0.6, y: 0.6), 7)   // up left
        XCTAssertEqual(PadSteamZoneLayout.ring6.zone(x: 0, y: -0.9), 3)     // bottom
        XCTAssertEqual(PadSteamZoneLayout.ring8.names.count, 8)
    }

    func testButtonsHoldTheZoneUnderTheFingerAndSlideBetweenThem() {
        var s = PadSteamTrackpadSettings(mode: .buttons); s.zoneLayout = .ring8
        var z = PadSteamPadZones()
        XCTAssertEqual(z.update(side: 0, down: true, x: 0, y: 0.8, settings: s), [.lpt1])
        XCTAssertEqual(z.update(side: 0, down: true, x: 0.8, y: 0, settings: s), [.lpt3])
        XCTAssertEqual(z.update(side: 1, down: true, x: -0.6, y: 0.6, settings: s), [.rpt8])
        XCTAssertEqual(z.update(side: 0, down: true, x: 0, y: 0, settings: s), [])         // resting in the middle
        XCTAssertEqual(z.update(side: 0, down: false, x: 0, y: 0.8, settings: s), [])
    }

    func testEightZonesAreMappableInputs() {
        XCTAssertEqual(PadProfiles.Input.padZoneTap(0, 7), .lpt8)
        XCTAssertEqual(PadProfiles.Input.padZoneClick(1, 5), .rpc6)
        XCTAssertTrue(PadProfiles.Input.rpt7.isVirtual)
        XCTAssertEqual(PadProfiles.Input.padZoneInputs.count, 32)
    }
}

final class PadProfileLinkTests: XCTestCase {
    func testALinkCarriesTheProfileAndComesBack() throws {
        var p = PadProfiles.Profile(name: "Shared")
        p.layers[0][.a] = .as(.key(49))
        let text = PadProfiles.exportText(p, all: [p])
        let url = try XCTUnwrap(PadProfileLink.make(text))
        XCTAssertEqual(url.scheme, "nokcandu"); XCTAssertEqual(url.host, "pad")
        XCTAssertFalse(url.absoluteString.contains("+") || url.absoluteString.contains("/p="))
        let back = try XCTUnwrap(PadProfileLink.text(url))
        XCTAssertEqual(try PadProfiles.parseShared(back).first?.name, "Shared")
        XCTAssertNil(PadProfileLink.text(URL(string: "nokcandu://pad?p=not-valid")!))
        XCTAssertNil(PadProfileLink.text(URL(string: "nokcandu://profile/12")!))
    }
}
