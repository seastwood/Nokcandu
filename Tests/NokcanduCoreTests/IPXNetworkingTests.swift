import XCTest
@testable import NokcanduCore

final class IPXNetworkingTests: XCTestCase {
    func fixture(imports: [String] = ["WSOCK32.dll"], is64: Bool = false) throws -> InstalledGame {
        var g = try ProfileCompletenessTests().fixture()
        let exe = try XCTUnwrap(CompatibilityFixes.managedProgram(g))
        try EngineGraphicsTests().image(imports, is64: is64).write(to: exe)
        g = CompatibilityFixes.fresh(g)
        return g
    }
    func payload() -> [String: Data] {
        var result = Dictionary(uniqueKeysWithValues: (IPXNetworking.dlls + ["ipxconfig.exe"]).map { ($0, EngineGraphicsTests().image(["KERNEL32.dll"])) })
        result["license.txt"] = Data("License".utf8); result["readme.txt"] = Data("Instructions".utf8)
        for name in ["dplayx.dll", "dpwsockx.dll", "dplaysvr.exe"] { result["directplay/" + name] = EngineGraphicsTests().image(["KERNEL32.dll"]) }
        return result
    }
    func testOfficialReleaseInstallProfileAndUndoE2E() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E_IPX"] == "1" else { throw XCTSkip("Requires the official checksum-verified IPXWrapper release") }
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let exe = try XCTUnwrap(CompatibilityFixes.managedProgram(g)), original = try Data(contentsOf: exe)
        let graphics = g.custom?.graphics
        try await CompatibilityFixes.install(.ipxNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertTrue(CompatibilityFixes.isInstalled(.ipxNetworking, for: g))
        for name in IPXNetworking.dlls {
            XCTAssertEqual(PEFile.inspect(exe.deletingLastPathComponent().appendingPathComponent(name))?.is64Bit, false)
        }
        XCTAssertTrue(Profiles.make(from: g, rating: .playable, notes: nil, install: nil).fixes?.contains("ipx-networking") == true)
        XCTAssertEqual(g.custom?.graphics, graphics)
        XCTAssertEqual(try Data(contentsOf: exe), original)
        try CompatibilityFixes.undo(.ipxNetworking, for: g) { _ in }
        XCTAssertFalse(CompatibilityFixes.isInstalled(.ipxNetworking, for: CompatibilityFixes.fresh(g)))
        XCTAssertEqual(try Data(contentsOf: exe), original)
    }

    func testOldComponentMigrationAndUndoE2E() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E_IPX"] == "1" else { throw XCTSkip("Requires pinned release packages") }
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(work); defer { try? FileManager.default.removeItem(at: work) }
        var originals: [URL: Data] = [:]
        for name in ["dplayx.dll", "dpwsockx.dll", "dplaysvr.exe"] {
            let data = EngineGraphicsTests().image(["stock-wine.dll"])
            let source = g.support.appendingPathComponent("wine/lib/wine/i386-windows/" + name)
            let target = g.prefix.appendingPathComponent("drive_c/windows/syswow64/" + name)
            try NokPaths.ensure(source.deletingLastPathComponent()); try data.write(to: source)
            try NokPaths.ensure(target.deletingLastPathComponent()); try data.write(to: target)
            originals[target] = data
        }
        let files = try await IPXNetworking.download(for: g, work: work) { _ in }
        var c = try XCTUnwrap(g.custom)
        let original = c
        let previous = ["dplayx": "b", "dsound": "n"]
        let oldRules = IPXNetworking.overrides.filter { $0.key != "dplayx" }
        let old = CompatibilityFixes.State(executable: c.exe, previousOverrides: previous, appliedOverrides: oldRules, previousLegacy: c.legacyD3D9, previousBorderless: c.borderless)
        try JSONEncoder().encode(old).write(to: CompatibilityFixes.marker(.ipxNetworking, g))
        let journal = CompatibilityFixes.journal(.ipxNetworking, g)
        for (url, data) in files where !url.path.contains("/windows/syswow64/") { try journal.write(data, to: url, reason: "Old component") }
        var rules = previous; rules.merge(oldRules) { _, new in new }
        rules["wininet"] = "b" // a later unrelated explicit setting
        CompatibilityFixes.setOverrides(rules, in: &c)
        try CustomGames.save(c, to: g); g = CompatibilityFixes.fresh(g)
        XCTAssertTrue(IPXNetworking.needsUpdate(g))
        let profile = Profiles.make(from: g, rating: .playable, notes: nil, install: nil)
        XCTAssertTrue(Profiles.plan(profile, for: g).componentFixes.contains(.ipxNetworking))
        let launcher = try XCTUnwrap(g.launcherURL), script = try Data(contentsOf: launcher)
        try (script + Data("\n# manual edit".utf8)).write(to: launcher)
        do { try await CompatibilityFixes.install(.ipxNetworking, for: g) { _ in }; XCTFail("Must preserve manual launcher") } catch {}
        XCTAssertTrue(IPXNetworking.needsUpdate(g))
        try script.write(to: launcher)
        try await CompatibilityFixes.install(.ipxNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertFalse(IPXNetworking.needsUpdate(g))
        XCTAssertEqual(CompatibilityFixes.overrides(g.custom?.environment?["WINEDLLOVERRIDES"])["wininet"], "b")
        try CompatibilityFixes.undo(.ipxNetworking, for: g) { _ in }; g = CompatibilityFixes.fresh(g)
        let restored = CompatibilityFixes.overrides(g.custom?.environment?["WINEDLLOVERRIDES"])
        XCTAssertEqual(restored, ["dplayx": "b", "dsound": "n", "wininet": "b"])
        XCTAssertEqual(g.custom?.graphics, original.graphics)
        for url in files.keys {
            if let data = originals[url] { XCTAssertEqual(try Data(contentsOf: url), data) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        }
    }

    func testSharedEligibilityDoesNotDependOnGameName() throws {
        for imports in [["WSOCK32.dll"], ["DPLAYX.dll"], ["DPLAY.dll"], ["ddraw.dll"], ["ws2_32.dll"]] {
            let g = try fixture(imports: imports); defer { try? FileManager.default.removeItem(at: g.appURL) }
            XCTAssertTrue(IPXNetworking.supports(g)); XCTAssertTrue(CompatibilityFixes.visible(.ipxNetworking, for: g))
            XCTAssertNil(CompatibilityFixes.unavailable(.ipxNetworking, for: g))
        }
        for (imports, is64) in [(["wsock32.dll"], true), (["ws2_32.dll"], true)] {
            let g = try fixture(imports: imports, is64: is64); defer { try? FileManager.default.removeItem(at: g.appURL) }
            XCTAssertFalse(IPXNetworking.supports(g))
        }
        var shared = try fixture(); defer { try? FileManager.default.removeItem(at: shared.appURL) }
        shared.custom?.source = .steamLibrary
        XCTAssertFalse(IPXNetworking.supports(shared), "Do not set environment-wide DLL rules in a shared launcher")
    }
    func testPackagePlanningPreservesGameFilesAndRejectsConflictsLinksAndWrongArch() throws {
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let exe = try XCTUnwrap(CompatibilityFixes.managedProgram(g)), before = try Data(contentsOf: exe)
        let root = exe.deletingLastPathComponent(), dll = root.appendingPathComponent("wsock32.dll")
        XCTAssertEqual(try IPXNetworking.plannedFiles(payload(), for: g).count, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dll.path))
        try Data("manual library".utf8).write(to: dll)
        XCTAssertThrowsError(try IPXNetworking.plannedFiles(payload(), for: g))
        XCTAssertEqual(try Data(contentsOf: dll), Data("manual library".utf8))
        try FileManager.default.removeItem(at: dll)
        try FileManager.default.createSymbolicLink(at: dll, withDestinationURL: exe)
        XCTAssertThrowsError(try IPXNetworking.plannedFiles(payload(), for: g))
        try FileManager.default.removeItem(at: dll)
        var wrong = payload(); wrong["wsock32.dll"] = EngineGraphicsTests().image([], is64: true)
        XCTAssertThrowsError(try IPXNetworking.plannedFiles(wrong, for: g))
        XCTAssertEqual(try Data(contentsOf: exe), before)
    }
    func testPrivateSystemProviderRequiresExactBundledWineAndNoLinks() throws {
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let source = g.support.appendingPathComponent("wine/lib/wine/i386-windows/dpwsockx.dll")
        let target = g.prefix.appendingPathComponent("drive_c/windows/syswow64/dpwsockx.dll")
        let original = EngineGraphicsTests().image(["stock.dll"])
        try NokPaths.ensure(source.deletingLastPathComponent()); try original.write(to: source)
        try NokPaths.ensure(target.deletingLastPathComponent()); try original.write(to: target)
        XCTAssertNoThrow(try IPXNetworking.plannedFiles(payload(), for: g))
        try Data("manual provider".utf8).write(to: target)
        XCTAssertThrowsError(try IPXNetworking.plannedFiles(payload(), for: g))
        XCTAssertEqual(try Data(contentsOf: target), Data("manual provider".utf8))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        XCTAssertThrowsError(try IPXNetworking.plannedFiles(payload(), for: g))
    }

    func testProfileCreationSharingPreviewAndUndoPreserveIPXAndOtherSettings() throws {
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        var c = try XCTUnwrap(g.custom)
        c.environment = ["KEEP": "yes", "WINEDLLOVERRIDES": "dsound=n"]
        try CustomGames.save(c, to: g); g = CompatibilityFixes.fresh(g)
        let before = try XCTUnwrap(g.custom)
        let state = CompatibilityFixes.State(executable: c.exe, previousOverrides: ["dsound": "n"], appliedOverrides: IPXNetworking.overrides, previousLegacy: nil, previousBorderless: c.borderless)
        try JSONEncoder().encode(state).write(to: CompatibilityFixes.marker(.ipxNetworking, g))
        let ledger = CompatibilityFixes.journal(.ipxNetworking, g)
        for (url, data) in try IPXNetworking.plannedFiles(payload(), for: g) { try ledger.write(data, to: url, reason: "IPX test install") }
        var rules = ["dsound": "n"]; rules.merge(IPXNetworking.overrides) { _, new in new }
        CompatibilityFixes.setOverrides(rules, in: &c); try CustomGames.save(c, to: g); g = CompatibilityFixes.fresh(g)
        let profile = Profiles.make(from: g, rating: .playable, notes: nil, install: nil)
        XCTAssertTrue(profile.fixes?.contains("ipx-networking") == true)
        XCTAssertEqual(profile.problems, [])
        let decoded = try GameProfile.parse(profile.json())
        XCTAssertEqual(decoded.fixes, profile.fixes)
        let sharedPayload = URLComponents(url: Profiles.submitURL(profile), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value
        XCTAssertTrue(try GameProfile.parse(XCTUnwrap(sharedPayload)).fixes?.contains("ipx-networking") == true)
        let target = try fixture(); defer { try? FileManager.default.removeItem(at: target.appURL) }
        XCTAssertTrue(Profiles.plan(decoded, for: target).componentFixes.contains(.ipxNetworking))
        try CompatibilityFixes.undo(.ipxNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment, before.environment)
        XCTAssertEqual(g.custom?.graphics, before.graphics)
        XCTAssertFalse(CompatibilityFixes.isInstalled(.ipxNetworking, for: g))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CompatibilityFixes.program(g)!.deletingLastPathComponent().appendingPathComponent("wsock32.dll").path))
    }
}
