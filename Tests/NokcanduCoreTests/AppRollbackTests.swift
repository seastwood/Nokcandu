import XCTest
@testable import NokcanduCore

final class AppRollbackTests: XCTestCase {
    var root: URL!
    var archives: URL { root.appendingPathComponent("App Versions") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app rollback ' tests " + UUID().uuidString).resolvingSymlinksInPath()
        try NokPaths.ensure(root)
        AppRollback.recoveryHelperOverride = Bundle(for: AppRollbackTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("nokcandu-settings")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: AppRollback.recoveryHelperOverride!.path))
    }
    override func tearDownWithError() throws { AppRollback.recoveryHelperOverride = nil; try FileManager.default.removeItem(at: root) }
    func app(_ name: String, version: String, code: Int = 0, bundle: String = AppRollback.bundleID) throws -> URL {
        let url = root.appendingPathComponent(name + ".app")
        try NokPaths.ensure(url.appendingPathComponent("Contents/MacOS"))
        try NokPaths.ensure(url.appendingPathComponent("Contents/Resources"))
        let source = root.appendingPathComponent("main.c")
        try Data("int main(void) { return \(code); }".utf8).write(to: source)
        XCTAssertTrue(try Shell.run("/usr/bin/clang", [source.path, "-o", url.appendingPathComponent("Contents/MacOS/Nokcandu").path]).ok)
        let plist: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundleExecutable": "Nokcandu", "CFBundleShortVersionString": version, "CFBundleVersion": "test-\(code)", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path]).ok)
        return url
    }
    func testArchiveRoundTripRestoresBothDirectionsAndPreservesUserData() throws {
        let current = try app("Installed Nokcandu", version: "0.12.2", code: 2), old = try app("Older", version: "0.12.1", code: 1)
        let settings = root.appendingPathComponent("user saves.json"), content = Data("preserve".utf8)
        try content.write(to: settings)
        let initial = try AppRollback.info(current).2
        let plan = try AppRollback.prepare(source: old, current: current, archiveRoot: archives, waitingPID: 0)
        XCTAssertEqual(try AppRollback.info(current).0, "0.12.2")
        try AppRollback.replace(plan, relaunch: false)
        XCTAssertEqual(try AppRollback.info(current).0, "0.12.1")
        XCTAssertEqual(try Data(contentsOf: settings), content)
        XCTAssertEqual(try AppRollback.info(plan.backup.app(in: archives)).2, initial)
        let back = try AppRollback.prepare(source: plan.backup.app(in: archives), current: current, archiveRoot: archives, waitingPID: 0)
        try AppRollback.replace(back, relaunch: false)
        XCTAssertEqual(try AppRollback.info(current).2, initial)
        XCTAssertEqual(AppRollback.saved(in: archives).count, 2)
    }
    func testActivePIDCannotBeReplacedAfterTimeout() throws {
        let current = try app("Current", version: "2"), old = try app("Old", version: "1", code: 1)
        let plan = try AppRollback.prepare(source: old, current: current, archiveRoot: archives)
        XCTAssertThrowsError(try AppRollback.replace(plan, waitSeconds: 0, relaunch: false))
        XCTAssertEqual(try AppRollback.info(current).0, "2")
    }
    func testChangedStageAndChangedCurrentRefuseWithoutSwap() throws {
        let current = try app("Current", version: "2"), old = try app("Old", version: "1", code: 1)
        let plan = try AppRollback.prepare(source: old, current: current, archiveRoot: archives, waitingPID: 0)
        try Data("corrupt".utf8).write(to: plan.staged.appendingPathComponent("Contents/MacOS/Nokcandu"))
        XCTAssertThrowsError(try AppRollback.replace(plan, relaunch: false))
        XCTAssertEqual(try AppRollback.info(current).0, "2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.backup.app(in: archives).path))
    }
    func testWrongAppAndCorruptSignatureRejectedBeforeBackup() throws {
        let current = try app("Current", version: "2"), wrong = try app("Wrong", version: "1", bundle: "other.app")
        XCTAssertThrowsError(try AppRollback.prepare(source: wrong, current: current, archiveRoot: archives))
        XCTAssertTrue(AppRollback.saved(in: archives).isEmpty)
        let bad = try app("Broken", version: "1")
        try Data("changed".utf8).write(to: bad.appendingPathComponent("Contents/Resources/extra"))
        XCTAssertThrowsError(try AppRollback.prepare(source: bad, current: current, archiveRoot: archives))
    }
    func testDedupAndRecoveryCommandSafelyQuotePaths() throws {
        let current = try app("Nokcandu's App", version: "2")
        let a = try AppRollback.archive(current, in: archives), b = try AppRollback.archive(current, in: archives)
        XCTAssertEqual(a.id, b.id)
        let command = a.folder(in: archives).appendingPathComponent("Restore Nokcandu.command")
        XCTAssertTrue(FileManager.default.fileExists(atPath: command.path))
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", command.path]).ok)
        XCTAssertTrue(try String(contentsOf: command).contains(CustomGames.shellQuote(current.path)))
    }
    func testDisplacedDestinationCollisionAndBackupTamperPreserveCurrent() throws {
        let current = try app("Current", version: "2"), old = try app("Old", version: "1", code: 1)
        let plan = try AppRollback.prepare(source: old, current: current, archiveRoot: archives, waitingPID: 0)
        try NokPaths.ensure(plan.displaced)
        XCTAssertThrowsError(try AppRollback.replace(plan, relaunch: false))
        try FileManager.default.removeItem(at: plan.displaced)
        try Data("corrupt".utf8).write(to: plan.backup.app(in: archives).appendingPathComponent("Contents/MacOS/Nokcandu"))
        XCTAssertThrowsError(try AppRollback.replace(plan, relaunch: false))
        XCTAssertEqual(try AppRollback.info(current).0, "2")
    }
    func testIndependentHelperRecoversMissingAndDamagedApp() throws {
        let good = try app("Good", version: "1", code: 1)
        let current = root.appendingPathComponent("Missing.app")
        let tool = AppRollback.recoveryHelperOverride!
        let missing = try Shell.run(tool.path, ["--install-app", good.path, current.path, "--archive-root", archives.path], timeout: 30)
        XCTAssertTrue(missing.ok, missing.combined)
        XCTAssertEqual(try AppRollback.info(current).0, "1")
        try Data("corrupt".utf8).write(to: current.appendingPathComponent("Contents/MacOS/Nokcandu"))
        let damaged = try Shell.run(tool.path, ["--install-app", good.path, current.path, "--archive-root", archives.path], timeout: 30)
        XCTAssertTrue(damaged.ok, damaged.combined)
        XCTAssertEqual(try AppRollback.info(current).0, "1")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".Nokcandu-damaged-") })
    }
    func testIndependentHelperRestoresAndArchivesCurrentWithRecoveryCommand() throws {
        let current = try app("Current", version: "2"), old = try app("Old", version: "1", code: 1)
        let result = try Shell.run(AppRollback.recoveryHelperOverride!.path, ["--install-app", old.path, current.path, "--archive-root", archives.path], timeout: 30)
        XCTAssertTrue(result.ok, result.combined)
        let saved = try XCTUnwrap(AppRollback.saved(in: archives).first)
        XCTAssertEqual(saved.version, "2")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: saved.folder(in: archives).appendingPathComponent("Restore Nokcandu.command").path))
        XCTAssertEqual(try AppRollback.info(current).0, "1")
    }

    func testResourceOnlyChangeInvalidatesPreparedPlan() throws {
        let current = try app("Current", version: "2"), old = try app("Old", version: "1", code: 1)
        let plan = try AppRollback.prepare(source: old, current: current, archiveRoot: archives, waitingPID: 0)
        let resource = current.appendingPathComponent("Contents/Resources/new-setting.txt")
        try Data("updated resource".utf8).write(to: resource)
        XCTAssertTrue(try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", current.path]).ok)
        XCTAssertNotEqual(try AppRollback.info(current).2, plan.expectedCurrentSHA)
        XCTAssertThrowsError(try AppRollback.replace(plan, relaunch: false))
        XCTAssertEqual(try String(contentsOf: resource), "updated resource")
        XCTAssertEqual(try AppRollback.info(current).0, "2")
    }

}
