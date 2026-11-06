import XCTest
@testable import NokcanduCore

final class RawMouseSummaryTests: XCTestCase {
    func testSummary() {
        XCTAssertNil(RawMouse.summary([]))
        XCTAssertEqual(RawMouse.summary(["installed; waiting", "ready (x)", "aiming: raw mouse on", "aiming: raw mouse off",
                                         "aiming: raw mouse on", "aiming: raw mouse off"]),
                       "working — took over the mouse 2 times while aiming (menus and other apps get the normal pointer back)")
        XCTAssertEqual(RawMouse.summary(["aiming: raw mouse on", "installed; waiting", "ready (x)"]),
                       "ready, but the game never captured the mouse for aiming")
        XCTAssertTrue(RawMouse.summary(["installed", "winemac event layout not recognised — staying off"])!.hasPrefix("not used"))
        XCTAssertTrue(RawMouse.summary(["installed", "reading the mouse hardware directly failed (0xe00002e2) — using GameController", "aiming: raw mouse on"])!
            .contains("Input Monitoring"))
        XCTAssertFalse(RawMouse.summary(["installed", "reading the mouse hardware directly", "aiming: raw mouse on"])!.contains("Input Monitoring"))
    }
}
