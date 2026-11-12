import XCTest
@testable import NokcanduCore
final class PadEditQueueTests: XCTestCase {
    func testBurstPublishesEveryCommittedValueButPersistsOnlyLatest() {
        var jobs: [() -> Void] = [], saved: [Int] = [], visible: [Int] = []
        var q: PadEditQueue<Int>!
        q = PadEditQueue(schedule: { delay, action in
            XCTAssertEqual(delay, 0.25); jobs.append(action); return {}
        }, didChange: { if let value = q.value(scope: "shared") { visible.append(value) } })
        for n in 0..<100 { q.submit(n, scope: "shared") { saved.append($0) } }
        XCTAssertEqual(visible, Array(0..<100)); XCTAssertTrue(saved.isEmpty)
        // Even a scheduler that executes cancelled jobs cannot commit an old value.
        for job in jobs { job() }
        XCTAssertEqual(saved, [99]); XCTAssertNil(q.value(scope: "shared"))
    }
    func testCloseAndQuitFlushScopesOnceAndStaleTimersCannotSaveAgain() {
        var jobs: [() -> Void] = [], saved: [String] = []
        let q = PadEditQueue<String>(schedule: { _, action in jobs.append(action); return {} }, didChange: {})
        q.submit("shared", scope: "profile:same-id") { saved.append($0) }
        q.submit("own one", scope: "own:one") { saved.append($0) }
        q.submit("own two", scope: "own:two") { saved.append($0) }
        q.flush("own:one"); XCTAssertEqual(saved, ["own one"])
        XCTAssertEqual(q.value(scope: "profile:same-id"), "shared")
        q.flushAll()
        XCTAssertEqual(Set(saved), Set(["shared", "own one", "own two"]))
        for job in jobs { job() }; q.flushAll()
        XCTAssertEqual(saved.count, 3)
    }
}

final class PadEditDeletionTests: XCTestCase {
    func testFlushingBeforeDeletionCannotResurrectProfileFromStaleJobs() {
        var jobs: [() -> Void] = [], disk = ["profile": 1]
        let q = PadEditQueue<Int>(schedule: { _, work in jobs.append(work); return {} }, didChange: {})
        q.submit(2, scope: "profile") { disk["profile"] = $0 }
        q.submit(3, scope: "profile") { disk["profile"] = $0 }
        q.flushAll()
        XCTAssertEqual(disk["profile"], 3)
        disk.removeValue(forKey: "profile")
        for job in jobs { job() }
        XCTAssertNil(disk["profile"])
    }
}
