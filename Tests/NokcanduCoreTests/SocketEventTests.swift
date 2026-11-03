import XCTest
@testable import NokcanduCore
final class SocketEventTests: XCTestCase {
    func testServerOnlySocketBoundaryWithoutNetworkOrAccountData() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("socket-events-" + UUID().uuidString)
        try NokPaths.ensure(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let binary = work.appendingPathComponent("test")
        let build = try Shell.run("/usr/bin/xcrun", ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-I", root.appendingPathComponent("Resources/rawmouse").path, root.appendingPathComponent("Tools/socket-events/test.c").path, "-o", binary.path], timeout: 30)
        XCTAssertTrue(build.ok, build.combined)
        let result = try Shell.run(binary.path, [], timeout: 10)
        XCTAssertTrue(result.ok, result.combined)
    }
}
