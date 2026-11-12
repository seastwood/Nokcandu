import XCTest
@testable import NokcanduCore

final class PadCapturePolicyTests: XCTestCase {
    func testAutomaticIsForegroundPermissionAndWindowScoped() {
        var p = PadCapturePolicy()
        p.update(pid: 12, mode: .automatic, permitted: true, windowAvailable: true)
        XCTAssertEqual(p.targetPID, 12)
        p.update(pid: 13, mode: .disabled, permitted: true, windowAvailable: true)
        XCTAssertNil(p.targetPID)
        p.update(pid: 12, mode: .automatic, permitted: false, windowAvailable: true)
        XCTAssertNil(p.targetPID)
        p.update(pid: 12, mode: .automatic, permitted: true, windowAvailable: false)
        XCTAssertNil(p.targetPID)
        p.update(pid: nil, mode: .automatic, permitted: true, windowAvailable: true)
        XCTAssertNil(p.targetPID)
    }
    func testManualNeverRestoresAcrossFocusChange() {
        var p = PadCapturePolicy()
        p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
        XCTAssertNil(p.targetPID)
        p.toggleManual(pid: 12)
        p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
        XCTAssertEqual(p.targetPID, 12)
        p.update(pid: 13, mode: .disabled, permitted: true, windowAvailable: true)
        p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
        XCTAssertNil(p.targetPID)
    }
    func testEmergencyReleaseCannotBeOverriddenByPolling() {
        var p = PadCapturePolicy()
        p.update(pid: 12, mode: .automatic, permitted: true, windowAvailable: true)
        p.release()
        for _ in 0..<10 { p.update(pid: 12, mode: .automatic, permitted: true, windowAvailable: true) }
        XCTAssertNil(p.targetPID)
        p.update(pid: 13, mode: .disabled, permitted: true, windowAvailable: true)
        p.update(pid: 12, mode: .automatic, permitted: true, windowAvailable: true)
        XCTAssertEqual(p.targetPID, 12)
        p.reset(); XCTAssertNil(p.targetPID)
    }
}

final class PadCaptureLossTests: XCTestCase {
    func testManualCaptureNeedsNewActivationAfterPermissionOrWindowLoss() {
        for permissionLoss in [true, false] {
            var p = PadCapturePolicy()
            p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
            p.toggleManual(pid: 12)
            p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
            XCTAssertEqual(p.targetPID, 12)
            p.update(pid: 12, mode: .manual, permitted: !permissionLoss, windowAvailable: permissionLoss)
            XCTAssertNil(p.targetPID)
            p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
            XCTAssertNil(p.targetPID)
            p.toggleManual(pid: 12)
            p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
            XCTAssertEqual(p.targetPID, 12)
        }
    }
    func testDisabledRuleCannotRememberManualActivation() {
        var p = PadCapturePolicy()
        p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
        p.toggleManual(pid: 12)
        p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
        p.update(pid: 12, mode: .disabled, permitted: true, windowAvailable: true)
        p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
        XCTAssertNil(p.targetPID)
        p.toggleManual(pid: 99)
        p.update(pid: 12, mode: .manual, permitted: true, windowAvailable: true)
        XCTAssertNil(p.targetPID)
    }
}
