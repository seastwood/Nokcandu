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
        XCTAssertEqual(PadProfiles.compile(plain, all: [plain]), "nokpad 1\n")
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
