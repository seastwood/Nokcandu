import XCTest
@testable import NokcanduCore

final class InstallerHandoffTests: XCTestCase {
    func testInstallerHandsBackControlAndContinueChecksInstalledFiles() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("installer-handoff-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let setup = root.appendingPathComponent("setup.exe")
        try NokPaths.ensure(root)
        try Data([1]).write(to: setup)
        var state = InstallState(installID: UUID().uuidString, recipeID: "custom", targetApp: root.appendingPathComponent("Test.app").path)
        state.inputs = ["name": "Test", "installerPath": setup.path]
        let ctx = InstallContext(recipe: CustomInstall.installRecipe(name: "Test"), state: state, library: [], log: { _ in })
        defer { try? fm.removeItem(at: ctx.workDir) }
        try NokPaths.ensure(ctx.wine.deletingLastPathComponent())
        // A /wait launch would block forever on a client left open by setup. Opening the
        // installer without /wait returns control; it does not claim installation succeeded.
        try Data("#!/bin/sh\nfor arg in \"$@\"; do [ \"$arg\" = /wait ] && exit 90; done\nexit 0\n".utf8).write(to: ctx.wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ctx.wine.path)
        let acquire = CustomInstall.Acquire(source: .installer)
        try await acquire.run(ctx)
        XCTAssertEqual(ctx.input("acquire.opened"), "1")
        XCTAssertFalse(acquire.isDone(ctx))
        do { try await acquire.run(ctx); XCTFail("An empty installation must not pass") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No installed program")) }
        let destination = CustomInstall.gamesFolder(ctx)
        try NokPaths.ensure(destination)
        try OpenUASettingsTests().pe().write(to: destination.appendingPathComponent("Test.exe"))
        try await acquire.run(ctx)
        XCTAssertTrue(acquire.isDone(ctx))
    }
}
