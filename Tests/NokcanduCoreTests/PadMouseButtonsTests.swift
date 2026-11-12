import XCTest
@testable import NokcanduCore
final class PadMouseButtonsTests: XCTestCase {
    func testCapturedReleaseCannotJumpToNewForegroundPointerOrProcess() throws {
        var s = PadMouseButtons()
        for button in 0...4 {
            let down = try XCTUnwrap(s.event(button: button, down: true, target: 123, point: CGPoint(x: 200, y: 300), flags: []))
            let up = try XCTUnwrap(s.event(button: button, down: false, target: 456, point: .zero, flags: []))
            XCTAssertEqual(down.target, 123); XCTAssertEqual(up.target, 123)
            for event in [down.event, up.event] {
                XCTAssertEqual(event.location, CGPoint(x: 200, y: 300))
                XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 0)
                XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 0)
                XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), Int64(button))
            }
        }
        XCTAssertTrue(s.held.isEmpty)
    }
    func testNormalDesktopReleaseUsesCurrentPointerAndIgnoresDuplicateDown() throws {
        var s = PadMouseButtons()
        _ = try XCTUnwrap(s.event(button: 0, down: true, target: 0, point: .zero, flags: []))
        XCTAssertNil(s.event(button: 0, down: true, target: 0, point: .zero, flags: []))
        let up = try XCTUnwrap(s.event(button: 0, down: false, target: 0, point: CGPoint(x: 8, y: 9), flags: []))
        XCTAssertEqual(up.event.location, CGPoint(x: 8, y: 9))
    }
}
