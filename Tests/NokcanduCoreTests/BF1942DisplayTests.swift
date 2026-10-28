import XCTest
@testable import NokcanduCore

final class BF1942DisplayTests: XCTestCase {
    func fixture() throws -> InstalledGame {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-display-" + UUID().uuidString + ".app")
        var g = InstalledGame(appURL: root, name: "BF test-" + UUID().uuidString)
        var c = CustomGameConfig(id: "bf-test", name: g.name, source: .folder, exe: #"C:\Games\BF1942\BF1942.exe"#, graphics: .classic3D)
        c.createdAt = Date(timeIntervalSince1970: 1000); g.custom = c
        try NokPaths.ensure(g.prefix.appendingPathComponent("dosdevices"))
        try FileManager.default.createSymbolicLink(atPath: g.prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        let folder = g.prefix.appendingPathComponent("drive_c/Games/BF1942")
        try NokPaths.ensure(folder.appendingPathComponent("Mods/bf1942/Settings/Profiles/Custom"))
        try NokPaths.ensure(g.contents.appendingPathComponent("MacOS")); try NokPaths.ensure(g.nokcanduState)
        try Data("unverified test EXE".utf8).write(to: folder.appendingPathComponent("BF1942.exe"))
        try Data("run Profiles/Custom/Video.con\r\n".utf8).write(to: folder.appendingPathComponent("Mods/bf1942/Settings/Video.con"))
        try Data("game.setGameDisplayMode 2560 1440 16 120\r\nrem keep this\r\n".utf8).write(to: folder.appendingPathComponent("Mods/bf1942/Settings/Profiles/Custom/Video.con"))
        try Data("renderer.setFullScreen 1\nrenderer.fieldOfView 1\n".utf8).write(to: folder.appendingPathComponent("Mods/bf1942/Settings/VideoDefault.con"))
        try c.encoded().write(to: CustomGameConfig.url(in: g.contents))
        return g
    }
    func testBF1942ControlsAreNotOfferedForOtherProgramsOrSharedLaunchers() throws {
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        XCTAssertTrue(BF1942DisplayFix.supports(g))
        g.custom?.exe = #"C:\Games\BF1942\OtherGame.exe"#
        XCTAssertFalse(BF1942DisplayFix.supports(g), "Even another program beside BF1942 must not get BF1942 controls")
        g.custom?.exe = #"C:\Games\BF1942\BF1942.exe"#
        g.custom?.source = .steamLibrary
        XCTAssertFalse(BF1942DisplayFix.supports(g))
    }
    func testCommandEditingPreservesCommentsAndLineEndings() {
        let text = "rem game.setGameDisplayMode 1 2 3 4\r\n\tgame.setGameDisplayMode 800 600 16 120\r\nother.keep 9\r\ngame.setGameDisplayMode 1 2 3 4\r\n"
        let edited = BF1942DisplayFix.setting("game.setGameDisplayMode", value: "1280 800 32 60", in: text)
        XCTAssertEqual(edited, "rem game.setGameDisplayMode 1 2 3 4\r\ngame.setGameDisplayMode 1280 800 32 60\r\nother.keep 9\r\ngame.setGameDisplayMode 1280 800 32 60\r\n")
        XCTAssertEqual(BF1942DisplayFix.setting("game.setGameDisplayMode", value: "1280 800 32 60", in: edited), edited)
    }
    func testMenuCorrectionChangesOnlyFourBytesAndRejectsUnknownFiles() throws {
        var data = Data(repeating: 0xaa, count: 5_648_384)
        data.replaceSubrange(0x631ef..<0x631f3, with: [0x20, 3, 0, 0])
        data.replaceSubrange(0x631f7..<0x631fb, with: [0x58, 2, 0, 0])
        let changed = try BF1942DisplayFix.replacingMenuDimensions(data)
        let offsets = zip(data, changed).enumerated().compactMap { $0.element.0 != $0.element.1 ? $0.offset : nil }
        XCTAssertEqual(offsets, [0x631ef, 0x631f0, 0x631f7, 0x631f8])
        XCTAssertThrowsError(try BF1942DisplayFix.checkedMenuCopy(data), "correct offsets alone must never bypass the full fingerprint")
        XCTAssertThrowsError(try BF1942DisplayFix.replacingMenuDimensions(Data()))
    }
    func testResolutionApplyRepeatAndUndo() async throws {
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let folder = try XCTUnwrap(BF1942DisplayFix.folder(g)), file = folder.appendingPathComponent("Mods/bf1942/Settings/Profiles/Custom/Video.con")
        let before = try Data(contentsOf: file), exe = try Data(contentsOf: folder.appendingPathComponent("BF1942.exe"))
        XCTAssertNotNil(BF1942DisplayFix.menuUnavailable(for: g))
        try await BF1942DisplayFix.apply(to: g, size: [1280, 800], recommended: false) { _ in }
        try await BF1942DisplayFix.apply(to: g, size: [1920, 1080], recommended: false) { _ in }
        XCTAssertEqual(BF1942DisplayFix.resolution(for: g), [1920, 1080])
        XCTAssertEqual(try String(contentsOf: file), "game.setGameDisplayMode 1920 1080 32 60\r\nrem keep this\r\n")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("BF1942.exe")), exe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(BF1942DisplayFix.copyName).path))
        try BF1942DisplayFix.undo(for: g) { _ in }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(BF1942DisplayFix.hasChanges(for: g))
    }
    func testUnknownExecutableAndUserEditsAreLeftUntouched() async throws {
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let folder = try XCTUnwrap(BF1942DisplayFix.folder(g)), file = folder.appendingPathComponent("Mods/bf1942/Settings/Profiles/Custom/Video.con")
        let before = try Data(contentsOf: file)
        do { try await BF1942DisplayFix.apply(to: g, recommended: true) { _ in }; XCTFail("unknown EXE accepted") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(BF1942DisplayFix.hasChanges(for: g))
        try await BF1942DisplayFix.apply(to: g, recommended: false) { _ in }
        try Data("manual change\n".utf8).write(to: file)
        XCTAssertThrowsError(try BF1942DisplayFix.undo(for: g) { _ in })
        XCTAssertEqual(try String(contentsOf: file), "manual change\n")
        XCTAssertTrue(BF1942DisplayFix.hasChanges(for: g))
    }
    func testNoProfilesCreatesOnlyKnownDefaultAndRefusesEscapingSymlink() throws {
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let folder = try XCTUnwrap(BF1942DisplayFix.folder(g))
        let settings = folder.appendingPathComponent("Mods/bf1942/Settings")
        try FileManager.default.removeItem(at: settings.appendingPathComponent("Profiles"))
        try FileManager.default.removeItem(at: settings.appendingPathComponent("Video.con"))
        let plan = try BF1942DisplayFix.plannedFiles(root: folder, size: [1280, 800], recommended: true)
        XCTAssertEqual(String(data: try XCTUnwrap(plan.first(where: { $0.key.lastPathComponent == "Video.con" && $0.key.deletingLastPathComponent().lastPathComponent == "Settings" })?.value), encoding: .utf8), "run Profiles/Default/Video.con\n")
        XCTAssertEqual(plan.count, 3)
        try FileManager.default.createSymbolicLink(at: settings.appendingPathComponent("Profiles"), withDestinationURL: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try BF1942DisplayFix.checkedURL(settings.appendingPathComponent("Profiles/Default/Video.con"), root: folder))
    }
    func testMenuCopyLauncherUsesCorrectPathAndOldSettingsDecode() throws {
        var c = CustomGameConfig(id: "bf-test", name: "BF", source: .folder, exe: #"C:\Games\Battlefield 1942\BF1942.exe"#, graphics: .classic3D)
        c.bf1942MenuCopy = true; c.borderless = true
        let script = CustomGames.launcherScript(for: c)
        XCTAssertTrue(script.contains(#"GAME_EXE='C:\Games\Battlefield 1942\BF1942-Nokcandu.exe'"#))
        XCTAssertTrue(script.contains(#"export NOKCANDU_BORDERLESS_RESTART_TARGET='C:\Games\Battlefield 1942\BF194N.exe'"#))
        XCTAssertLessThan(try XCTUnwrap(script.range(of: BF1942DisplayFix.copyName)?.lowerBound), try XCTUnwrap(script.range(of: "export NOKCANDU_BORDERLESS_TARGET")?.lowerBound))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sh")
        defer { try? FileManager.default.removeItem(at: temp) }
        try script.write(to: temp, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", temp.path]).ok)
    }
    func testMenuCopyUpgradePreservesResolutionAndCanUndo() throws {
        let source = URL(fileURLWithPath: "/Users/seth/Applications/Sikarugir/bf1942-test.app/Contents/SharedSupport/prefix/drive_c/Games/bf1942-test/BF1942.exe")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("local owned game isn't installed") }
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let root = try XCTUnwrap(BF1942DisplayFix.folder(g))
        let original = try Data(contentsOf: source)
        try original.write(to: root.appendingPathComponent("BF1942.exe"))
        g.custom?.bf1942MenuCopy = true
        try XCTUnwrap(g.custom).encoded().write(to: CustomGameConfig.url(in: g.contents))
        try BF1942DisplayFix.save(.init(width: 1920, height: 1200, previousProgram: g.custom!.exe,
                                       appliedProgram: g.custom!.exe, recommended: true), g)
        let ledger = BF1942DisplayFix.journal(g)
        let target = root.appendingPathComponent(BF1942DisplayFix.copyName)
        try ledger.write(BF1942DisplayFix.replacingMenuDimensions(original), to: target, reason: "Previous menu fix")
        let video = root.appendingPathComponent("Mods/bf1942/Settings/Profiles/Custom/Video.con")
        let settings = try Data(contentsOf: video)
        let config = try Data(contentsOf: CustomGameConfig.url(in: g.contents))
        try BF1942DisplayFix.refreshMenuCopies(g)
        let alias = root.appendingPathComponent(BF1942DisplayFix.restartCopyName)
        XCTAssertEqual(try Hashing.sha256(file: alias), BF1942DisplayFix.correctedSHA)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: alias))
        XCTAssertEqual(try Data(contentsOf: video), settings)
        XCTAssertEqual(try Data(contentsOf: CustomGameConfig.url(in: g.contents)), config)
        XCTAssertEqual(BF1942DisplayFix.resolution(for: g), [1920, 1200])
        let count = BF1942DisplayFix.journal(g).entries.count
        try BF1942DisplayFix.refreshMenuCopies(g)
        XCTAssertEqual(BF1942DisplayFix.journal(g).entries.count, count)
        XCTAssertTrue(BF1942DisplayFix.journal(g).revertAll().skipped.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("BF1942.exe")), original)
    }

    func testObservedOriginalWhenAvailable() throws {
        let p = URL(fileURLWithPath: "/Users/seth/Applications/Sikarugir/bf1942-test.app/Contents/SharedSupport/prefix/drive_c/Games/bf1942-test/BF1942.exe")
        guard FileManager.default.fileExists(atPath: p.path) else { throw XCTSkip("local owned game isn't installed") }
        let original = try Data(contentsOf: p)
        XCTAssertEqual(Hashing.sha256(data: original), BF1942DisplayFix.originalSHA)
        XCTAssertEqual(Hashing.sha256(data: try BF1942DisplayFix.checkedMenuCopy(original)), BF1942DisplayFix.correctedSHA)
        let changed = try BF1942DisplayFix.checkedMenuCopy(original)
        let previous = try BF1942DisplayFix.replacingMenuDimensions(original)
        XCTAssertEqual(Hashing.sha256(data: previous), BF1942DisplayFix.previousCorrectedSHA)
        XCTAssertEqual(try BF1942DisplayFix.checkedMenuCopy(previous), changed)
        XCTAssertEqual(try BF1942DisplayFix.checkedMenuCopy(changed), changed)
        XCTAssertEqual(changed.subdata(in: 0x4d369c..<0x4d36a7), Data("BF194N.exe\0".utf8))
        let allowed = Set([0x631ef, 0x631f0, 0x631f7, 0x631f8, 0x4d36a1])
        for (offset, pair) in zip(original, changed).enumerated() where pair.0 != pair.1 {
            XCTAssertTrue(allowed.contains(offset), "unexpected byte change at \(offset)")
        }
        XCTAssertEqual(try Data(contentsOf: p), original)
    }
}
