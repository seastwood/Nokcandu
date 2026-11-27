import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

final class PadAccessibilityTests: XCTestCase {
    func testEveryHoldBecomesAToggle() {
        var l = PadProfiles.Layer(name: "Base")
        l[.a] = .as(.key(12)); l[.lb] = .as(.layerHold("Aim")); l[.x] = .as(.macro("m"))
        let t = PadAccessibility.holdsAsToggles(l, base: true)
        XCTAssertEqual(t[.a]?.press, [.keyToggle(12)]); XCTAssertEqual(t[.lb]?.press, [.layerToggle("Aim")])
        XCTAssertEqual(t[.x]?.press, [.macro("m")], "macros stay")
        XCTAssertEqual(t[.b]?.press, [.padToggle(.b)], "a button left as itself toggles itself")
        XCTAssertNil(t[.guide], "the system button stays")
        XCTAssertTrue(PadAccessibility.togglesHolds(t))
        // In the engine: one press holds, the next lets go.
        var p = PadProfiles.Profile(id: "p", name: "P"); p.layers[0] = t
        let r = PadRecorder(String(PadProfiles.compile(p, all: [p]).dropFirst("nokpad 1\n".count)))
        r.press("a", true, 1); r.press("a", false, 1.1)
        XCTAssertEqual(r.take(), ["key 12 down"])
        r.press("a", true, 2); r.press("a", false, 2.1)
        XCTAssertEqual(r.take(), ["key 12 up"])
    }
    func testOneHandedLeft() {
        let p = PadAccessibility.oneHanded(PadProfiles.Profile(id: "p", name: "P"), left: true)
        XCTAssertEqual(p.layers[0][.lb]?.press, [.layerHold("Right side")])
        let side = p.layers[1]
        XCTAssertEqual(side[.down]?.press, [.pad(.a)]); XCTAssertEqual(side.leftStick?.mode, .otherStick)
        XCTAssertEqual(PadAccessibility.oneHanded(p, left: true).layers.count, 2, "again: the same layer, not another")
        let r = PadRecorder(String(PadProfiles.compile(p, all: [p]).dropFirst("nokpad 1\n".count)))
        r.press("lb", true, 1); r.press("down", true, 1.1); r.press("down", false, 1.2); r.press("lb", false, 1.3)
        XCTAssertEqual(r.take(), ["pad a down", "pad a up"])
    }
}
