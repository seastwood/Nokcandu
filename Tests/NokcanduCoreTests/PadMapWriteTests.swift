import XCTest
@testable import NokcanduCore
final class PadMapWriteTests: XCTestCase {
    func testFailedMapIsReportedWithoutSkippingOtherEnvironments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("profiles.json"), df = root.appendingPathComponent("default")
        var p = PadProfiles.Profile(name: "Mapping"); p.base[.a] = .as(.key(12))
        try PadProfiles.saveProfiles([p], file: file)
        try Data((p.id + "\n").utf8).write(to: df)
        let bad = root.appendingPathComponent("Bad.app/Contents"), good = root.appendingPathComponent("Good.app/Contents")
        let protected = PadProfiles.mapFile(bad)
        try NokPaths.ensure(protected)
        let keep = protected.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: keep)
        XCTAssertThrowsError(try PadProfiles.store(p, environments: [bad, good], file: file, defaultFile: df))
        XCTAssertEqual(try String(contentsOf: keep), "keep")
        XCTAssertTrue(try String(contentsOf: PadProfiles.mapFile(good)).contains("press=key:12"))
        XCTAssertFalse(PadProfiles.write(contents: bad, shared: false, file: file, defaultFile: df))
        XCTAssertThrowsError(try PadProfiles.set(.normal, contents: bad, file: file, defaultFile: df))
        XCTAssertEqual(try String(contentsOf: keep), "keep")
    }
    func testLinkedControllerMapAndTargetArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let c = root.appendingPathComponent("Game.app/Contents")
        try NokPaths.ensure(PadProfiles.mapFile(c).deletingLastPathComponent())
        let target = root.appendingPathComponent("manual.txt")
        try Data("manual".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: PadProfiles.mapFile(c), withDestinationURL: target)
        XCTAssertThrowsError(try PadProfiles.set(.normal, contents: c))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: PadProfiles.mapFile(c).path), target.path)
        XCTAssertEqual(try String(contentsOf: target), "manual")
    }
}
