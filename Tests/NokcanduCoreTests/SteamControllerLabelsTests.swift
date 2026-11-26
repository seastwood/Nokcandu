import XCTest
import NokcanduCore

/// The original Steam Controller read under the 2026 controller's labels.
final class SteamControllerLabelsTests: XCTestCase {
    func original(click: Bool, touch: Bool = true) -> SteamControllerReport.State {
        SteamControllerReport.state(counter: 1, flags: (click ? 1 << 18 : 0) | (touch ? 1 << 20 : 0), leftTrigger: 0, rightTrigger: 0,
                                    stick: [0, 0], leftPad: [0, 0], rightPad: [16000, -8000], leftTouch: false,
                                    gyro: [0, 0, 0], acceleration: [0, 0, 0])
    }
    func testRightPadClickIsTheRightTrackpadClickUnder2026Labels() {
        let s = original(click: true).labeled(as: .steam2026)
        XCTAssertTrue(s.buttons.contains(.rpclick)); XCTAssertFalse(s.buttons.contains(.rs))
        XCTAssertEqual(s.padClick(1), .rpclick)
    }
    func testOwnLabelsAndOtherFamiliesAreUnchanged() {
        let s = original(click: true)
        XCTAssertEqual(s.labeled(as: .valve), s); XCTAssertEqual(s.labeled(as: nil), s)
        XCTAssertTrue(s.labeled(as: .valve).buttons.contains(.rs))
    }
    func testRightPadStillActsAsTheRightStickWhenSetToItsUsualBehavior() {
        let s = original(click: false), relabeled = s.labeled(as: .steam2026)
        let usual = PadSteamTrackpadSettings(), left = PadSteamTrackpadSettings()
        XCTAssertEqual(relabeled.mappingAxes(left: left, right: usual)[2], s.mappingAxes(left: left, right: usual)[2])
        XCTAssertEqual(relabeled.mappingAxes(left: left, right: usual)[3], s.mappingAxes(left: left, right: usual)[3])
    }
}
