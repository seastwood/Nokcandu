import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

/// A layer with routing of its own: the game's controller controls switched on and off by a layer.
final class LayerRoutingTests: XCTestCase {
    func testLayerPassesTheControllerOnAndBack() {
        // Base: only mappings. Layer 1 (toggled by back): the controller itself, back still toggling.
        let r = PadRecorder("""
        bind 0 a press=key:12
        bind 0 back press=layer:toggle:1
        route a mapped
        route back mapped
        route a native layer=1
        route back standard layer=1
        route lstick native layer=1
        """)
        r.press("a", true, 1); r.press("a", false, 1.1)
        r.press("back", true, 2); r.press("back", false, 2.05)          // the controller itself
        r.press("a", true, 3); r.press("a", false, 3.1)
        r.press("back", true, 4); r.press("back", false, 4.05)          // back to mappings only
        r.press("a", true, 5); r.press("a", false, 5.1)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up", "pad a down", "pad a up", "key 12 down", "key 12 up"])
    }

    func testAHeldButtonKeepsItsPressRouteAcrossALayerChange() {
        let r = PadRecorder("""
        bind 0 lb press=layer:hold:1
        bind 0 a press=key:12
        route lb mapped
        route a mapped
        route lb native layer=1
        route a native layer=1
        """)
        r.press("a", true, 1)                    // pressed as a mapping
        r.press("lb", true, 2)                   // layer 1: the controller itself
        r.press("a", false, 3)                   // released as it was pressed: the key goes up
        r.press("lb", false, 4)                  // the hold pressed in the base layer ends the layer
        r.press("a", true, 5); r.press("a", false, 5.1)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up", "key 12 down", "key 12 up"])
    }

    func testCompiledLayerRoutes() {
        var p = PadProfiles.Profile(id: "p", name: "P", layers: [.init(id: "b", name: "Base"), .init(id: "x", name: "Xbox")])
        p.routingMode = .remappingAll
        p.layers[0][.back] = PadProfiles.Binding(press: [.layerToggle("Xbox")])
        p.layers[1].routingMode = .native
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.contains("route a mapped\n"))
        XCTAssertTrue(text.contains("route a native layer=1\n"))
        XCTAssertTrue(text.contains("route back standard layer=1\n"), "the button that switches layers keeps doing so")
        XCTAssertTrue(text.contains("route gyro native layer=1\n"))
        XCTAssertEqual(PadProfiles.routing(p, all: [p], layer: 1), .native)
        XCTAssertEqual(PadProfiles.routing(p, all: [p], layer: 0), .remappingAll)
        p.layers[1].routingMode = nil
        XCTAssertFalse(PadProfiles.compile(p, all: [p]).contains("route a native layer=1"), "no table without a routing of its own")
    }

    func testNativeProfileWithAMappedLayerStillCompiles() {
        var p = PadProfiles.Profile(id: "p", name: "P", layers: [.init(id: "b", name: "Base"), .init(id: "k", name: "Keys")])
        p.routingMode = .native
        p.layers[0][.lb] = PadProfiles.Binding(press: [.layerHold("Keys")])
        p.layers[1][.a] = PadProfiles.Binding(press: [.key(12)])
        var plain = PadProfiles.Profile(id: "q", name: "Q"); plain.routingMode = .native
        XCTAssertFalse(PadProfiles.compile(plain, all: [plain]).contains("route"), "the controller itself: nothing compiled but its players")
        p.layers[1].routingMode = .remappingAll
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.contains("route a native\n")); XCTAssertTrue(text.contains("route lb standard\n"))
        XCTAssertTrue(text.contains("route a mapped layer=1\n"))
    }

    func testLayerRoutingIsSaved() throws {
        var l = PadProfiles.Layer(name: "Xbox"); l.routingMode = .native
        XCTAssertEqual(try JSONDecoder().decode(PadProfiles.Layer.self, from: JSONEncoder().encode(l)).routingMode, .native)
        XCTAssertNil(try JSONDecoder().decode(PadProfiles.Layer.self, from: Data(#"{"id":"x","name":"X","bindings":{}}"#.utf8)).routingMode)
    }
}

final class AntiDeadzoneTests: XCTestCase {
    func testSmallMovementStartsPastTheGamesDeadzone() {
        let r = PadRecorder("stick 0 mode=pad to=0 dz=0.1 outer=1 anti=0.25")
        pe_axis(r.engine, 0, 0, 1); pe_axis(r.engine, 1, 0, 1)
        XCTAssertEqual(r.axes[0], 0, "inside its own dead zone: still nothing")
        pe_axis(r.engine, 0, Int32(0.12 * 32767), 1.1)
        XCTAssertGreaterThan(r.axes[0], Int(0.25 * 32767), "just past it: beyond the game's")
        XCTAssertLessThan(r.axes[0], Int(0.28 * 32767))
        pe_axis(r.engine, 0, 32767, 1.2)
        XCTAssertEqual(r.axes[0], 32767, "full stays full")
        let plain = PadRecorder("stick 0 mode=pad to=0 dz=0.1 outer=1")
        pe_axis(plain.engine, 0, Int32(0.12 * 32767), 1)
        XCTAssertLessThan(plain.axes[0], Int(0.05 * 32767))
    }
    func testCompiledOnlyWhenSet() {
        var p = PadProfiles.Profile(id: "p", name: "P")
        p.leftStick = PadProfiles.Stick()
        XCTAssertFalse(PadProfiles.compile(p, all: [p]).contains("anti="))
        p.leftStick?.antiDeadzone = 0.2
        XCTAssertTrue(PadProfiles.compile(p, all: [p]).contains(" anti=0.2"))
    }
}

final class CoopPlayersTests: XCTestCase {
    func testCompiledPlayersAndTheEngineIgnoresOtherPlayersBlocks() {
        var p = PadProfiles.Profile(id: "p", name: "P"), q = PadProfiles.Profile(id: "q", name: "Q")
        p.layers[0][.a] = PadProfiles.Binding(press: [.key(12)])
        q.layers[0][.a] = PadProfiles.Binding(press: [.key(13)])
        let plain = PadProfiles.compile(p, all: [p, q])
        XCTAssertTrue(plain.contains("player 2 asis\n")); XCTAssertTrue(plain.contains("player 8 asis\n"), "unset: as it is")
        p.players = [.same, .profile("q")]
        let text = PadProfiles.compile(p, all: [p, q])
        XCTAssertTrue(text.contains("player 2 same\n"))
        XCTAssertTrue(text.contains("player 3 begin\nnokpad 1\n")); XCTAssertTrue(text.contains("player 3 end\n"))
        XCTAssertTrue(text.contains("player 4 begin\n"), "later players follow the last one set")
        XCTAssertFalse(text.contains("player 3 begin\nnokpad 1\nplayer"), "the other profile's own players aren't nested")
        // Player 1's engine runs only its own lines: a stays key 12, not the embedded profile's 13.
        let r = PadRecorder(String(text.dropFirst("nokpad 1\n".count)))
        r.press("a", true, 1); r.press("a", false, 1.1)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up"])
        p.players = [.profile("p")]
        XCTAssertTrue(PadProfiles.compile(p, all: [p]).contains("player 2 same\n"), "itself: the same profile")
        p.players = [.profile("gone")]
        XCTAssertTrue(PadProfiles.compile(p, all: [p]).contains("player 2 asis\n"), "a deleted profile: as it is")
    }
}
