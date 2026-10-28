import XCTest
@testable import NokcanduCore

final class SettingsRecoveryTests: XCTestCase {
    func testGameEditsDoNotLockResolutionAndUndoKeepsOtherValues() async throws {
        let fm = FileManager.default, game = try BF1942DisplayTests().fixture()
        defer { try? fm.removeItem(at: game.appURL) }
        let root = try XCTUnwrap(BF1942DisplayFix.folder(game))
        let video = root.appendingPathComponent("Mods/bf1942/Settings/Profiles/Custom/Video.con")
        try await BF1942DisplayFix.apply(to: game, size: [1280, 800], recommended: false) { _ in }
        try Data("rem game rewrote this\r\ngame.setGameDisplayMode 2560 1600 16 60\r\ngame.setShadows 0\r\n".utf8).write(to: video)
        try await BF1942DisplayFix.apply(to: game, size: [1920, 1200], recommended: false) { _ in }
        var text = try String(contentsOf: video)
        XCTAssertTrue(text.contains("1920 1200 32 60")); XCTAssertTrue(text.contains("game.setShadows 0")); XCTAssertTrue(text.contains("rem game rewrote this"))
        try BF1942DisplayFix.undo(for: game) { _ in }
        text = try String(contentsOf: video)
        XCTAssertTrue(text.contains("2560 1440 16 120"), "Undo restores only the original display command")
        XCTAssertTrue(text.contains("game.setShadows 0")); XCTAssertTrue(text.contains("rem game rewrote this"))
        XCTAssertFalse(SettingsBackups.list(for: game).isEmpty, "The pre-Undo current file remains recoverable")
    }
    func testSettingsBackupRestoreVerifiesVersionAndKeepsCurrentVersion() async throws {
        let fm = FileManager.default, game = try BF1942DisplayTests().fixture()
        defer { try? fm.removeItem(at: game.appURL) }
        let video = try XCTUnwrap(BF1942DisplayFix.folder(game)).appendingPathComponent("Mods/bf1942/Settings/Profiles/Custom/Video.con")
        let original = try Data(contentsOf: video)
        try await BF1942DisplayFix.apply(to: game, size: [1280, 800], recommended: false) { _ in }
        let changed = try Data(contentsOf: video), backup = try XCTUnwrap(SettingsBackups.list(for: game).first { $0.original == video })
        try SettingsBackups.restore(backup, for: game)
        XCTAssertEqual(try Data(contentsOf: video), original)
        XCTAssertTrue(SettingsBackups.list(for: game).contains { (try? Data(contentsOf: $0.backup)) == changed })
        try Data("corrupt backup".utf8).write(to: backup.backup)
        XCTAssertThrowsError(try SettingsBackups.restore(backup, for: game))
        XCTAssertEqual(try Data(contentsOf: video), original)
    }
    func testSharedIniUndoPreservesGameChangesAndLegacyEncoding() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("settings-journal-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try NokPaths.ensure(root)
        let file = root.appendingPathComponent("game.ini"), journal = ChangeJournal(scope: "settings", root: root)
        let before = "gfx.vbo = on\r\nvolume = 73\r\n; café\r\n".data(using: .isoLatin1)!
        try before.write(to: file)
        let after = "gfx.vbo = off\r\nvolume = 73\r\n; café\r\n".data(using: .isoLatin1)!
        try journal.writeSettings(after, to: file, keys: ["gfx.vbo"], reason: "test")
        try "gfx.vbo = off\r\nvolume = 45\r\n; café\r\n".data(using: .isoLatin1)!.write(to: file)
        try journal.validateForUndo()
        XCTAssertTrue(journal.revertAll().skipped.isEmpty)
        let result = try String(contentsOf: file, encoding: .isoLatin1)
        XCTAssertTrue(result.contains("gfx.vbo = on")); XCTAssertTrue(result.contains("volume = 45")); XCTAssertTrue(result.contains("café"))
    }
    func testBuiltInGameBackupsAndOnlyItsKnownDocumentsSettingsAreVisible() throws {
        let fm = FileManager.default, game = try BF1942DisplayTests().fixture()
        let global = ChangeJournal(scope: game.journalScope)
        defer {
            try? fm.removeItem(at: game.appURL)
            try? fm.removeItem(at: NokPaths.backups.appendingPathComponent(game.journalScope))
            try? fm.removeItem(at: NokPaths.journals.appendingPathComponent(game.journalScope + ".json"))
        }
        let file = try XCTUnwrap(BF1942DisplayFix.folder(game)).appendingPathComponent("global.ini")
        try Data("setting = old".utf8).write(to: file)
        try global.write(Data("setting = new".utf8), to: file, reason: "built-in settings")
        XCTAssertTrue(SettingsBackups.list(for: game).contains { $0.original.path == file.path })
        let zeroHour = InstalledGame(appURL: game.appURL, name: "Zero Hour", recipe: RecipeCatalog.zeroHour)
        let spec = try XCTUnwrap(GameDataSpec.forGame(zeroHour))
        XCTAssertTrue(SettingsBackups.allowed(spec.folder.appendingPathComponent("Options.ini"), game: zeroHour))
        XCTAssertFalse(SettingsBackups.allowed(spec.folder.appendingPathComponent("unrelated.ini"), game: zeroHour))
    }
    func testBinaryFilesStillUseStrictOwnership() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("binary-journal-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try NokPaths.ensure(root)
        let file = root.appendingPathComponent("game.exe"), journal = ChangeJournal(scope: "binary", root: root)
        try Data([1]).write(to: file); try journal.write(Data([2]), to: file, reason: "test")
        try Data([3]).write(to: file)
        XCTAssertThrowsError(try journal.validateForUndo())
        XCTAssertFalse(journal.revertAll().skipped.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data([3]))
    }
}
