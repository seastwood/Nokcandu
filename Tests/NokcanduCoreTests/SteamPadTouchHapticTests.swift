import XCTest
@testable import NokcanduCore

final class SteamPadTouchHapticTests: XCTestCase {
    func testContactPulseDoesNotRequireMovementOrRepeatWhileHeld() {
        var feedback = SteamControllerHaptics()
        let pulse = feedback.touch(side: 1, down: true, strength: 0.2, at: 1)
        XCTAssertEqual(pulse, SteamControllerHaptics.pulse(side: 1, strength: 0.2))
        for n in 1...100 {
            XCTAssertNil(feedback.touch(side: 1, down: true, strength: 0.2, at: 1 + Double(n)/100))
        }
        XCTAssertNil(feedback.touch(side: 1, down: false, strength: 0.2, at: 2.1))
        XCTAssertNotNil(feedback.touch(side: 1, down: true, strength: 0.2, at: 2.2))
        XCTAssertNotNil(feedback.touch(side: 0, down: true, strength: 0.2, at: 2.2))
        XCTAssertNil(feedback.movement(side: 1, dx: 20, dy: 0, strength: 0.2, at: 2.201))
        feedback.reset()
        XCTAssertNotNil(feedback.touch(side: 1, down: true, strength: 0.2, at: 3))
    }
    func testDisabledContactBoundsAndProfileCompatibility() throws {
        var feedback = SteamControllerHaptics()
        XCTAssertNil(feedback.touch(side: 1, down: true, strength: 0, at: 1))
        XCTAssertNil(feedback.touch(side: 1, down: true, strength: 0.2, at: 1.1))
        XCTAssertNil(feedback.touch(side: 1, down: false, strength: 0.2, at: 1.2))
        XCTAssertNotNil(feedback.touch(side: 1, down: true, strength: 0.2, at: 1.3))
        XCTAssertNil(feedback.touch(side: 1, down: false, strength: 0.2, at: 1.301))
        XCTAssertNil(feedback.touch(side: 1, down: true, strength: 0.2, at: 1.302))
        XCTAssertNil(feedback.touch(side: 2, down: true, strength: 0.2, at: 2))
        XCTAssertNil(feedback.touch(side: 0, down: true, strength: 0.2, at: .nan))
        let old = try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: Data(#"{"mode":"existing","sensitivity":1500,"halfLife":0.16,"invertY":false}"#.utf8))
        XCTAssertNil(old.touchFeedback)
        var settings = old
        settings.touchFeedback = 0.3
        XCTAssertNil(settings.movementFeedback)
        XCTAssertEqual(try JSONDecoder().decode(PadSteamTrackpadSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
