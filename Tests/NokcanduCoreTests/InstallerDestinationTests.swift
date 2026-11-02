import XCTest
@testable import NokcanduCore

final class InstallerDestinationTests: XCTestCase {
    func testPreparedExternalFolderBecomesInnoDestinationAndNeedsNoCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("External drive")
        try NokPaths.ensure(external)
        var state = InstallState(installID: UUID().uuidString, recipeID: "custom", targetApp: root.appendingPathComponent("Test.app").path)
        state.inputs = ["name": "Game With Spaces", "source": "installer", "filesFolder": external.path]
        let ctx = InstallContext(recipe: CustomInstall.installRecipe(name: "Test"), state: state, library: [], log: { _ in })
        let prepare = CustomInstall.PrepareFiles(source: .installer)
        try await prepare.run(ctx)
        let setup = root.appendingPathComponent("setup.exe")
        var data = EngineGraphicsTests().image([])
        data.append(Data("Inno Setup Setup Data (5.6.2)".utf8)); try data.write(to: setup)
        let expected = #"C:\Games\Game With Spaces"#
        XCTAssertEqual(InstallerDestination.preferredDirectory(in: ctx), expected)
        XCTAssertEqual(InstallerDestination.arguments(for: setup, in: ctx), ["start", "/unix", setup.path, "/DIR=" + expected])
        let exe = CustomInstall.gamesFolder(ctx).appendingPathComponent("bin/game.exe")
        try NokPaths.ensure(exe.deletingLastPathComponent()); try Data([1]).write(to: exe)
        ctx.state.inputs["exe"] = expected + #"\bin\game.exe"#
        XCTAssertTrue(CustomInstall.StoreFiles().isDone(ctx), "A correctly routed install must skip relocation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("Game With Spaces/bin/game.exe").path))

        try EngineGraphicsTests().image([]).write(to: setup)
        XCTAssertEqual(InstallerDestination.arguments(for: setup, in: ctx), ["start", "/unix", setup.path], "Never guess switches for unknown installers")
        try data.write(to: setup)
        ctx.state.inputs["launcherKind"] = "ea"
        XCTAssertEqual(InstallerDestination.arguments(for: setup, in: ctx).count, 3)
        ctx.state.inputs.removeValue(forKey: "launcherKind")
        ctx.state.inputs.removeValue(forKey: "filesFolder")
        XCTAssertEqual(InstallerDestination.arguments(for: setup, in: ctx).count, 3, "Preserve internal-install defaults")
    }

    func testDetectorDoesNotUseFilenameOrAcceptNonPEOrMSI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(root); defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("setup_gog_game.exe")
        try Data("Inno Setup Setup Data (6.0)".utf8).write(to: exe)
        XCTAssertFalse(InstallerDestination.isInnoSetup(exe))
        var data = EngineGraphicsTests().image([]); data.append(Data("Inno Setup Setup Data (6.0)".utf8))
        let msi = root.appendingPathComponent("setup.msi"); try data.write(to: msi)
        XCTAssertFalse(InstallerDestination.isInnoSetup(msi))
    }
}
