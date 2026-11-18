import XCTest
import NokcanduCore

final class ControllerDeviceAccessTests: XCTestCase {
    func testExclusiveAccessNeverFallsBackAndCanRetryAfterSteamReleases() {
        let access = ControllerDeviceAccess(exclusive: true)
        var calls = 0
        XCTAssertFalse(access.open { exclusive in XCTAssertTrue(exclusive); calls += 1; return -1 })
        XCTAssertEqual(access.state, .refused(-1)); XCTAssertFalse(access.usable)
        XCTAssertEqual(calls, 1, "No second open requesting shared access")
        XCTAssertTrue(access.open { exclusive in XCTAssertTrue(exclusive); calls += 1; return 0 })
        XCTAssertEqual(access.state, .exclusive)
        XCTAssertTrue(access.open { _ in XCTFail("An owned interface is not reopened by each discovery poll"); return -1 })
        XCTAssertEqual(calls, 2)
        var closes = 0
        access.release { exclusive in XCTAssertTrue(exclusive); closes += 1 }
        access.release { _ in XCTFail("Release must be idempotent") }
        XCTAssertEqual(closes, 1); XCTAssertEqual(access.state, .released)
        XCTAssertFalse(access.open { _ in XCTFail("A stopped reader cannot reacquire"); return 0 })
    }
    func testExplicitOptOutRetainsSharedAccessAndReleaseOptions() {
        let access = ControllerDeviceAccess(exclusive: false)
        XCTAssertTrue(access.open { exclusive in XCTAssertFalse(exclusive); return 0 })
        XCTAssertEqual(access.state, .shared)
        access.release { exclusive in XCTAssertFalse(exclusive) }
        XCTAssertEqual(access.state, .released)
    }
    func testRefusedOrNeverOpenedAccessDoesNotCloseAnotherOwner() {
        for access in [ControllerDeviceAccess(exclusive: true), ControllerDeviceAccess(exclusive: false)] {
            XCTAssertFalse(access.open { _ in -1 })
            access.release { _ in XCTFail("No successful open to release") }
        }
        ControllerDeviceAccess(exclusive: true).release { _ in XCTFail("Unopened device must not close") }
    }
    func testReadingStatusDoesNotWaitForBlockedOpen() async {
        let access = ControllerDeviceAccess(exclusive: true)
        let opening = expectation(description: "OS open started")
        let responsive = expectation(description: "Status query stays responsive")
        let done = expectation(description: "Open returns")
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(access.open { _ in opening.fulfill(); _ = gate.wait(timeout: .now() + 5); return 0 })
            done.fulfill()
        }
        await fulfillment(of: [opening], timeout: 2)
        DispatchQueue.main.async { XCTAssertEqual(access.state, .unopened); responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 2)
        gate.signal()
        await fulfillment(of: [done], timeout: 2)
    }
    func testCancelledDiscoveryClosesLateExclusiveOpenWithoutPublishingInput() async {
        let queue = DispatchQueue(label: "exclusive-cancel-test")
        let discovery = SteamControllerDiscovery(queue: queue)
        let access = ControllerDeviceAccess(exclusive: true)
        let opening = expectation(description: "Open is pending")
        let closed = expectation(description: "Late open released")
        let gate = DispatchSemaphore(value: 0)
        discovery.scan([1], probe: { _ in
            access.open { _ in opening.fulfill(); _ = gate.wait(timeout: .now() + 5); return 0 }
        }, completion: { _ in XCTFail("Cancelled result must not capture a mode or publish input") })
        await fulfillment(of: [opening], timeout: 2)
        discovery.cancel(); gate.signal()
        queue.async {
            access.release { exclusive in XCTAssertTrue(exclusive) }
            DispatchQueue.main.async { XCTAssertEqual(access.state, .released); closed.fulfill() }
        }
        await fulfillment(of: [closed], timeout: 2)
    }
}
