import XCTest
import NokcanduCore

final class SteamPadAngleAvailabilityTests: XCTestCase {
    func testFreshDefaultsAreStraightAndSavedAnglesSurviveBehaviorChanges() throws {
        for mode in PadSteamTrackpadSettings.Mode.allCases {
            var profile = PadProfiles.Profile(name: "Angle")
            profile.steamLeftTrackpad = PadSteamTrackpadSettings(mode: mode)
            XCTAssertEqual(PadProfiles.steamTrackpad(0, profile: profile, all: []).rotation, 0)
            profile.steamLeftTrackpad?.rotation = -22
            let decoded = try JSONDecoder().decode(PadProfiles.Profile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(PadProfiles.steamTrackpad(0, profile: decoded, all: []).rotation, -22)
        }
    }
    func testRotatedTapZonesWorkInEveryBehaviorIncludingDialAndExisting() {
        for mode in PadSteamTrackpadSettings.Mode.allCases {
            var s = PadSteamTrackpadSettings(mode: mode); s.zoneLayout = .quadrants; s.rotation = 0
            XCTAssertEqual(PadSteamZoneRouter.tap(side: 0, x: 0.8, y: -0.15, settings: s) { _ in true }, .lpt4)
            s.rotation = 30
            XCTAssertEqual(PadSteamZoneRouter.tap(side: 0, x: 0.8, y: -0.15, settings: s) { _ in true }, .lpt2)
        }
    }
    func testExistingTouchAndRightPadAxesUseAngleWithoutRotatingPhysicalStick() {
        var s = PadSteamTrackpadSettings(); s.rotation = 30
        let touch = s.normalizedTouch(x: 0.5, y: 0)
        XCTAssertEqual(touch.x, Float((cos(Double.pi / 6) * 0.5 + 1) / 2), accuracy: 0.00001)
        XCTAssertEqual(touch.y, 0.375, accuracy: 0.00001)
        var state = SteamControllerReport.state(counter: 1, flags: 1 << 20, leftTrigger: 0, rightTrigger: 0,
            stick: [0, 0], leftPad: [0, 0], rightPad: [16384, 0], leftTouch: false, gyro: [0, 0, 0], acceleration: [0, 0, 0])
        let axes = state.mappingAxes(left: .init(), right: s)
        XCTAssertEqual(axes[2]!, Int(16384 * cos(Double.pi / 6)), accuracy: 1)
        XCTAssertEqual(axes[3]!, -8192, accuracy: 1)
        state.kind = .steam2026; state.rightStick = .init(1, 0)
        let withStick = state.mappingAxes(left: .init(), right: s)
        XCTAssertEqual(withStick[2], 32767); XCTAssertEqual(withStick[3], 0)
    }
    func testDialRotationKeepsScrollStepsAndReversalAcrossAngleWrap() {
        for rotation in [-30.0, 0, 30] {
            var s = PadSteamTrackpadSettings(mode: .dial); s.rotation = rotation; s.dialStep = 30
            for reverse in [false, true] {
                s.dialReverse = reverse
                var dial = PadSteamDial(), total = 0
                for degrees in stride(from: 170.0, through: 350, by: 10) {
                    let r = degrees * .pi / 180
                    total += dial.update(down: true, x: cos(r) * 0.8, y: sin(r) * 0.8, settings: s)
                }
                XCTAssertEqual(total, reverse ? -6 : 6)
            }
        }
    }
}
