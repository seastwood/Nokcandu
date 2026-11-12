import XCTest
@testable import NokcanduCore
import NokcanduPadEngine

/// A trackpad as four directions, and the edge ring as an input of its own.
final class SteamPadZoneTests: XCTestCase {
    private func settings(_ mode: PadSteamTrackpadSettings.Mode, edge: Double? = nil, rotation: Double? = 0) -> PadSteamTrackpadSettings {
        var s = PadSteamTrackpadSettings(mode: mode); s.edge = edge; s.rotation = rotation; return s
    }

    func testDirectionsAreEightWayWithACentreDeadZone() {
        var z = PadSteamPadZones(); let s = settings(.directions)
        XCTAssertEqual(z.update(side: 0, down: true, x: 0, y: 0.1, settings: s), [])
        XCTAssertEqual(z.update(side: 0, down: true, x: 0, y: 0.6, settings: s), [.lpup])
        XCTAssertEqual(z.update(side: 0, down: true, x: 0.5, y: 0.5, settings: s), [.lpup, .lpright])
        XCTAssertEqual(z.update(side: 0, down: true, x: 0.6, y: 0, settings: s), [.lpright])
        XCTAssertEqual(z.update(side: 0, down: true, x: -0.5, y: -0.5, settings: s), [.lpdown, .lpleft])
        XCTAssertEqual(z.update(side: 0, down: false, x: -0.5, y: -0.5, settings: s), [], "lifting lets everything go")
        XCTAssertEqual(PadSteamPadZones().held, [])
        var right = PadSteamPadZones()
        XCTAssertEqual(right.update(side: 1, down: true, x: -0.7, y: 0, settings: s), [.rpleft])
    }

    func testEdgeIsHeldAtTheRimInEveryBehaviorAndHasASize() {
        for mode in PadSteamTrackpadSettings.Mode.allCases {
            var z = PadSteamPadZones(); let s = settings(mode, edge: 0.2)
            XCTAssertFalse(z.update(side: 0, down: true, x: 0.5, y: 0, settings: s).contains(.lpedge), "\(mode)")
            XCTAssertTrue(z.update(side: 0, down: true, x: 0.85, y: 0, settings: s).contains(.lpedge), "\(mode)")
            // A finger resting on the boundary doesn't chatter: it stays held slightly inside it.
            XCTAssertTrue(z.update(side: 0, down: true, x: 0.78, y: 0, settings: s).contains(.lpedge))
            XCTAssertFalse(z.update(side: 0, down: true, x: 0.7, y: 0, settings: s).contains(.lpedge))
        }
        var z = PadSteamPadZones()
        XCTAssertEqual(z.update(side: 0, down: true, x: 0, y: 0.95, settings: settings(.directions, edge: 0.2)), [.lpup, .lpedge], "walk and sprint together")
        XCTAssertEqual(z.update(side: 0, down: true, x: 0, y: 0.95, settings: settings(.directions)), [.lpup], "no edge unless a size is set")
        XCTAssertEqual(PadSteamPadZones.edgeSize(settings(.mouse, edge: 0.01)), 0)
        XCTAssertEqual(PadSteamPadZones.edgeSize(settings(.mouse, edge: 3)), 0.6)
    }

    func testPadAngleTurnsTheDirections() {
        var z = PadSteamPadZones()
        // Straight up on the raw pad, with the pad turned 30°, is past the up/left boundary only when far enough round.
        XCTAssertEqual(z.update(side: 1, down: true, x: 0.6, y: 0, settings: settings(.directions, rotation: 30)), [.rpright, .rpup])
        z.reset()
        XCTAssertEqual(z.update(side: 1, down: true, x: 0.6, y: 0, settings: settings(.directions, rotation: 0)), [.rpright])
    }

    func testDirectionsDoNotMoveThePointer() {
        var pad = PadSteamTrackpad(); let s = settings(.directions)
        _ = pad.touch(down: true, x: 0.2, y: 0.5, at: 1, settings: s)
        XCTAssertEqual(pad.touch(down: true, x: 0.8, y: 0.5, at: 1.004, settings: s), PadSteamTrackpad.Motion())
    }

    func testEngineHoldsWhatTheEdgeAndDirectionsAreSetTo() throws {
        var p = PadProfiles.Profile(name: "Steam")
        p.layers[0][.lpup] = .as(.key(13)); p.layers[0][.lpedge] = .as(.key(56))
        var keys: [Int32: Bool] = [:]
        let box = Unmanaged.passRetained(KeyBox { k, d in keys[k] = d })
        defer { box.release() }
        var sink = pe_sink(); sink.ctx = box.toOpaque()
        sink.key = { ctx, k, d in Unmanaged<KeyBox>.fromOpaque(ctx!).takeUnretainedValue().note(k, d) }
        let engine = try XCTUnwrap(PadProfiles.compile(p, all: [p]).withCString { pe_create($0, sink) })
        defer { pe_destroy(engine) }
        pe_pad_zone(engine, pe_input_named("lpup"), true, 1); pe_tick(engine, 1.01)
        XCTAssertEqual(keys[13], true); XCTAssertNil(keys[56])
        pe_pad_zone(engine, pe_input_named("lpedge"), true, 1.02); pe_tick(engine, 1.03)
        XCTAssertEqual(keys[56], true)
        pe_pad_zone(engine, pe_input_named("lpedge"), false, 1.04); pe_tick(engine, 1.05)
        XCTAssertEqual(keys[56], false); XCTAssertEqual(keys[13], true)
        pe_pad_zone(engine, pe_input_named("a"), true, 1.06)        // not a pad zone: ignored
        pe_release_main(engine, 1.1)
        XCTAssertEqual(keys[13], false)
    }

    func testSettingsRoundTripAndOlderProfilesDecode() throws {
        var s = settings(.directions, edge: 0.25); s.deadzone = 0.3
        XCTAssertEqual(try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: JSONEncoder().encode(s)), s)
        let old = try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: Data(#"{"mode":"trackball","sensitivity":900,"halfLife":0.2,"invertY":false}"#.utf8))
        XCTAssertNil(old.edge); XCTAssertEqual(PadSteamPadZones.edgeSize(old), 0)
    }
}

private final class KeyBox {
    let note: (Int32, Bool) -> Void
    init(_ note: @escaping (Int32, Bool) -> Void) { self.note = note }
}
