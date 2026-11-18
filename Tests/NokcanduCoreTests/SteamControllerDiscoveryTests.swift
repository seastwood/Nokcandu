import XCTest
import NokcanduCore

final class SteamControllerDiscoveryTests: XCTestCase {
    func testSilentReceiverProbeDoesNotBlockMainQueueAndCannotPileUp() async {
        let work = DispatchQueue(label: "discovery-test")
        let discovery = SteamControllerDiscovery(queue: work)
        let probing = expectation(description: "HID probe started")
        let responsive = expectation(description: "Main queue progressed while probe is waiting")
        let finished = expectation(description: "Probe completed")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            XCTAssertTrue(discovery.scan([1], probe: { _ in
                XCTAssertFalse(Thread.isMainThread)
                probing.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return false
            }, completion: { id in
                XCTAssertTrue(Thread.isMainThread); XCTAssertNil(id); finished.fulfill()
            }))
            XCTAssertFalse(discovery.scan([2], probe: { _ in XCTFail("A second scan must not pile up"); return true }, completion: { _ in }))
            DispatchQueue.main.async { responsive.fulfill() }
        }
        await fulfillment(of: [probing, responsive], timeout: 2)
        release.signal()
        await fulfillment(of: [finished], timeout: 2)
    }
    func testSelectionRetainsOrderAndStopsAfterARespondingSlot() async {
        let discovery = SteamControllerDiscovery(queue: DispatchQueue(label: "selection-test"))
        let done = expectation(description: "Selected responding slot")
        discovery.scan([1, 2, 3], probe: { id in
            XCTAssertNotEqual(id, 3, "Do not touch later slots once a controller responds")
            return id == 2
        }, completion: { id in
            XCTAssertEqual(id, 2); XCTAssertTrue(Thread.isMainThread); done.fulfill()
        })
        await fulfillment(of: [done], timeout: 2)
    }
    func testStopOrNewReaderRejectsOldResultsAndStopsOldScan() async {
        let discovery = SteamControllerDiscovery(queue: DispatchQueue(label: "cancel-test"))
        let probing = expectation(description: "Old probe started")
        let done = expectation(description: "New generation completed")
        let release = DispatchSemaphore(value: 0)
        discovery.scan([1, 99], probe: { id in
            XCTAssertEqual(id, 1, "Cancelled scan must not probe the remaining slots")
            probing.fulfill(); _ = release.wait(timeout: .now() + 5); return true
        }, completion: { _ in XCTFail("Stale result must not take over a controller after stop") })
        await fulfillment(of: [probing], timeout: 2)
        discovery.cancel()
        XCTAssertTrue(discovery.scan([2], probe: { _ in true }, completion: { id in
            XCTAssertEqual(id, 2); done.fulfill()
        }))
        release.signal()
        await fulfillment(of: [done], timeout: 2)
    }
}
