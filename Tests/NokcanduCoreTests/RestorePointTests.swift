import XCTest
@testable import NokcanduCore

final class RestorePointTests: XCTestCase {
    func testCreateRestoreAndPrune() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("rp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Test Game.app", isDirectory: true)
        let file = app.appendingPathComponent("Contents/SharedSupport/prefix/user.reg")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let p = try XCTUnwrap(try RestorePoints.create(app: app, reason: "Test", automatic: false))
        XCTAssertEqual(RestorePoints.list(app: app).map(\.folder.lastPathComponent), [p.folder.lastPathComponent])
        // Hidden folder beside the app: the library scan skips it.
        XCTAssertTrue(p.folder.path.contains("/.Nokcandu Restore Points/Test Game/"))

        try "after".write(to: file, atomically: true, encoding: .utf8)
        try RestorePoints.restore(p, app: app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
        // The state before restoring is kept as its own point.
        let all = RestorePoints.list(app: app)
        XCTAssertEqual(all.count, 2)
        let undo = try XCTUnwrap(all.first { $0.reason.hasPrefix("Before restoring") })
        try RestorePoints.restore(undo, app: app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after")

        // Automatic points: one per 2 minutes, newest few kept.
        XCTAssertNil(try RestorePoints.create(app: app, reason: "auto", automatic: true))   // one was just taken
        for p in RestorePoints.list(app: app) { try RestorePoints.delete(p) }
        XCTAssertNotNil(try RestorePoints.create(app: app, reason: "auto", automatic: true))
        XCTAssertNil(try RestorePoints.create(app: app, reason: "auto again", automatic: true))
        for p in RestorePoints.list(app: app) { try RestorePoints.delete(p) }
        XCTAssertTrue(RestorePoints.list(app: app).isEmpty)
    }
}
