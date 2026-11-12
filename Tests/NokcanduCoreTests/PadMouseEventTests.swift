import XCTest
import CoreGraphics
@testable import NokcanduCore

final class PadMouseEventTests: XCTestCase {
    func testEveryHeldButtonCombinationHasConsistentDragIdentity() throws {
        // All 32 combinations, including both primary buttons and extra buttons.
        for mask in 0..<32 {
            let held = Set((0...4).filter { mask & (1 << $0) != 0 })
            let event = try XCTUnwrap(PadMouseEvent.movement(at: CGPoint(x: 120, y: 90),
                dx: -17, dy: 23, heldButtons: held, flags: [.maskShift]))
            let first = held.min()
            let expected: CGEventType = first == nil ? .mouseMoved : first == 0 ? .leftMouseDragged : first == 1 ? .rightMouseDragged : .otherMouseDragged
            XCTAssertEqual(event.type, expected, "held: \(held)")
            XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), Int64(first ?? 0))
            XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), -17)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 23)
            XCTAssertEqual(event.location, CGPoint(x: 120, y: 90))
            XCTAssertEqual(event.flags, [.maskShift])
        }
    }

    func testReleaseTransitionsKeepRemainingDragAndThenResumeMovement() throws {
        let sequence: [Set<Int>] = [[0, 1], [1], []]
        let events = try sequence.map { try XCTUnwrap(PadMouseEvent.movement(at: .zero,
            dx: 8, dy: -4, heldButtons: $0, flags: [])) }
        XCTAssertEqual(events.map(\.type), [.leftMouseDragged, .rightMouseDragged, .mouseMoved])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.mouseEventButtonNumber) }, [0, 1, 0])
    }
}
