import XCTest
@testable import NokcanduCore

final class WineLeftoversTests: XCTestCase {
    private let wine = "/Apps/Steam.app/Contents/SharedSupport/wine/bin/wine64-preloader"
    private let server = "/Apps/Steam.app/Contents/SharedSupport/wine/bin/wineserver"

    /// Programs whose Wine server has gone are leftovers; a live session is never touched.
    func testOnlyWithoutAServer() {
        let old: [(pid: Int32, executable: String, started: Double)] = [(100, wine, 1000), (101, wine, 1001)]
        XCTAssertEqual(WineTools.leftovers(old, now: 5000, minimumAge: 15), [100, 101])
        XCTAssertEqual(WineTools.leftovers(old + [(200, server, 4000), (201, wine, 4001)], now: 5000, minimumAge: 15), [])
        XCTAssertEqual(WineTools.leftovers([], now: 5000, minimumAge: 15), [])
    }
    /// A program that has only just started may be about to start its server: left alone.
    func testJustStartedIsLeftAlone() {
        let list: [(pid: Int32, executable: String, started: Double)] = [(100, wine, 1000), (300, wine, 4995)]
        XCTAssertEqual(WineTools.leftovers(list, now: 5000, minimumAge: 15), [100])
    }
    func testStartTimeOfThisProcess() {
        let t = try! XCTUnwrap(WineTools.startTime(getpid()))
        XCTAssertLessThan(t, Date().timeIntervalSince1970 + 1); XCTAssertGreaterThan(t, Date().timeIntervalSince1970 - 24 * 3600)
        // An environment with nothing running: nothing to end.
        XCTAssertEqual(WineTools.endLeftovers(contents: URL(fileURLWithPath: "/nonexistent/Nothing.app/Contents")), [])
    }
}
