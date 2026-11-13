import XCTest
@testable import NokcanduCore
import NokcanduPadEngine

/// A trackpad divided into zones: each zone's tap, double tap and click, falling back to the pad's own.
final class SteamPadZoneRoutingTests: XCTestCase {
    func testLayoutsPutAFingerInTheRightZone() {
        XCTAssertEqual(PadSteamZoneLayout.leftRight.zone(x: -0.5, y: 0), 0); XCTAssertEqual(PadSteamZoneLayout.leftRight.zone(x: 0.5, y: 0), 1)
        XCTAssertEqual(PadSteamZoneLayout.topBottom.zone(x: 0, y: 0.5), 0); XCTAssertEqual(PadSteamZoneLayout.topBottom.zone(x: 0, y: -0.5), 1)
        XCTAssertEqual([(-0.5, 0.5), (0.5, 0.5), (-0.5, -0.5), (0.5, -0.5)].map { PadSteamZoneLayout.quadrants.zone(x: $0.0, y: $0.1) }, [0, 1, 2, 3])
        XCTAssertEqual([(0.1, 0.1), (0, 0.7), (0, -0.7), (-0.7, 0), (0.7, 0)].map { PadSteamZoneLayout.cross.zone(x: $0.0, y: $0.1) }, [0, 1, 2, 3, 4])
        XCTAssertNil(PadSteamZoneLayout.off.zone(x: 0, y: 0))
        XCTAssertEqual(PadSteamZoneLayout.allCases.map { $0.names.count }, [0, 2, 2, 4, 5])
        // Zones turn with the pad angle: just right of the top, turned 30°, lands left of the divider.
        XCTAssertEqual(PadSteamZoneLayout.leftRight.zone(x: 0.1, y: 0.8, rotation: 30), 0)
        XCTAssertEqual(PadSteamZoneLayout.leftRight.zone(x: 0.1, y: 0.8), 1)
    }

    func testATapGoesToItsZoneOnlyWhenTheZoneDoesSomething() {
        var s = PadSteamTrackpadSettings(mode: .trackball); s.zoneLayout = .quadrants; s.rotation = 0
        let some: Set<PadProfiles.Input> = [.lpt2]
        XCTAssertEqual(PadSteamZoneRouter.tap(side: 0, x: 0.5, y: 0.5, settings: s) { some.contains($0) }, .lpt2)
        XCTAssertEqual(PadSteamZoneRouter.tap(side: 0, x: -0.5, y: 0.5, settings: s) { some.contains($0) }, .lptap, "empty zone: the pad's own tap")
        s.zoneLayout = nil
        XCTAssertEqual(PadSteamZoneRouter.tap(side: 0, x: 0.5, y: 0.5, settings: s) { _ in true }, .lptap)
        XCTAssertEqual(PadSteamZoneRouter.tap(side: 1, x: 0.5, y: 0.5, settings: s) { _ in true }, .rptap)
    }

    func testAClickInAZoneReplacesThePadsOwnClickUntilItIsLetGo() {
        var s = PadSteamTrackpadSettings(mode: .mouse); s.zoneLayout = .leftRight; s.rotation = 0
        var r = PadSteamZoneRouter(); let bound: Set<PadProfiles.Input> = [.rpc2]
        var out = r.click(side: 1, down: true, touching: true, x: 0.6, y: 0, settings: s) { bound.contains($0) }
        XCTAssertEqual(out.change?.input, .rpc2); XCTAssertEqual(out.change?.down, true); XCTAssertTrue(out.suppress)
        out = r.click(side: 1, down: true, touching: true, x: -0.6, y: 0, settings: s) { bound.contains($0) }
        XCTAssertNil(out.change, "sliding into another zone while clicked keeps the first"); XCTAssertTrue(out.suppress)
        out = r.click(side: 1, down: false, touching: true, x: -0.6, y: 0, settings: s) { bound.contains($0) }
        XCTAssertEqual(out.change?.input, .rpc2); XCTAssertEqual(out.change?.down, false)
        // The empty left zone: the pad's own click.
        out = r.click(side: 1, down: true, touching: true, x: -0.6, y: 0, settings: s) { bound.contains($0) }
        XCTAssertNil(out.change); XCTAssertFalse(out.suppress)
        out = r.click(side: 1, down: false, touching: true, x: -0.6, y: 0, settings: s) { bound.contains($0) }
        XCTAssertNil(out.change); XCTAssertFalse(out.suppress)
        // No finger reading: the pad's own click.
        out = r.click(side: 1, down: true, touching: false, x: 0.6, y: 0, settings: s) { bound.contains($0) }
        XCTAssertNil(out.change); XCTAssertFalse(out.suppress)
    }

    func testEngineKnowsWhatIsBoundInTheLayersOn() {
        let r = PadRecorder("bind 0 lpc1 press=key:49\nbind 1 lpc2 press=key:50\nbind 0 lb press=layer:hold:1")
        XCTAssertTrue(pe_input_bound(r.engine, pe_input_named("lpc1")))
        XCTAssertFalse(pe_input_bound(r.engine, pe_input_named("lpc2")), "only in a layer that is off")
        r.press("lb", true, 1); r.tick(1.01)
        XCTAssertTrue(pe_input_bound(r.engine, pe_input_named("lpc2")))
        XCTAssertFalse(pe_input_bound(r.engine, -1))
        pe_pad_zone(r.engine, pe_input_named("lpc2"), true, 1.1); r.tick(1.11)
        pe_pad_zone(r.engine, pe_input_named("lpc2"), false, 1.2); r.tick(1.21)
        XCTAssertTrue(r.take().contains("key 50 down"))
        XCTAssertEqual(PadProfiles.Input.lpt3.title(), "Left pad zone 3 tap"); XCTAssertEqual(PadProfiles.Input.rpc5.title(), "Right pad zone 5 click")
        XCTAssertTrue(PadProfiles.Input.rpc5.isVirtual)
        for i in PadProfiles.Input.padZoneInputs { XCTAssertGreaterThanOrEqual(pe_input_named(i.rawValue), 0, i.rawValue) }
    }

    func testZoneSettingsRoundTrip() throws {
        var s = PadSteamTrackpadSettings(mode: .stick); s.zoneLayout = .cross
        XCTAssertEqual(try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: JSONEncoder().encode(s)), s)
    }
}

final class SteamRumbleTests: XCTestCase {
    func testRumbleIsAFiniteRepeatedPulseOnEachPad() throws {
        for strong in [false, true] {
            let l = try XCTUnwrap(SteamControllerHaptics.rumble(side: 0, strong: strong)), r = try XCTUnwrap(SteamControllerHaptics.rumble(side: 1, strong: strong))
            XCTAssertEqual(l.count, 64); XCTAssertEqual(Array(l.prefix(3)), [0x8f, 7, 1]); XCTAssertEqual(r[2], 0)
            let on = Int(l[3]) | Int(l[4]) << 8, off = Int(l[5]) | Int(l[6]) << 8, count = Int(l[7]) | Int(l[8]) << 8
            let seconds = Double((on + off) * count) / 1_000_000
            XCTAssertEqual(seconds, strong ? 0.4 : 0.15, accuracy: 0.01)
            XCTAssertGreaterThan(on, 1000, "stronger than a movement pulse")
        }
        XCTAssertNil(SteamControllerHaptics.rumble(side: 2, strong: true))
        let soft = try XCTUnwrap(SteamControllerHaptics.rumble(side: 0, strength: 0.2, seconds: 0.1))
        let hard = try XCTUnwrap(SteamControllerHaptics.rumble(side: 0, strength: 1, seconds: 0.1))
        XCTAssertLessThan(Int(soft[3]) | Int(soft[4]) << 8, Int(hard[3]) | Int(hard[4]) << 8, "a softer rumble drives the pad for less of each pulse")
        let period = { (b: [UInt8]) in (Int(b[3]) | Int(b[4]) << 8) + (Int(b[5]) | Int(b[6]) << 8) }
        XCTAssertEqual(period(soft), period(hard), "the same buzz, only softer")
        let long = try XCTUnwrap(SteamControllerHaptics.rumble(side: 0, strength: 0.5, seconds: 5))
        XCTAssertLessThanOrEqual(Double(period(long) * (Int(long[7]) | Int(long[8]) << 8)) / 1_000_000, 1.0, "never longer than a second")
        XCTAssertNil(SteamControllerHaptics.rumble(side: 0, strength: 0, seconds: 0.1))
    }
}

final class SteamPadDialTests: XCTestCase {
    /// A thumb circling the pad at radius 0.8, from `from` degrees by `by` degrees in 2° steps.
    private func circle(_ dial: inout PadSteamDial, from: Double, by: Double, _ s: PadSteamTrackpadSettings) -> Int {
        var total = 0, a = from
        let step = by > 0 ? 2.0 : -2.0
        for _ in 0..<Int(abs(by) / 2) {
            a += step
            total += dial.update(down: true, x: 0.8 * cos(a * .pi / 180), y: 0.8 * sin(a * .pi / 180), settings: s)
        }
        return total
    }
    func testCirclingScrollsOneStepPerTurnAndClockwiseScrollsDown() {
        var s = PadSteamTrackpadSettings(mode: .dial); s.dialStep = 30
        var d = PadSteamDial()
        _ = d.update(down: true, x: 0.8, y: 0, settings: s)
        XCTAssertEqual(circle(&d, from: 0, by: 360, s), 12, "counter-clockwise: twelve steps up per turn at 30°")
        XCTAssertEqual(circle(&d, from: 0, by: -180, s), -6, "clockwise scrolls down")
        s.dialReverse = true
        XCTAssertEqual(circle(&d, from: -180, by: 90, s), -3, "reversed")
    }
    func testTheCentreAndLiftingDoNothing() {
        let s = PadSteamTrackpadSettings(mode: .dial)
        var d = PadSteamDial()
        for n in 0..<50 { XCTAssertEqual(d.update(down: true, x: 0.1 * cos(Double(n)), y: 0.1 * sin(Double(n)), settings: s), 0) }
        _ = d.update(down: true, x: 0.8, y: 0, settings: s)
        _ = d.update(down: false, x: 0, y: 0, settings: s)
        XCTAssertEqual(d.update(down: true, x: -0.8, y: 0, settings: s), 0, "landing elsewhere is not a turn")
        XCTAssertEqual(PadSteamDial.step(PadSteamTrackpadSettings()), 30)
        var pad = PadSteamTrackpad()
        _ = pad.touch(down: true, x: 0.9, y: 0.5, at: 1, settings: s)
        XCTAssertEqual(pad.touch(down: true, x: 0.5, y: 0.9, at: 1.004, settings: s), PadSteamTrackpad.Motion(), "a scroll wheel doesn't move the pointer")
    }
    func testDialSettingsRoundTrip() throws {
        var s = PadSteamTrackpadSettings(mode: .dial); s.dialStep = 20; s.dialReverse = true; s.dialHaptic = 0.25
        XCTAssertEqual(try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: JSONEncoder().encode(s)), s)
    }
}
