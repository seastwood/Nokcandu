import XCTest
@testable import NokcanduCore

final class OverlayMappingLabelTests: XCTestCase {
    func testKeysUseTheirSymbolsAndLettersAsThemselves() {
        XCTAssertEqual(PadLabel.key(49), "␣")
        XCTAssertEqual(PadLabel.key(56), "⇧")
        XCTAssertEqual(PadLabel.key(59), "⌃")
        XCTAssertEqual(PadLabel.key(14), "E")
        XCTAssertEqual(PadLabel.key(12), "Q")
    }

    func testModifiersRunIntoTheKey() {
        XCTAssertEqual(PadLabel.outputs([.key(59), .key(8)]), "⌃C")
        XCTAssertEqual(PadLabel.outputs([.key(14), .mouse(.left)]), "E+LMB")
    }

    func testHoldAndDoubleTapGoOnTheSecondLine() {
        var b = PadProfiles.Binding()
        b.tap = [.key(15)]; b.hold = [.key(49)]
        XCTAssertEqual(PadLabel.text(b), PadLabel.Text(main: "R", second: "⏱␣"))
        var d = PadProfiles.Binding()
        d.press = [.key(14)]; d.double = [.key(12)]
        XCTAssertEqual(PadLabel.text(d), PadLabel.Text(main: "E", second: "²Q"))
        XCTAssertNil(PadLabel.text(PadProfiles.Binding()))
    }

    func testLongNamesAreShortened() {
        XCTAssertEqual(PadLabel.abbreviate("Crouch Walk"), "CW")
        XCTAssertEqual(PadLabel.abbreviate("Reload"), "Relo")
        XCTAssertEqual(PadLabel.abbreviate("Map"), "Map")
    }

    func testAButtonThatPressesItselfShowsNothing() {
        var b = PadProfiles.Binding(); b.press = [.pad(.a)]
        XCTAssertTrue(OverlayMappingRules.isItself(b, .a))
        b.press = [.key(49)]
        XCTAssertFalse(OverlayMappingRules.isItself(b, .a))
    }

    func testStickLabelsByMode() {
        var s = PadProfiles.Stick(); s.mode = .keys
        XCTAssertEqual(OverlayMappingRules.stick(s, side: 0, label: { _ in nil })?.around, ["W", "S", "A", "D"])
        s.mode = .stick
        XCTAssertNil(OverlayMappingRules.stick(s, side: 0, label: { _ in nil }))
        s.mode = .directions; s.directionsScroll = true
        let labels: [PadProfiles.Input: String] = [.lsleft: "V", .lsright: "T"]
        XCTAssertEqual(OverlayMappingRules.stick(s, side: 0, label: { labels[$0].map { PadLabel.Text(main: $0) } })?.around, ["⇡", "⇣", "V", "T"])
    }

    func testCompassReadsLikeWASD() {
        XCTAssertEqual(OverlayMappingRules.compass(["W", "S", "A", "D"]), "WASD")
        XCTAssertEqual(OverlayMappingRules.compass(["Up", "Down", "Left", "Right"]), "Up Le Do Ri")
    }

    func testDirectionPadShowsFourSectorsAndHighlightsTheHeldOne() {
        var s = PadSteamTrackpadSettings(mode: .directions)
        s.edge = 0
        let f = OverlayPadFace.steamPad(side: 0, settings: s, label: { $0 == .lpup ? PadLabel.Text(main: "W") : nil },
                                        held: [.lpup], toggled: [], clickInput: .touchpad, clicked: false)
        XCTAssertEqual(f.regions.count, 4)
        XCTAssertEqual(f.regions.first?.text?.main, "W")
        XCTAssertEqual(f.regions.filter(\.active).count, 1)
        XCTAssertTrue(f.regions.allSatisfy { if case .sector = $0.shape { return true }; return false })
    }

    func testEdgeRingIsItsOwnRegionOutsideTheZones() {
        var s = PadSteamTrackpadSettings(mode: .mouse)
        s.edge = 0.2
        let f = OverlayPadFace.steamPad(side: 1, settings: s, label: { $0 == .rpedge ? PadLabel.Text(main: "⇧") : nil },
                                        held: [], toggled: [.rpedge], clickInput: .rpclick, clicked: false)
        XCTAssertEqual(f.regions.count, 1)
        XCTAssertEqual(f.regions[0].shape, .sector(from: 0, to: 360, inner: 0.8, outer: 1))
        XCTAssertTrue(f.regions[0].toggled)
        XCTAssertEqual(f.centre, "Mouse")
    }
}
