import XCTest
@testable import NokcanduCore

final class BF2DeploymentUITests: XCTestCase {
    func testNewFileInsideLinkedGameFolderResolvesItsParentFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real"), link = root.appendingPathComponent("linked")
        try NokPaths.ensure(real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let file = link.appendingPathComponent("dxvk.conf")
        XCTAssertEqual(BF2DeploymentUI.destination(file).path,real.appendingPathComponent("dxvk.conf").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testComponentIsScopedAndUndoPreservesOtherSettings() async throws {
        var g = try ProfileCompletenessTests().fixture()
        defer { try? FileManager.default.removeItem(at: g.appURL) }
        let bin = g.support.appendingPathComponent("wine/bin")
        try NokPaths.ensure(bin)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("wine"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        PendingSettings.stateRootOverride = g.appURL.appendingPathComponent("test-pending-state")
        defer { PendingSettings.stateRootOverride = nil }
        let folder = g.prefix.appendingPathComponent("drive_c/Games/BF2")
        try NokPaths.ensure(folder.appendingPathComponent("mods/bf2"))
        try OpenUASettingsTests().pe().write(to: folder.appendingPathComponent("BF2.exe"))
        var config = try XCTUnwrap(g.custom)
        config.exe = #"C:\Games\BF2\BF2.exe"#
        config.environment = ["KEEP": "unchanged", "DXVK_CONFIG": "d3d9.maxFrameLatency = 2"]
        try CustomGames.save(config, to: g); g = CompatibilityFixes.fresh(g)
        XCTAssertFalse(BF2DeploymentUI.supports(g), "Unsupported renderers must not offer an inert workaround")
        let dll = g.support.appendingPathComponent("renderer/d9vk/wine/i386-windows/d3d9.dll")
        try NokPaths.ensure(dll.deletingLastPathComponent())
        try Data((BF2DeploymentUI.option + "\0DXVK_CONFIG_FILE\0").utf8).write(to: dll)
        XCTAssertTrue(BF2DeploymentUI.supports(g))
        let stale = g
        var queued = config; queued.arguments = "+restart 1"
        try PendingSettings.save(.custom(queued, force: false, changeProgram: false), title: "Queued game settings", for: g)
        try await CompatibilityFixes.install(.bf2DeploymentUI, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment?[BF2DeploymentUI.flag], "1")
        XCTAssertEqual(g.custom?.environment?["DXVK_CONFIG_FILE"], #"C:\Games\BF2\dxvk.conf"#)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("dxvk.conf")), BF2DeploymentUI.fileData)
        XCTAssertEqual(g.custom?.environment?["DXVK_CONFIG"], "d3d9.maxFrameLatency = 2")
        XCTAssertTrue(Profiles.make(from: g, rating: .playable, notes: nil, install: nil).fixes?.contains("bf2-deployment-ui") == true)
        _ = try await PendingSettings.apply(for: g)
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment?[BF2DeploymentUI.flag], "1", "A queued old snapshot cannot disable an installed component")
        XCTAssertEqual(g.custom?.arguments, "+restart 1")
        _ = CustomGames.upgradeLaunchers([stale])
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.arguments, "+restart 1", "Maintenance must read current disk settings")
        XCTAssertEqual(g.custom?.environment?[BF2DeploymentUI.flag], "1")
        var missing = try XCTUnwrap(g.custom)
        missing.environment?[BF2DeploymentUI.flag] = nil
        missing.environment?["DXVK_CONFIG_FILE"] = nil
        try CustomGames.save(missing, to: g)
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment?[BF2DeploymentUI.flag], "1", "Every ordinary save preserves installed requirements")
        XCTAssertEqual(g.custom?.environment?["DXVK_CONFIG_FILE"], #"C:\Games\BF2\dxvk.conf"#)
        // Simulate an older build's already-lost on-disk setting to exercise
        // migration independently of the now-protected save entry point.
        let oldLauncher = Data(CustomGames.launcherScript(for: missing).utf8)
        missing.launcherSHA = Hashing.sha256(data: oldLauncher)
        try oldLauncher.write(to: g.contents.appendingPathComponent("MacOS/" + CustomGames.launcherName))
        try missing.encoded().write(to: CustomGameConfig.url(in: g.contents))
        XCTAssertEqual(CustomGames.upgradeLaunchers([stale]), 1, "Known component receipts repair a lost owned setting")
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment?[BF2DeploymentUI.flag], "1")
        XCTAssertEqual(g.custom?.arguments, "+restart 1")
        var later = try XCTUnwrap(g.custom); later.environment?["KEEP"] = "later edit"
        try CustomGames.save(later, to: g)
        try CompatibilityFixes.undo(.bf2DeploymentUI, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertNil(g.custom?.environment?[BF2DeploymentUI.flag])
        XCTAssertNil(g.custom?.environment?["DXVK_CONFIG_FILE"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("dxvk.conf").path))
        XCTAssertEqual(g.custom?.environment?["KEEP"], "later edit")
        XCTAssertEqual(g.custom?.environment?["DXVK_CONFIG"], "d3d9.maxFrameLatency = 2")
        later = try XCTUnwrap(g.custom); later.exe = #"C:\Games\T\Other.exe"#
        g.custom = later
        XCTAssertFalse(BF2DeploymentUI.supports(g))
    }
    func testRuntimeAppendPreservesPerformanceAndExplicitUserChoices() throws {
        for original in ["", "d3d9.maxFrameLatency = 1; d3d9.presentInterval = 1", "d3d9.deviceLossOnFocusLoss = False; other = 7"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", BF2DeploymentUI.launcherExports + "printf '%s' \"$DXVK_CONFIG\""]
            p.environment = ["DXVK_CONFIG": original]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            let result = String(decoding: bytes, as: UTF8.self)
            if original.contains(BF2DeploymentUI.option) { XCTAssertEqual(result, original) }
            else {
                XCTAssertTrue(result.hasSuffix("d3d9.deviceLossOnFocusLoss = True"))
                XCTAssertTrue(result.hasPrefix(original))
            }
        }
    }
    func testLauncherOptInAndGraphicsIsolation() {
        var config = CustomGameConfig(id: "bf2", name: "BF2", source: .folder, exe: #"C:\Games\BF2\BF2.exe"#, graphics: .classic3D)
        XCTAssertFalse(CustomGames.launcherScript(for: config).contains("case \"${DXVK_CONFIG:-}\""))
        config.environment = [BF2DeploymentUI.flag: "1", "DXVK_CONFIG": "d3d9.maxFrameLatency = 2"]
        let text = CustomGames.launcherScript(for: config)
        XCTAssertTrue(text.contains(BF2DeploymentUI.launcherExports))
        XCTAssertLessThan(text.range(of: "# Your extra settings")!.lowerBound, text.range(of: BF2DeploymentUI.launcherExports)!.lowerBound)
        config.graphics = .compatible
        XCTAssertFalse(CustomGames.launcherScript(for: config).contains(BF2DeploymentUI.launcherExports))
    }
}
