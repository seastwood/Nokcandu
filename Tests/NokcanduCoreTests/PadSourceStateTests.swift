import XCTest
@testable import NokcanduCore
final class PadSourceStateTests: XCTestCase {
    func testTwoControllersCannotReleaseEachOthersHold() {
        var s = PadSourceState()
        XCTAssertEqual(s.update(source: "one", buttons: [0], axes: [0: 24000]).buttons.count, 1)
        XCTAssertTrue(s.update(source: "two", buttons: [], axes: [0: 0]).buttons.isEmpty)
        XCTAssertTrue(s.update(source: "two", buttons: [0], axes: [0: 0]).buttons.isEmpty)
        let removed = s.retain(["two"])
        XCTAssertTrue(removed.buttons.isEmpty)
        XCTAssertEqual(removed.axes.first?.1, 0)
        XCTAssertEqual(s.retain([]).buttons.first?.1, false)
    }
    func testAxisSelectionIsIndependentOfCallbackOrder() {
        var s = PadSourceState()
        _ = s.update(source: "a", buttons: [], axes: [0: 16000])
        XCTAssertEqual(s.update(source: "b", buttons: [], axes: [0: -24000]).axes.first?.1, -24000)
        XCTAssertEqual(s.retain(["a"]).axes.first?.1, 16000)
    }
}
