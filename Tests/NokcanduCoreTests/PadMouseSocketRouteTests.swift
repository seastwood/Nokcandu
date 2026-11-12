import XCTest
@testable import NokcanduCore
final class PadMouseSocketRouteTests: XCTestCase {
    func testReleaseUsesOriginalProcessAfterFocusChangeAndDoesNotFallBackOnFailure() {
        var route = PadMouseSocketRoute()
        var calls: [String] = []
        let send: (Int32, Int, Bool) -> Bool = { pid, button, down in calls.append("\(pid):\(button):\(down)"); return down }
        XCTAssertTrue(route.route(button: 0, down: true, target: 42, available: true, send: send))
        XCTAssertTrue(route.route(button: 0, down: true, target: 99, available: true, send: send))
        XCTAssertEqual(route.held, [0])
        XCTAssertTrue(route.route(button: 0, down: false, target: 99, available: false, send: send))
        XCTAssertEqual(calls, ["42:0:true", "42:0:false"])
        XCTAssertTrue(route.held.isEmpty)
    }
    func testUnavailableOldHelperOrFailedDownRetainsExistingEventRoute() {
        var route = PadMouseSocketRoute()
        XCTAssertFalse(route.route(button: 1, down: true, target: 42, available: false) { _,_,_ in XCTFail("Old helper must not receive new route"); return true })
        XCTAssertFalse(route.route(button: 1, down: true, target: 42, available: true) { _,_,_ in false })
        XCTAssertTrue(route.held.isEmpty)
        XCTAssertFalse(route.route(button: 1, down: false, target: 42, available: true) { _,_,_ in XCTFail("No unmatched release"); return true })
    }
}
