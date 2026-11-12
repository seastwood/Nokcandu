import CoreGraphics

import XCTest
@testable import NokcanduCore
final class PadKeyboardStateTests: XCTestCase {
    func testBothSidesAndChordRelease() {
        for (left, right, flag) in [(56, 60, CGEventFlags.maskShift), (59, 62, .maskControl), (58, 61, .maskAlternate), (55, 54, .maskCommand)] {
            var s = PadKeyboardState()
            XCTAssertEqual(s.update(left, down: true), flag)
            XCTAssertEqual(s.update(right, down: true), flag)
            XCTAssertEqual(s.update(left, down: false), flag)
            XCTAssertEqual(s.update(126, down: true), flag)
            XCTAssertEqual(s.update(126, down: false), flag)
            XCTAssertEqual(s.update(right, down: false), [])
        }
    }
}
