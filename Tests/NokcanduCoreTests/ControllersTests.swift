import XCTest
@testable import NokcanduCore

final class ControllersTests: XCTestCase {
    func testModesDecideEachMakerAndWineDefaultsStay() {
        XCTAssertEqual(Controllers.plan(.native, steam: false)[.nintendo], true)
        XCTAssertEqual(Controllers.plan(.xbox, steam: true)[.playstation], false)
        XCTAssertEqual(Controllers.plan(.automatic, steam: true)[.valve], true)
        XCTAssertEqual(Controllers.plan(.automatic, steam: false)[.nintendo], .some(nil))
        XCTAssertTrue(Controllers.passesThrough(.playstation, mode: .automatic, steam: false), "Wine passes PlayStation controllers through by default")
        XCTAssertFalse(Controllers.passesThrough(.nintendo, mode: .automatic, steam: false))
        XCTAssertTrue(Controllers.passesThrough(.nintendo, mode: .automatic, steam: true))
        XCTAssertFalse(Controllers.passesThrough(nil, mode: .native, steam: true), "other makers are always converted")
    }

    func testRegistryKeysAreWrittenAndRemovedWithoutTouchingTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-ctl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let system = root.appendingPathComponent("system.reg")
        try "WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n[Software\\\\Other] 1700000000\n\"Keep\"=\"me\"\n".write(to: system, atomically: true, encoding: .utf8)

        try Controllers.apply(Controllers.plan(.native, steam: false), system: system)
        var text = try String(contentsOf: system, encoding: .utf8)
        XCTAssertTrue(text.contains("[System\\\\CurrentControlSet\\\\Services\\\\WineBus\\\\Devices\\\\057e]"))
        XCTAssertTrue(text.contains("[System\\\\CurrentControlSet\\\\Services\\\\WineBus\\\\Devices\\\\28de]"))
        XCTAssertEqual(text.components(separatedBy: "\"Hidraw\"=dword:00000001").count - 1, 3)

        try Controllers.apply(Controllers.plan(.xbox, steam: false), system: system)
        text = try String(contentsOf: system, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\"Hidraw\"=dword:00000000").count - 1, 3)
        XCTAssertFalse(text.contains("dword:00000001"))

        try Controllers.apply(Controllers.plan(.automatic, steam: false), system: system)
        text = try String(contentsOf: system, encoding: .utf8)
        XCTAssertFalse(text.contains("\"Hidraw\""), "Automatic outside Steam leaves Wine's defaults")
        XCTAssertTrue(text.contains("\"Keep\"=\"me\""))
    }

    func testDescriptionsSayWhatWindowsSees() {
        let pro = Controllers.Connected(name: "Pro Controller", vendorID: 0x057E, productID: 0x2009, location: 1, bluetooth: true, isGamepad: true)
        XCTAssertEqual(Controllers.describe(pro, mode: .automatic, steam: false), "As an Xbox controller (gyro isn't passed on this way).")
        XCTAssertTrue(Controllers.describe(pro, mode: .automatic, steam: true).hasPrefix("As itself, with gyro. Steam Input"))
        let steamController = Controllers.Connected(name: "Steam Controller", vendorID: 0x28DE, productID: 0x1142, location: 2, bluetooth: false, isGamepad: false)
        XCTAssertTrue(Controllers.describe(steamController, mode: .native, steam: true).hasPrefix("Not seen by Windows programs yet"))
        XCTAssertEqual(pro.ids, "057E:2009")
    }
}

final class KeyRemapTests: XCTestCase {
    func testMappingsBecomeMacKeyboardRemapsAndBack() {
        let m = [KeyRemap.Mapping(from: 63, to: 59), KeyRemap.Mapping(from: 59, to: 63), KeyRemap.Mapping(from: 61, to: 62), KeyRemap.Mapping(from: 0, to: nil)]
        let text = KeyRemap.text(m)
        XCTAssertEqual(text, "0xff0100000003 0x7000000e0\n0x7000000e0 0xff0100000003\n0x7000000e6 0x7000000e4\n0x700000004 0x700000000\n")
        XCTAssertEqual(KeyRemap.parse(text), m)
        XCTAssertEqual(Set(KeyRemap.keys.map(\.code)).count, KeyRemap.keys.count, "no key listed twice")
        XCTAssertTrue(KeyRemap.keys.allSatisfy { KeyRemap.hidUsages[$0.code] != nil }, "every listed key can be remapped")
        XCTAssertEqual(KeyRemap.hidUsages[16], 0x7_0000_001C, "Y")
        XCTAssertEqual(KeyRemap.hidUsages[29], 0x7_0000_0027, "0")
    }

    func testKarabinerSimpleModificationsAreCopied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-kb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: root) }
        try #"""
        {"profiles":[{"name":"Default profile","simple_modifications":[{"from":{"key_code":"right_option"},"to":[{"key_code":"right_control"}]}]},
         {"name":"Voidlink","selected":true,"simple_modifications":[{"from":{"apple_vendor_top_case_key_code":"keyboard_fn"},"to":[{"key_code":"left_control"}]},
          {"from":{"key_code":"left_control"},"to":[{"apple_vendor_top_case_key_code":"keyboard_fn"}]},{"from":{"key_code":"caps_lock"},"to":[{"key_code":"vk_none"}]},
          {"from":{"consumer_key_code":"mute"},"to":[{"key_code":"f1"}]}],
          "complex_modifications":{"rules":[{"description":"x"}]}}]}
        """#.write(to: root, atomically: true, encoding: .utf8)
        let p = KeyRemap.karabinerProfiles(root)
        XCTAssertEqual(p.map(\.name), ["Default profile", "Voidlink"])
        XCTAssertEqual(p[0].mappings, [KeyRemap.Mapping(from: 61, to: 62)])
        XCTAssertEqual(p[1].mappings, [KeyRemap.Mapping(from: 63, to: 59), KeyRemap.Mapping(from: 59, to: 63), KeyRemap.Mapping(from: 57, to: nil)])
        XCTAssertEqual(p[1].skipped, 2)
        XCTAssertTrue(p[1].selected)
    }
}

final class ControllerKindTests: XCTestCase {
    func testWheelsPedalsAndFlightGearAreRecognized() {
        XCTAssertEqual(Controllers.kind(vendorID: 0x046D, productID: 0xC24F, usagePage: 1, usage: 4), .wheel, "Logitech G29")
        XCTAssertEqual(Controllers.kind(vendorID: 0x044F, productID: 0xB66E, usagePage: 1, usage: 4), .wheel, "Thrustmaster T300")
        XCTAssertEqual(Controllers.kind(vendorID: 0x044F, productID: 0xB679, usagePage: 1, usage: 4), .flight, "Thrustmaster rudder pedals")
        XCTAssertEqual(Controllers.kind(vendorID: 0x0EB7, productID: 0x0001, usagePage: 1, usage: 4), .wheel, "Fanatec")
        XCTAssertEqual(Controllers.kind(vendorID: 0x231D, productID: 0x0200, usagePage: 1, usage: 4), .flight, "VKB")
        XCTAssertEqual(Controllers.kind(vendorID: 0x1234, productID: 0x1, usagePage: 2, usage: 0x02), .wheel, "simulation: automobile")
        XCTAssertEqual(Controllers.kind(vendorID: 0x045E, productID: 0x0B13, usagePage: 1, usage: 5), .gamepad, "Xbox")
        let pedals = Controllers.Connected(name: "Pedals", vendorID: 0x1234, productID: 1, location: 3, bluetooth: false, isGamepad: false, usagePage: 2, usage: 0xBB)
        XCTAssertTrue(Controllers.describe(pedals, mode: .automatic, steam: false).hasPrefix("Not seen by Windows programs yet"))
        let wheel = Controllers.Connected(name: "G29", vendorID: 0x046D, productID: 0xC24F, location: 4, bluetooth: false, isGamepad: true, usagePage: 1, usage: 4)
        XCTAssertEqual(Controllers.describe(wheel, mode: .xbox, steam: false), "As itself: its own axes and buttons, for games with wheel support.")
    }
}

final class KeyLayoutTests: XCTestCase {
    func testLayoutsDefaultsAndGamesWithTheirOwnKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lf = root.appendingPathComponent("key-layouts.json"), df = root.appendingPathComponent("key-layout-default")
        let a = root.appendingPathComponent("A.app/Contents"), b = root.appendingPathComponent("B.app/Contents")
        let c = root.appendingPathComponent("C.app/Contents"), d = root.appendingPathComponent("D.app/Contents")
        let all = [a, b, c, d]
        let voidlink = KeyRemap.Layout(name: "Voidlink", mappings: [KeyRemap.Mapping(from: 63, to: 59)])
        var racing = KeyRemap.Layout(name: "Racing", mappings: [KeyRemap.Mapping(from: 61, to: 62)])
        try KeyRemap.store(voidlink, environments: all, file: lf, defaultFile: df)
        try KeyRemap.store(racing, environments: all, file: lf, defaultFile: df)
        XCTAssertEqual(KeyRemap.choice(contents: a), .followDefault, "every game starts on the default")

        try KeyRemap.set(.layout(racing.id), contents: b, file: lf, defaultFile: df)
        try KeyRemap.set(.own, contents: c, own: [KeyRemap.Mapping(from: 0, to: nil)], file: lf, defaultFile: df)
        try KeyRemap.set(.normal, contents: d, file: lf, defaultFile: df)
        try KeyRemap.setDefault(voidlink, environments: all, file: df, layoutsFile: lf)
        XCTAssertEqual(KeyRemap.load(contents: a), voidlink.mappings, "the default reaches games following it")
        XCTAssertEqual(KeyRemap.load(contents: b), racing.mappings, "a game's own choice isn't overridden")
        XCTAssertEqual(KeyRemap.load(contents: c), [KeyRemap.Mapping(from: 0, to: nil)])
        XCTAssertEqual(KeyRemap.load(contents: d), [], "normal keys stay normal")

        racing.mappings.append(KeyRemap.Mapping(from: 58, to: 59))
        try KeyRemap.store(racing, environments: all, file: lf, defaultFile: df)
        XCTAssertEqual(KeyRemap.load(contents: b), racing.mappings, "editing a layout reaches every game using it")

        try KeyRemap.delete(voidlink, environments: all, file: lf, defaultFile: df)
        XCTAssertNil(KeyRemap.defaultLayoutID(file: df))
        XCTAssertEqual(KeyRemap.load(contents: a), [], "no default: normal keys")
        try KeyRemap.delete(racing, environments: all, file: lf, defaultFile: df)
        XCTAssertEqual(KeyRemap.choice(contents: b), .own)
        XCTAssertEqual(KeyRemap.load(contents: b), racing.mappings, "keys stay after their layout is deleted")
    }
}

final class LaunchServicesCleanupTests: XCTestCase {
    func testOnlyStaleNokcanduRecordsAreRemoved() {
        let dump = """
        path:                       /Users/me/Applications/Sikarugir/Battlefield 2.app/Contents/SharedSupport/GameApp/Battlefield 2.app (0x4044)
        identifier:                 local.nokcandu.game.battlefield-2
        --------------------------------------------------------------------------------
        path:                       /Volumes/Games/Nokcandu Games/Battlefield 2.app/Contents/SharedSupport/GameApp/Battlefield 2.app (0x7ec8)
        identifier:                 local.nokcandu.game.battlefield-2
        --------------------------------------------------------------------------------
        path:                       /private/var/folders/x/T/profile-display-1.app/Contents/SharedSupport/GameApp/Profile display test.app (0x1)
        identifier:                 local.nokcandu.game.profile-display-test
        --------------------------------------------------------------------------------
        path:                       /Users/me/.Trash/Battlefield 1942™.app (0x2)
        identifier:                 local.nokcandu.ea.battlefield-1942
        --------------------------------------------------------------------------------
        path:                       /Applications/Sikarugir/.Nokcandu Restore Points/Worms/2026/App/Contents/Configure.app (0x3)
        identifier:                 com.sikarugir.configure
        --------------------------------------------------------------------------------
        path:                       /Users/me/Applications/Sikarugir/Gone.app (0x4)
        identifier:                 local.nokcandu.gone
        --------------------------------------------------------------------------------
        path:                       /Applications/Safari.app (0x5)
        identifier:                 com.apple.Safari
        """
        let records = SystemIntegration.records(dump: dump)
        XCTAssertEqual(records.count, 7)
        let stale = SystemIntegration.stale(records, exists: { !$0.contains("Gone") }, resolve: { p in
            p.replacingOccurrences(of: "/Users/me/Applications/Sikarugir/Battlefield 2.app", with: "/Volumes/Games/Nokcandu Games/Battlefield 2.app")
        }).map(\.path)
        XCTAssertEqual(stale, [
            "/Users/me/Applications/Sikarugir/Battlefield 2.app/Contents/SharedSupport/GameApp/Battlefield 2.app",
            "/private/var/folders/x/T/profile-display-1.app/Contents/SharedSupport/GameApp/Profile display test.app",
            "/Users/me/.Trash/Battlefield 1942™.app",
            "/Applications/Sikarugir/.Nokcandu Restore Points/Worms/2026/App/Contents/Configure.app",
            "/Users/me/Applications/Sikarugir/Gone.app",
        ])
        XCTAssertTrue(SystemIntegration.isTesting)
    }
}

final class SharedLauncherKeysTests: XCTestCase {
    func testGamesInsideALauncherCanHaveTheirOwnKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-routes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("Battle.net.app/Contents")
        let wine = host.appendingPathComponent("SharedSupport/wine/bin/wine")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: wine.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        try NokPaths.ensure(KeyRemap.folder(host))
        try "battle.net.exe\tBattle.net\noverwatch.exe\tOverwatch\nd2r.exe\tDiablo II Resurrected\n".write(to: KeyRemap.folder(host).appendingPathComponent("app-names.tsv"), atomically: true, encoding: .utf8)
        func game(_ name: String, uid: String) -> InstalledGame {
            var g = InstalledGame(appURL: root.appendingPathComponent("\(name).app"), name: name)
            g.battleNet = BattleNetLink(hostApp: root.appendingPathComponent("Battle.net.app").path, uid: uid, code: "X", name: name)
            return g
        }
        let ow = game("Overwatch", uid: "prometheus"), d2 = game("Diablo II Resurrected", uid: "osi")
        XCTAssertEqual(KeyRemap.choice(contents: ow.contents, shared: true), .sameAsLauncher, "games start on the launcher's keys")
        XCTAssertEqual(KeyRemap.refreshRoutes([ow, d2]), 0)

        try KeyRemap.set(.own, contents: ow.contents, own: [KeyRemap.Mapping(from: 63, to: 59)])
        KeyRemap.refreshRoutes([ow, d2])
        let routes = try String(contentsOf: KeyRemap.routesFile(host), encoding: .utf8)
        XCTAssertEqual(routes, "overwatch.exe\t" + KeyRemap.file(ow.contents).path + "\n")
        XCTAssertEqual(KeyRemap.load(contents: ow.contents), [KeyRemap.Mapping(from: 63, to: 59)])

        // A default layout doesn't touch a game using the launcher's keys.
        let lf = root.appendingPathComponent("layouts.json"), df = root.appendingPathComponent("default")
        let l = KeyRemap.Layout(name: "L", mappings: [KeyRemap.Mapping(from: 61, to: 62)])
        try KeyRemap.store(l, environments: [host], shared: [ow.contents, d2.contents], file: lf, defaultFile: df)
        try KeyRemap.setDefault(l, environments: [host], shared: [ow.contents, d2.contents], file: df, layoutsFile: lf)
        XCTAssertEqual(KeyRemap.load(contents: d2.contents), [])
        XCTAssertEqual(KeyRemap.load(contents: host), l.mappings, "the launcher itself follows the default")

        try KeyRemap.set(.sameAsLauncher, contents: ow.contents)
        KeyRemap.refreshRoutes([ow, d2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: KeyRemap.routesFile(host).path))
    }
}

final class LibraryDiscoveryTests: XCTestCase {
    func testFoldersOfGameAppsAreFoundWithoutTheLibraryOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-disc-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ path: String) throws {
            let c = root.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: c.appendingPathComponent("SharedSupport/prefix"), withIntermediateDirectories: true)
            try (["CFBundleName": "G"] as NSDictionary).write(to: c.appendingPathComponent("Info.plist"))
        }
        try app("Drive/Nokcandu Games/A.app"); try app("Drive/Nokcandu Games/B.app")
        try app("Drive/Old/Deep/C.app")
        try app("Drive/.Nokcandu Restore Points/X/D.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Drive/Other.app/Contents"), withIntermediateDirectories: true)   // not a game
        let found = LibraryDiscovery.folders(in: root.appendingPathComponent("Drive"), depth: 3, known: [])
        XCTAssertEqual(found.map(\.folder.lastPathComponent), ["Nokcandu Games", "Deep"])
        XCTAssertEqual(found.map(\.games), [2, 1])
        let known = LibraryDiscovery.folders(in: root.appendingPathComponent("Drive"), depth: 3, known: [root.appendingPathComponent("Drive/Nokcandu Games")])
        XCTAssertEqual(known.map(\.folder.lastPathComponent), ["Deep"])
        let inLibrary = LibraryDiscovery.folders(in: root.appendingPathComponent("Drive"), depth: 3, known: [],
                                                 library: [root.appendingPathComponent("Drive/Old/Deep/C.app").path])
        XCTAssertEqual(inLibrary.map(\.folder.lastPathComponent), ["Nokcandu Games"])
    }
}
