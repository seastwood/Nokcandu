import XCTest
@testable import NokcanduCore

final class NativeIPXNetworkingTests: XCTestCase {
    func fixture() throws -> InstalledGame {
        var g = try IPXNetworkingTests().fixture()
        let bin = g.support.appendingPathComponent("wine/bin")
        try NokPaths.ensure(bin)
        let script = #"""
        #!/usr/bin/env python3
        import json,sys,os,pathlib
        db=pathlib.Path(os.environ['WINEPREFIX']).parent/'regdb.json'
        values=json.loads(db.read_text()) if db.exists() else {}
        a=sys.argv[1:]
        if a and a[0].endswith('adapter-info.exe'):
            print('en0|{test}|12:34:56:78:90:AB|192.168.1.2');sys.exit(0)
        if not a or a[0]!='reg': sys.exit(0)
        op,key=a[1:3];name=a[a.index('/v')+1];token=key+'|'+name
        if op=='query':
            if token not in values: print('reg: Unable to find the specified registry key');sys.exit(1)
            t,v=values[token];print(key+'\n    '+name+'    '+t+'    '+v)
        elif op=='add':
            values[token]=[a[a.index('/t')+1],a[a.index('/d')+1]];db.write_text(json.dumps(values))
        elif op=='delete':
            values.pop(token,None);db.write_text(json.dumps(values))
        else: sys.exit(2)
        """#
        let wine = bin.appendingPathComponent("wine")
        try script.write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try "wine sikarugir 11.0 (revision 1)".write(to: g.support.appendingPathComponent("wine/version"), atomically: true, encoding: .utf8)
        g = CompatibilityFixes.fresh(g)
        return g
    }
    func installRegistryRecord(_ g: InstalledGame) throws -> InstalledGame {
        let change = NativeIPXNetworking.RegistryChange(key: NativeIPXNetworking.registryRoot, name: "frame_type", previous: nil, applied: .dword(3))
        try NativeIPXNetworking.apply([change], for: g)
        let state = CompatibilityFixes.State(registryChanges: [change], executable: g.custom!.exe, previousOverrides: [:], appliedOverrides: ["wpcap": "b"], previousLegacy: nil, previousBorderless: nil,
            previousEnvironment: [:], appliedEnvironment: [NativeIPXNetworking.flag: "1"])
        try JSONEncoder().encode(state).write(to: CompatibilityFixes.marker(.nativeIPXNetworking, g))
        var config = g.custom!; config.environment = [NativeIPXNetworking.flag: "1", "WINEDLLOVERRIDES": "wpcap=b", "KEEP": "yes"]
        try CustomGames.save(config, to: g)
        return CompatibilityFixes.fresh(g)
    }
    func testRegistryParsingAndConflictAwareRestore() throws {
        XCTAssertEqual(try NativeIPXNetworking.parseValue("key\n frame_type REG_DWORD 0x3\n", name: "frame_type"), .dword(3))
        XCTAssertEqual(try NativeIPXNetworking.parseValue("primary REG_BINARY 5ECD64631CB8", name: "primary"), .binary("5ecd64631cb8"))
        XCTAssertThrowsError(try NativeIPXNetworking.parseValue("primary REG_SZ manual", name: "primary"))
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        let changes = [NativeIPXNetworking.RegistryChange(key: NativeIPXNetworking.registryRoot, name: "use_pcap", previous: nil, applied: .dword(1))]
        try NativeIPXNetworking.apply(changes, for: g)
        try NativeIPXNetworking.write(.dword(0), key: changes[0].key, name: changes[0].name, for: g)
        XCTAssertThrowsError(try NativeIPXNetworking.restore(changes, for: g))
        XCTAssertEqual(try NativeIPXNetworking.read(changes[0].key, changes[0].name, for: g), .dword(0))
        try NativeIPXNetworking.write(.dword(1), key: changes[0].key, name: changes[0].name, for: g)
        try NativeIPXNetworking.restore(changes, for: g)
        XCTAssertNil(try NativeIPXNetworking.read(changes[0].key, changes[0].name, for: g))
    }
    func testPortableProfileFrameAndUndoKeepLocalPermissionsAndUserEdits() async throws {
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        g = try installRegistryRecord(g)
        var p = Profiles.make(from: g, rating: .works, notes: nil, install: nil)
        p.gameDisplay = nil
        XCTAssertTrue(p.fixes!.contains("native-ipx-networking")); XCTAssertEqual(p.nativeIPXFrame, 3)
        XCTAssertNil(p.environment?[NativeIPXNetworking.flag]); XCTAssertNil(p.environment?["WINEDLLPATH"])
        XCTAssertEqual(try GameProfile.parse(p.json()).nativeIPXFrame, 3)
        XCTAssertEqual(p.problems, [])
        p.nativeIPXFrame = 1
        let snapshot = try Profiles.apply(p, to: g, includeShared: false)
        try await Profiles.applyGameDisplay(p, to: g, snapshot: snapshot) { _ in }
        XCTAssertEqual(NativeIPXNetworking.frame(for: g), 1)
        try Profiles.undo(snapshot)
        XCTAssertEqual(NativeIPXNetworking.frame(for: g), 3)
        try NativeIPXNetworking.setFrame(2, for: g)
        XCTAssertThrowsError(try Profiles.undo(snapshot))
        XCTAssertEqual(NativeIPXNetworking.frame(for: g), 2)
        try CompatibilityFixes.undo(.nativeIPXNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertNil(try NativeIPXNetworking.read(NativeIPXNetworking.registryRoot, "frame_type", for: g))
        XCTAssertEqual(g.custom?.environment?["KEEP"], "yes")
        XCTAssertNil(g.custom?.environment?[NativeIPXNetworking.flag])
        p.nativeIPXFrame = 4; XCTAssertFalse(p.problems.isEmpty)
        p.nativeIPXFrame = 3; p.fixes = []; XCTAssertFalse(p.problems.isEmpty)
    }
    func testRedactedAdapterMigrationPreservesUndoAndManualChanges() throws {
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        g = try installRegistryRecord(g)
        var state = CompatibilityFixes.state(.nativeIPXNetworking, g)!
        let primary = NativeIPXNetworking.RegistryChange(key: NativeIPXNetworking.registryRoot, name: "primary", previous: .binary("ffffffffffff"), applied: .binary("020000000000"))
        state.registryChanges!.append(primary)
        try NativeIPXNetworking.apply([primary], for: g)
        try JSONEncoder().encode(state).write(to: CompatibilityFixes.marker(.nativeIPXNetworking, g))
        var config = g.custom!; config.environment![NativeIPXNetworking.interfaceFlag] = "en0"
        try CustomGames.save(config, to: g); g = CompatibilityFixes.fresh(g)
        // A later explicit registry choice blocks automatic repair.
        try NativeIPXNetworking.write(.binary("aabbccddeeff"), key: primary.key, name: primary.name, for: g)
        NativeIPXNetworking.refreshAdapter(g)
        XCTAssertEqual(try NativeIPXNetworking.read(primary.key, primary.name, for: g), .binary("aabbccddeeff"))
        try NativeIPXNetworking.write(primary.applied, key: primary.key, name: primary.name, for: g)
        NativeIPXNetworking.refreshAdapter(g)
        XCTAssertEqual(try NativeIPXNetworking.read(primary.key, primary.name, for: g), .binary("1234567890ab"))
        XCTAssertEqual(CompatibilityFixes.state(.nativeIPXNetworking, g)?.registryChanges?.first(where: { $0.name == "primary" })?.previous, .binary("ffffffffffff"))
        try CompatibilityFixes.undo(.nativeIPXNetworking, for: g) { _ in }
        XCTAssertEqual(try NativeIPXNetworking.read(primary.key, primary.name, for: g), .binary("ffffffffffff"))
    }
    func testWineAdapterIdentityRejectsRedactionAndKeepsCaptureIdentity() throws {
        let parsed = NativeIPXNetworking.wineAdapters("en0|{a}|5e:cd:64:63:1c:b8|192.168.1.2\r\nen1|{b}|02:00:00:00:00:00|192.168.1.3\nawdl0|{c}|12:34:56:78:90:ab|192.168.1.4\nen2|{d}|00:00:00:00:00:00|192.168.1.5")
        XCTAssertEqual(parsed, [.init(name: "en0", mac: "5E:CD:64:63:1C:B8", hasAddress: true)])
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        g = try installRegistryRecord(g)
        try NativeIPXNetworking.setAdapter("en0", for: g)
        XCTAssertEqual(try NativeIPXNetworking.read(NativeIPXNetworking.registryRoot, "primary", for: g), .binary("1234567890ab"))
        XCTAssertEqual(try NativeIPXNetworking.read(NativeIPXNetworking.registryRoot + "\\12:34:56:78:90:AB", "net", for: g), .binary("00000000"))
    }
    func testAdapterParsingAndLaunchPermissionScope() throws {
        let interfaces = NativeIPXNetworking.adapters("en0: flags=up\n\tether 5e:cd:64:63:1c:b8\n\tinet 192.168.1.203 netmask x\nawdl0: flags=up\n\tether 12:34:56:78:90:ab\n")
        XCTAssertEqual(interfaces.count, 2); XCTAssertTrue(interfaces[0].hasAddress); XCTAssertFalse(interfaces[1].hasAddress)
        let g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        var c = g.custom!
        XCTAssertFalse(CustomGames.launcherScript(for: c).contains("NOKCANDU_IPX_PERMISSION"))
        c.environment = [NativeIPXNetworking.flag: "1"]
        let script = CustomGames.launcherScript(for: c)
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("WINEDLLPATH=\"$SUPPORT/nokcandu/native-ipx/wine"))
        XCTAssertLessThan(script.range(of: "if [ \"$CHECK_ONLY\" = 1 ]")!.lowerBound, script.range(of: "NOKCANDU_IPX_PERMISSION")!.lowerBound)
        let file = g.appURL.appendingPathComponent("launcher-syntax.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", file.path]).ok)
        let appleStart = try XCTUnwrap(script.range(of: "on run argv\n"))
        let appleEnd = try XCTUnwrap(script.range(of: "\nNOKCANDU_IPX_PERMISSION\n", range: appleStart.lowerBound..<script.endIndex))
        let apple = g.appURL.appendingPathComponent("permission.applescript")
        try String(script[appleStart.lowerBound..<appleEnd.lowerBound]).write(to: apple, atomically: true, encoding: .utf8)
        let compiled = try Shell.run("/usr/bin/osacompile", ["-o", g.appURL.appendingPathComponent("permission.scpt").path, apple.path])
        XCTAssertTrue(compiled.ok, compiled.combined)
        let line = g.support.appendingPathComponent("wine/version")
        try "wine sikarugir 10.0 (revision 8)".write(to: line, atomically: true, encoding: .utf8)
        XCTAssertFalse(NativeIPXNetworking.supports(CompatibilityFixes.fresh(g)))
    }
    func testProtectedBootstrapChecksOnlyCopiedBytesWithoutPrivileges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-permission-test-" + UUID().uuidString)
        try NokPaths.ensure(root); defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper's copy")
        let payload = Data("#!/bin/bash\n( sleep 1; rm -f \"$3/native-ipx-access\"; rmdir \"$3\" ) </dev/null >/dev/null 2>&1 &\necho \"$3\"\n".utf8)
        try payload.write(to: helper)
        let bootstrap = NativeIPXNetworking.permissionBootstrap.components(separatedBy: .newlines).filter { !$0.contains("Native IPX authorization did not start as administrator") }.joined(separator: "\n")
        let result = try Shell.run("/bin/bash", ["-p", "-c", bootstrap, "ipx-bootstrap", helper.path, String(getuid()), Hashing.sha256(data: payload)], timeout: 5)
        XCTAssertTrue(result.ok, result.combined)
        let stage = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(stage.path.hasPrefix("/private/tmp/nokcandu-ipx."), result.stdout)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: stage.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("native-ipx-access")), payload)
        try Data("changed source".utf8).write(to: helper)
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("native-ipx-access")), payload)
        for _ in 0..<60 where FileManager.default.fileExists(atPath: stage.path) { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        let refused = try Shell.run("/bin/bash", ["-p", "-c", bootstrap, "ipx-bootstrap", helper.path, String(getuid()), Hashing.sha256(data: payload)], timeout: 5)
        XCTAssertFalse(refused.ok); XCTAssertTrue(refused.combined.contains("helper changed"))
        XCTAssertFalse(NativeIPXNetworking.launcherAccess.contains("1800"))
        XCTAssertFalse(NativeIPXNetworking.launcherAccess.contains("30 minutes"))
    }
    func testOwnedSessionHelperMigrationPreservesRegistryAndManualLaunchers() throws {
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        g = try installRegistryRecord(g)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-helper-resource-" + UUID().uuidString)
        try NokPaths.ensure(root); defer { try? FileManager.default.removeItem(at: root); NativeIPXNetworking.resourceForTesting = nil }
        NativeIPXNetworking.resourceForTesting = root
        let payload = Data("owned helper revision two".utf8)
        try payload.write(to: root.appendingPathComponent(NativeIPXNetworking.helperName))
        let launcher = g.launcherURL!, original = try Data(contentsOf: launcher)
        try Data("manual launcher".utf8).write(to: launcher)
        NativeIPXNetworking.refreshHelper(g)
        let target = NativeIPXNetworking.directory(g).appendingPathComponent(NativeIPXNetworking.helperName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: launcher), Data("manual launcher".utf8))
        try original.write(to: launcher)
        NativeIPXNetworking.refreshHelper(g)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertFalse(NativeIPXNetworking.needsUpdate(g))
        XCTAssertEqual(NativeIPXNetworking.frame(for: g), 3)
        XCTAssertEqual(CompatibilityFixes.state(.nativeIPXNetworking, g)?.registryChanges?.first?.previous, nil)
        try Data("later manual helper".utf8).write(to: target)
        try Data("new bundled helper".utf8).write(to: root.appendingPathComponent(NativeIPXNetworking.helperName))
        NativeIPXNetworking.refreshHelper(g)
        XCTAssertEqual(try Data(contentsOf: target), Data("later manual helper".utf8))
        XCTAssertThrowsError(try CompatibilityFixes.undo(.nativeIPXNetworking, for: g) { _ in })
        XCTAssertEqual(NativeIPXNetworking.frame(for: g), 3)
    }
    func testSessionManagerLifetimeAndConcurrentGamesWithoutPacketPrivileges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-session-helper-test-" + UUID().uuidString)
        try NokPaths.ensure(root); defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/native-ipx/access.c")
        let helper = root.appendingPathComponent("access-test")
        let compile = try Shell.run("/usr/bin/xcrun", ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-DNOK_IPX_TEST", source.path, "-o", helper.path], timeout: 30)
        XCTAssertTrue(compile.ok, compile.combined)
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tools/native-ipx/test-session-manager.py")
        let run = try Shell.run("/usr/bin/env", ["python3", script.path, helper.path], timeout: 15)
        XCTAssertTrue(run.ok, run.combined)
        XCTAssertTrue(run.stdout.contains("Two-game session lifetime"))
    }
    func testAdapterSelectionIsLocalAndUndoKeepsPreviousSettings() throws {
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        g = try installRegistryRecord(g)
        guard let adapter = NativeIPXNetworking.availableAdapters().first else { throw XCTSkip("Requires a connected local LAN interface") }
        try NativeIPXNetworking.setAdapter(adapter.id, for: g)
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment?[NativeIPXNetworking.interfaceFlag], adapter.id)
        XCTAssertEqual(WineTools.environment(contents: g.contents)[NativeIPXNetworking.interfaceFlag], adapter.id)
        let profile = Profiles.make(from: g, rating: .works, notes: nil, install: nil)
        XCTAssertNil(profile.environment?[NativeIPXNetworking.interfaceFlag])
        XCTAssertThrowsError(try NativeIPXNetworking.setAdapter("not-a-real-interface", for: g))
        try CompatibilityFixes.undo(.nativeIPXNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertNil(g.custom?.environment?[NativeIPXNetworking.interfaceFlag])
        XCTAssertEqual(g.custom?.environment?["KEEP"], "yes")
    }
    func testNativeComponentOfficialPackagesAndUndoE2E() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_E2E_IPX"] == "1" else { throw XCTSkip("Requires verified official packages and the built native packet module") }
        var g = try fixture(); defer { try? FileManager.default.removeItem(at: g.appURL) }
        guard NativeIPXNetworking.supports(g) else { throw XCTSkip("Build Nokcandu with the native IPX module first") }
        let before = g.custom!
        try await CompatibilityFixes.install(.nativeIPXNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertTrue(CompatibilityFixes.isInstalled(.ipxNetworking, for: g))
        XCTAssertTrue(CompatibilityFixes.isInstalled(.nativeIPXNetworking, for: g))
        let game = CompatibilityFixes.managedProgram(g)!.deletingLastPathComponent()
        XCTAssertEqual(try Hashing.sha256(file: game.appendingPathComponent("dpwsockx.dll")), NativeIPXNetworking.providerSHA)
        XCTAssertEqual(NativeIPXNetworking.frame(for: g), 3)
        XCTAssertThrowsError(try CompatibilityFixes.undo(.ipxNetworking, for: g) { _ in })
        try CompatibilityFixes.undo(.nativeIPXNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("wpcap.dll").path))
        XCTAssertNotEqual(try Hashing.sha256(file: game.appendingPathComponent("dpwsockx.dll")), NativeIPXNetworking.providerSHA)
        try CompatibilityFixes.undo(.ipxNetworking, for: g) { _ in }
        g = CompatibilityFixes.fresh(g)
        XCTAssertEqual(g.custom?.environment, before.environment)
        XCTAssertEqual(g.custom?.graphics, before.graphics)
    }
}
