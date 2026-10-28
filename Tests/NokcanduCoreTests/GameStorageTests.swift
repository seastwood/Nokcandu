import XCTest
@testable import NokcanduCore
final class GameStorageTests: XCTestCase {
    func testSplitGameStorageCountsEachLocationOnce() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("storage-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Game.app"), prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        let folder = prefix.appendingPathComponent("drive_c/Games/Test")
        try NokPaths.ensure(folder); try NokPaths.ensure(root.appendingPathComponent("External"))
        try Data(repeating: 42, count: 16384).write(to: folder.appendingPathComponent("Test.exe"))
        let c = CustomGameConfig(id: "storage", name: "Storage test", source: .folder, exe: #"C:\Games\Test\Test.exe"#, graphics: .classic3D)
        let g = InstalledGame(appURL: app, name: c.name, custom: c)
        let before = Storage.usage(for: g)
        XCTAssertEqual(before.parts.count, 1)
        try GameMover.moveFiles(g, to: root.appendingPathComponent("External"))
        let split = Storage.usage(for: g)
        XCTAssertEqual(split.parts.count, 2)
        XCTAssertEqual(split.parts[1].title, "Game files")
        XCTAssertEqual(split.bytes, Storage.size(app) + Storage.size(root.appendingPathComponent("External/Test")))
        XCTAssertTrue(split.complete)
        XCTAssertFalse(split.parts[0].drive.isEmpty)
        XCTAssertEqual(Storage.driveName(URL(fileURLWithPath: "/Volumes/Offline Games/Game")), "Offline Games")
    }
}

final class GameRemovalStorageTests: XCTestCase {
    func testOnlyDedicatedOwnedExternalFolderIsOfferedForRemoval() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("removal-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let library = root.appendingPathComponent("Library"), external = library.appendingPathComponent("Test")
        try NokPaths.ensure(external)
        func game(_ name: String) throws -> InstalledGame {
            let app = root.appendingPathComponent(name + ".app")
            let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
            let games = prefix.appendingPathComponent("drive_c/Games")
            try NokPaths.ensure(games)
            try fm.createSymbolicLink(atPath: games.appendingPathComponent("Test").path, withDestinationPath: external.path)
            let config = CustomGameConfig(id: name, name: name, source: .folder, exe: #"C:\Games\Test\Game.exe"#, graphics: .classic3D)
            return InstalledGame(appURL: app, name: name, custom: config)
        }
        let first = try game("First")
        XCTAssertEqual(GameRemoval.removableExternalFiles(first, library: [first], folders: [library])?.path, external.path)
        XCTAssertNil(GameRemoval.removableExternalFiles(first, library: [first], folders: [root]))
        let second = try game("Second")
        XCTAssertNil(GameRemoval.removableExternalFiles(first, library: [first, second], folders: [library]))
        try sourceMarker(first.support)
        XCTAssertNil(GameRemoval.removableExternalFiles(first, library: [first], folders: [library]))
        XCTAssertTrue(fm.fileExists(atPath: external.path))
    }
    private func sourceMarker(_ support: URL) throws {
        try "borrowed".write(to: support.appendingPathComponent("referenced-game-folder.txt"), atomically: true, encoding: .utf8)
    }
}
