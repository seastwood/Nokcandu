import XCTest
@testable import NokcanduCore

/// Programs of an engine kept outside the app (Apple silicon engines are linked, not copied) report the engine's
/// own folder; they still belong to the app whose prefix they run in.
final class LinkedEngineOwnershipTests: XCTestCase {
    func testLinkedEngineProgramsBelongToTheAppOfTheirPrefix() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nok-linked-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let engine = root.appendingPathComponent("Engine/Contents")
        try fm.createDirectory(at: engine.appendingPathComponent("lib/wine/aarch64-unix"), withIntermediateDirectories: true)
        try fm.createDirectory(at: engine.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let support = root.appendingPathComponent("Game.app/Contents/SharedSupport")
        try fm.createDirectory(at: support.appendingPathComponent("wine"), withIntermediateDirectories: true)
        try fm.createDirectory(at: support.appendingPathComponent("prefix"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: support.appendingPathComponent("wine/lib"), withDestinationURL: engine.appendingPathComponent("lib"))
        let s = support.standardizedFileURL.path
        XCTAssertEqual(WineTools.linkedEngine(support: s), engine.standardizedFileURL.path)

        let loader = engine.appendingPathComponent("lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try fm.createDirectory(at: support.appendingPathComponent("prefix/drive_c"), withIntermediateDirectories: true)
        p.currentDirectoryURL = support.appendingPathComponent("prefix/drive_c")
        try p.run()
        defer { p.terminate() }
        XCTAssertTrue(WineTools.owns(pid: p.processIdentifier, executable: loader, support: s))
        // Another app's program on the same engine isn't this app's.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["5"]
        let otherPrefix = root.appendingPathComponent("Other.app/Contents/SharedSupport/prefix")
        try fm.createDirectory(at: otherPrefix, withIntermediateDirectories: true)
        other.currentDirectoryURL = otherPrefix
        try other.run()
        defer { other.terminate() }
        XCTAssertFalse(WineTools.owns(pid: other.processIdentifier, executable: loader, support: s))
        // Something else inside the engine's folder isn't a Wine program.
        XCTAssertFalse(WineTools.owns(pid: p.processIdentifier, executable: engine.appendingPathComponent("share/x").path, support: s))
        XCTAssertTrue(WineTools.leftovers([(1, engine.appendingPathComponent("bin/wineserver").path, 0)], now: 100, minimumAge: 1).isEmpty)
    }
}
