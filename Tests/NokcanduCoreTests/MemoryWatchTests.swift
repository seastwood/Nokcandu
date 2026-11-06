import XCTest
@testable import NokcanduCore

final class MemoryWatchTests: XCTestCase {
    func testFootprintOfARealProcess() {
        XCTAssertGreaterThan(MemoryWatch.footprint(pid: getpid()) ?? 0, 0)
        XCTAssertNil(MemoryWatch.footprint(pid: 1 << 30))
    }

    func testSessionsTrackPeakAndRestartWithANewProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let g = InstalledGame(appURL: root.appendingPathComponent("Game.app"), name: "Game")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = MemoryWatch.record(g, pid: 500, bytes: 3 << 30, now: t)
        _ = MemoryWatch.record(g, pid: 500, bytes: 9 << 30, now: t.addingTimeInterval(30))
        let s = MemoryWatch.record(g, pid: 500, bytes: 7 << 30, now: t.addingTimeInterval(60))
        XCTAssertEqual(s.peak, 9 << 30)
        XCTAssertEqual(s.growth, 6 << 30)
        XCTAssertEqual(MemoryWatch.last(g)?.peak, 9 << 30, "a big jump is saved right away")
        let next = MemoryWatch.record(g, pid: 501, bytes: 2 << 30, now: t.addingTimeInterval(600))
        XCTAssertEqual(next.peak, 2 << 30)
        XCTAssertEqual(MemoryWatch.last(g)?.pid, 501)
    }

    func testOnlyHeavySessionsGetAdvice() {
        let g = InstalledGame(appURL: URL(fileURLWithPath: "/nonexistent/Game.app"), name: "Game")
        let t = Date()
        let light = MemoryWatch.Session(pid: 2, started: t, updated: t, first: 2 << 30, peak: 5 << 30)
        let heavy = MemoryWatch.Session(pid: 2, started: t, updated: t, first: 3 << 30, peak: 11 << 30)
        XCTAssertNil(MemoryWatch.advice(g, session: light, physical: 16 << 30))
        XCTAssertFalse(MemoryWatch.isHeavy(MemoryWatch.Session(pid: 2, started: t, updated: t, first: 1, peak: 3 << 30), physical: 4 << 30), "at least 4 GB")
        let a = try? XCTUnwrap(MemoryWatch.advice(g, session: heavy, physical: 16 << 30))
        XCTAssertEqual(a?.title, "Game used 11.0 GB of this Mac's 16.0 GB memory")
        XCTAssertTrue(a?.detail.contains("grew by 8.0 GB") == true)
        XCTAssertEqual(a?.offersLowMemoryDXMT, false, "not a DXMT game")
    }
}
