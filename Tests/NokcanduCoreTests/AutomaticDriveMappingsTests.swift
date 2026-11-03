import XCTest
@testable import NokcanduCore

final class AutomaticDriveMappingsTests: XCTestCase {
    func fixture() throws -> InstalledGame { try LauncherRemovalTests().fixture().host }
    func cleanup(_ game: InstalledGame) { try? FileManager.default.removeItem(at: game.appURL.deletingLastPathComponent()) }
    func link(_ game: InstalledGame, letter: String = "D", target: String, raw: String? = "/dev/nok-test-device") throws -> AutomaticDriveMappings.Mapping {
        let directory = game.prefix.appendingPathComponent("dosdevices")
        try NokPaths.ensure(directory)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(letter.lowercased() + ":").path, withDestinationPath: target)
        if let raw { try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(letter.lowercased() + "::").path, withDestinationPath: raw) }
        return try XCTUnwrap(AutomaticDriveMappings.snapshot(prefix: game.prefix)[letter])
    }
    func authorize(_ game: InstalledGame, _ mapping: AutomaticDriveMappings.Mapping) throws {
        let record = AutomaticDriveMappings.Record(mapping: mapping, origin: .userRemoval)
        try AutomaticDriveMappings.save([mapping.letter: record], at: AutomaticDriveMappings.state(game.contents, "automatic-media-drives"))
    }
    func testNewImageMappingOnlyAndUndoLeavesTargetsUntouched() throws {
        let game = try fixture(); defer { cleanup(game) }
        let before = AutomaticDriveMappings.snapshot(prefix: game.prefix)
        let volume = "/Volumes/Nokcandu-Installer-" + UUID().uuidString
        _ = try link(game, target: volume)
        _ = try link(game, letter: "F", target: "/Volumes/Nokcandu-Unplugged-SSD-" + UUID().uuidString)
        try AutomaticDriveMappings.recordNew(contents: game.contents, before: before, images: ["/tmp/Installer.dmg": [volume]])
        XCTAssertEqual(try AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: true), 1)
        XCTAssertNil(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"])
        XCTAssertNotNil(AutomaticDriveMappings.snapshot(prefix: game.prefix)["F"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume))
        try AutomaticDriveMappings.undo(for: game)
        XCTAssertEqual(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"]?.destination, volume)
        XCTAssertEqual(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"]?.rawDestination, "/dev/nok-test-device")
    }
    func testPreexistingUnknownMappingsAreNeverAdopted() throws {
        let game = try fixture(); defer { cleanup(game) }
        let volume = "/Volumes/Nokcandu-Old-Installer-" + UUID().uuidString
        _ = try link(game, target: volume)
        let before = AutomaticDriveMappings.snapshot(prefix: game.prefix)
        try AutomaticDriveMappings.recordNew(contents: game.contents, before: before, images: ["/tmp/Installer.dmg": [volume]])
        XCTAssertEqual(try AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: true), 0)
        XCTAssertNotNil(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"])
    }
    func testManualMappingSurvivesEvenIfOldAutoRecordExists() throws {
        let game = try fixture(); defer { cleanup(game) }
        let volume = "/Volumes/Nokcandu-Manual-Image-" + UUID().uuidString
        try Drives.add("D", to: URL(fileURLWithPath: volume), for: game)
        let mapping = try XCTUnwrap(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"])
        try authorize(game, mapping)
        XCTAssertEqual(try AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: true), 0)
        XCTAssertNotNil(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"])
    }
    func testConfiguredDiscProgramAndRegistryReferencesAreProtected() throws {
        for reference in ["disc", "program", "registry", "environment", "manual launcher"] {
            var game = try fixture(); defer { cleanup(game) }
            let mapping = try link(game, target: "/Volumes/Nokcandu-Protected-" + UUID().uuidString)
            try authorize(game, mapping)
            if reference == "disc" { game.custom?.disc = DiscSpec(imageName: "Game.iso", volumeLabel: "Game", internalMountDir: "SharedSupport/MountedDisc") }
            if reference == "program" { game.custom?.exe = #"D:\Game\game.exe"# }
            if reference == "environment" { game.custom?.environment = ["GAME_DATA": #"D:\Content"#] }
            if reference == "manual launcher" {
                let directory = game.contents.appendingPathComponent("MacOS")
                try NokPaths.ensure(directory)
                try #"wine D:\MyGame\game.exe"#.write(to: directory.appendingPathComponent("manually-edited-launcher"), atomically: true, encoding: .utf8)
            }
            if reference == "registry" { try #""InstallLocation"="D:\\Game""#.write(to: game.prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8) }
            XCTAssertEqual(try AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: true), 0, reference)
        }
    }
    func testBusyOrChangedEnvironmentAndOccupiedUndoLetterArePreserved() throws {
        let game = try fixture(); defer { cleanup(game) }
        let mapping = try link(game, target: "/Volumes/Nokcandu-Stale-" + UUID().uuidString)
        try authorize(game, mapping)
        XCTAssertEqual(try AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: false), 0)
        let raw = game.prefix.appendingPathComponent("dosdevices/d::")
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.createSymbolicLink(atPath: raw.path, withDestinationPath: "/dev/new-device")
        XCTAssertEqual(try AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: true), 0)
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.createSymbolicLink(atPath: raw.path, withDestinationPath: mapping.rawDestination!)
        XCTAssertEqual(try AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: true), 1)
        let new = try link(game, target: "/Volumes/Nokcandu-New-User-Drive-" + UUID().uuidString)
        try AutomaticDriveMappings.undo(for: game)
        XCTAssertEqual(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"], new)
    }
}

extension AutomaticDriveMappingsTests {
    func testRemoveClearsBothLinksWithoutRemovingFolderContents() throws {
        let game = try fixture(); defer { cleanup(game) }
        let content = game.appURL.deletingLastPathComponent().appendingPathComponent("Keep Game Data")
        try NokPaths.ensure(content)
        let file = content.appendingPathComponent("save.dat")
        try Data("keep save".utf8).write(to: file)
        _ = try link(game, target: content.path)
        try Drives.remove("D", for: game)
        XCTAssertNil(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: game.prefix.appendingPathComponent("dosdevices/d::").path))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep save".utf8))
    }
}

extension AutomaticDriveMappingsTests {
    func testConcurrentCleanupRemovesOnePairAndKeepsOneRecoveryRecord() throws {
        let game = try fixture(); defer { cleanup(game) }
        try authorize(game, link(game, target: "/Volumes/Nokcandu-Concurrent-" + UUID().uuidString))
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            _ = try? AutomaticDriveMappings.reconcileHost(contents: game.contents, games: [game], closed: true)
        }
        XCTAssertNil(AutomaticDriveMappings.snapshot(prefix: game.prefix)["D"])
        let records = AutomaticDriveMappings.read([AutomaticDriveMappings.Record].self, at: AutomaticDriveMappings.state(game.contents, "removed-media-drives"))
        XCTAssertEqual(records?.count, 1)
    }
}
