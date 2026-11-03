import XCTest
@testable import NokcanduCore

final class StorageInventoryTests: XCTestCase {
    actor Counts { var value = 0; func next() -> Int { value += 1; return value } }
    actor Gate {
        var waiting: CheckedContinuation<Void, Never>?
        var open = false
        func wait() async { if !open { await withCheckedContinuation { waiting = $0 } } }
        func release() { open = true; waiting?.resume(); waiting = nil }
    }
    func item(_ value: Int) -> StorageInventory.Snapshot {
        StorageInventory.Snapshot(items: [.init(title: "Fixture", url: URL(fileURLWithPath: "/tmp/storage-fixture"), bytes: Int64(value), detail: "")])
    }
    func testConcurrentReadersShareWalkAndRecentResult() async {
        let cache = StorageInventory(), counts = Counts(), gate = Gate(), started = expectation(description: "walk started")
        let key = StorageInventory.Key(section: .games, library: [])
        let loader: @Sendable () async -> StorageInventory.Snapshot = {
            let count = await counts.next(); started.fulfill(); await gate.wait(); return self.item(count)
        }
        let first = Task { await cache.value(for: key, loader: loader) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await cache.value(for: key, loader: loader) }
        await gate.release()
        let a = await first.value, b = await second.value
        let c = await cache.value(for: key) { XCTFail("Recent result must not rescan"); return self.item(9) }
        XCTAssertEqual(a.items.first?.bytes, 1); XCTAssertEqual(b.items, a.items); XCTAssertEqual(c.items, a.items)
        let count = await counts.value; XCTAssertEqual(count, 1)
    }
    func testRefreshDuringWalkCannotRepopulateStaleCache() async {
        let cache = StorageInventory(), gate = Gate(), started = expectation(description: "old walk started")
        let key = StorageInventory.Key(section: .games, library: [])
        let old = Task { await cache.value(for: key) { started.fulfill(); await gate.wait(); return self.item(1) } }
        await fulfillment(of: [started], timeout: 2)
        await cache.invalidate()
        let fresh = Task { await cache.value(for: key) { self.item(2) } }
        await gate.release()
        _ = await old.value
        let result = await fresh.value
        XCTAssertEqual(result.items.first?.bytes, 2)
        let cached = await cache.value(for: key) { XCTFail("Fresh result should be retained"); return self.item(3) }
        XCTAssertEqual(cached.items, result.items)
    }
    func testExpiryAndSectionIsolation() async {
        let cache = StorageInventory(lifetime: 0), counts = Counts()
        for _ in 0..<2 { _ = await cache.value(for: .init(section: .games, library: [])) { self.item(await counts.next()) } }
        let count = await counts.value; XCTAssertEqual(count, 2)
        let normal = StorageInventory()
        _ = await normal.value(for: .init(section: .games, library: [])) { self.item(1) }
        let other = await normal.value(for: .init(section: .appData, library: [])) { self.item(2) }
        XCTAssertEqual(other.items.first?.bytes, 2)
    }
}
