import XCTest
import CoreGraphics
@testable import NokcanduCore
final class PadEventSourceTests: XCTestCase {
    func testOwnMovementCannotTriggerPhysicalMousePriority() throws {
        let event = try XCTUnwrap(PadMouseEvent.movement(at: .zero, dx: 5, dy: 8, heldButtons: [], flags: []))
        XCTAssertTrue(PadEventSource.isOwn(event, processID: -123))
        XCTAssertTrue(PadEventSource.isOwn(userData: 0, sourcePID: 42, processID: 42))
        XCTAssertFalse(PadEventSource.isOwn(userData: 0, sourcePID: 42, processID: 43))
    }
}
