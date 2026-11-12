import XCTest
@testable import NokcanduCore
final class PadHeadMotionTests: XCTestCase {
    func testWrapRecenterAndTrackingDiscontinuity() {
        var h = PadHeadMotion()
        XCTAssertEqual(h.sample(yaw: .pi - 0.01, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 1).0, 0)
        XCTAssertEqual(h.sample(yaw: -.pi + 0.01, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 1).0, -19, accuracy: 1)
        h.recenter()
        XCTAssertEqual(h.sample(yaw: 0, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 1).0, 0)
        XCTAssertEqual(h.sample(yaw: 2, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 1).0, 0)
    }
    func testDeadZoneAndInvalidSamplesNeverProduceMotion() {
        var h = PadHeadMotion()
        _ = h.sample(yaw: 0, pitch: 0, sensitivity: 1000, deadZone: 0.01, smoothing: 1)
        XCTAssertEqual(h.sample(yaw: 0.001, pitch: 0.001, sensitivity: 1000, deadZone: 0.01, smoothing: 1).0, 0)
        XCTAssertEqual(h.sample(yaw: .nan, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 1).0, 0)
    }
}

final class PadHeadMotionPauseTests: XCTestCase {
    func testPauseDiscardsMovementAndFirstResumedSampleRecenters() {
        var h = PadHeadMotion()
        _ = h.sample(yaw: 0, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 0.5)
        XCTAssertNotEqual(h.sample(yaw: 0.1, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 0.5).0, 0)
        XCTAssertEqual(h.sample(yaw: 0.2, pitch: 0, sensitivity: 1000, deadZone: 0, smoothing: 0.5, active: false).0, 0)
        XCTAssertEqual(h.sample(yaw: 0.6, pitch: 0.4, sensitivity: 1000, deadZone: 0, smoothing: 0.5, active: false).1, 0)
        let resumed = h.sample(yaw: 0.7, pitch: 0.5, sensitivity: 1000, deadZone: 0, smoothing: 0.5)
        XCTAssertEqual(resumed.0, 0); XCTAssertEqual(resumed.1, 0)
        XCTAssertNotEqual(h.sample(yaw: 0.71, pitch: 0.5, sensitivity: 1000, deadZone: 0, smoothing: 0.5).0, 0)
    }
}
