import XCTest
@testable import NokcanduCore
final class SteamControllerOwnershipLockTests: XCTestCase {
    func testCompetingReaderCannotAcquireUntilRelease() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("reader.lock")
        let first=try XCTUnwrap(SteamControllerOwnershipLock.acquire(at:path))
        XCTAssertNil(SteamControllerOwnershipLock.acquire(at:path))
        first.release();first.release()
        XCTAssertNotNil(SteamControllerOwnershipLock.acquire(at:path))
    }
    func testLinkedLockPathIsNotFollowed() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let target=root.appendingPathComponent("target"),link=root.appendingPathComponent("reader.lock")
        try Data("preserve".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        XCTAssertNil(SteamControllerOwnershipLock.acquire(at:link))
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"preserve")
    }
}
