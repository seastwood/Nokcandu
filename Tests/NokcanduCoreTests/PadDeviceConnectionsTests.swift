import XCTest
@testable import NokcanduCore
final class PadDeviceConnectionsTests: XCTestCase {
    func testRemovalAndSameSlotReplacementAreReleasedExactlyOnce() {
        var c = PadDeviceConnections()
        XCTAssertEqual(c.update([1: "first", 2: "second"]), [])
        XCTAssertEqual(c.update([1: "replacement", 2: "second"]), [1])
        XCTAssertEqual(c.update([1: "replacement", 2: "second"]), [])
        XCTAssertEqual(c.update([2: "second"]), [1])
        XCTAssertEqual(c.update([:]), [2])
        XCTAssertEqual(c.update([:]), [])
    }
}
