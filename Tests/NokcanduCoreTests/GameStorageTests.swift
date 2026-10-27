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
