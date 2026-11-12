import XCTest
@testable import NokcanduCore

final class PadLayerImportTests: XCTestCase {
    func testCopiesExplicitLayerSettingsAndRenamesSelfReferencesWithoutChangingDestination() throws {
        var source = PadProfiles.Profile(name: "Source")
        var layer = PadProfiles.Layer(name: "MacOS")
        layer[.a] = .as(.layerToggle("macos"))
        layer.leftStick = PadProfiles.Stick(mode: .mouse)
        layer.color = "#123456"
        source.layers.append(layer)
        var destination = PadProfiles.Profile(name: "Destination")
        destination.base[.b] = .as(.key(12))
        destination.layers.append(PadProfiles.Layer(name: "MACOS"))
        let prior = destination
        let result = try PadProfiles.importingLayer(from: source, layerID: layer.id, into: destination, all: [])
        XCTAssertEqual(destination, prior)
        XCTAssertEqual(result.base, prior.base)
        XCTAssertEqual(result.layers.last?.name, "MacOS (2)")
        XCTAssertNotEqual(result.layers.last?.id, layer.id)
        XCTAssertEqual(result.layers.last?[.a]?.press, [.layerToggle("MacOS (2)")])
        XCTAssertEqual(result.layers.last?.leftStick?.mode, .mouse)
        XCTAssertEqual(result.layers.last?.color, layer.color)
    }
    func testClonesNestedInheritedMenuAndMacroDependenciesDespiteIDCollision() throws {
        var under = PadProfiles.Profile(id: "under", name: "Under")
        under.macros = [.init(id: "macro", name: "Original", steps: [.init(.chord)])]
        under.macros![0].steps[0].outputs = [.key(13), .key(59)]
        under.menus = [.init(id: "menu", name: "Menu", slices: [.init(title: "", outputs: [.macro("macro")])])]
        var source = PadProfiles.Profile(name: "Source", buildsOn: [under.id])
        source.base[.a] = .as(.menu("menu"))
        source.base[.b] = .as(.macro("macro"))
        var destination = PadProfiles.Profile(name: "Destination")
        destination.macros = [.init(id: "macro", name: "Keep", steps: [.init(.press, output: .key(0))])]
        let result = try PadProfiles.importingLayer(from: source, layerID: source.base.id, into: destination, all: [under])
        XCTAssertEqual(result.macros?.count, 2)
        XCTAssertEqual(result.macros?.first, destination.macros?.first)
        let newMacro = try XCTUnwrap(result.macros?.last)
        let newMenu = try XCTUnwrap(result.menus?.first)
        XCTAssertNotEqual(newMacro.id, "macro")
        XCTAssertNotEqual(newMenu.id, "menu")
        XCTAssertEqual(newMenu.slices[0].outputs, [.macro(newMacro.id)])
        XCTAssertEqual(result.layers.last?[.b]?.press, [.macro(newMacro.id)])
        XCTAssertEqual(newMacro.steps[0].outputs, [.key(13), .key(59)])
    }
    func testMissingReferencesAndCapacityFailWithoutPartialEdits() throws {
        var source = PadProfiles.Profile(name: "Source")
        source.base[.a] = .as(.macro("missing"))
        let destination = PadProfiles.Profile(name: "Destination")
        XCTAssertThrowsError(try PadProfiles.importingLayer(from: source, layerID: source.base.id, into: destination, all: []))
        XCTAssertNil(destination.macros)
        source.base[.a] = .as(.layerHold("Absent"))
        XCTAssertThrowsError(try PadProfiles.importingLayer(from: source, layerID: source.base.id, into: destination, all: []))
        var full = destination
        full.layers += (1...7).map { PadProfiles.Layer(name: "Layer \($0)") }
        XCTAssertThrowsError(try PadProfiles.importingLayer(from: source, layerID: source.base.id, into: full, all: []))
        source.base.bindings = ["dev.unavailable.b0": .as(.key(13))]
        XCTAssertThrowsError(try PadProfiles.importingLayer(from: source, layerID: source.base.id, into: destination, all: []))
    }
}
