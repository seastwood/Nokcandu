import XCTest
@testable import NokcanduCore

final class SharedSteamTests: XCTestCase {
    func bashSyntax(_ script: String, _ name: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nok-\(name).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        let r = try Shell.run("/bin/bash", ["-n", tmp.path])   // macOS /bin/bash is 3.2 — the one the apps run with
        XCTAssertTrue(r.ok, r.combined + "\n" + script)
    }

    func testScriptsAreValidBash() throws {
        try bashSyntax(SharedSteam.helperScript(), "helper")
        try bashSyntax(SharedSteam.hostLauncherScript(), "host")
        let game = SharedSteam.gameLauncherScript(appID: 240, name: "Counter-Strike: Source", graphics: .classic3D,
                                                  steamApp: URL(fileURLWithPath: "/Users/x/Applications/Sikarugir/Steam.app"))
        try bashSyntax(game, "game")
        XCTAssertTrue(game.contains("--applaunch 240"))
        for p in GraphicsPreset.allCases { XCTAssertTrue(SharedSteam.helperScript().contains(" \(p.rawValue))")) }
    }

    func testHelperRefusesBadAppIDAndUnknownMode() throws {
        // Runs the helper for real against an empty fake app: it must stop before touching anything.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-steam-\(UUID().uuidString)")
        let res = root.appendingPathComponent("Steam.app/Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let h = res.appendingPathComponent("nokcandu-steam")
        try SharedSteam.helperScript().write(to: h, atomically: true, encoding: .utf8)
        XCTAssertFalse(try Shell.run("/bin/bash", [h.path, "--applaunch", "24x"]).ok)
        let r = try Shell.run("/bin/bash", [h.path, "--mode", "nope"])
        XCTAssertEqual(r.status, 2)
        XCTAssertFalse(try Shell.run("/bin/bash", [h.path, "--check"]).ok, "no wine/steam in the fake app")
    }

    func testSteamFilesParse() throws {
        let users = #"""
        "users"
        {
            "76561197960287930"
            {
                "AccountName"   "player_example"
                "PersonaName"   "Player"
                "MostRecent"    "1"
            }
        }
        """#
        let n = try VDF.parse(users)
        XCTAssertEqual(n["users"]?["76561197960287930"]?["PersonaName"]?.string, "Player")
        let manifest = #"""
        "AppState"
        {
            "appid"     "240"
            "name"      "Counter-Strike: Source"
            "StateFlags"        "4"
            "installdir"        "Counter-Strike Source"
            "SizeOnDisk"        "4500000000"
        }
        """#
        let m = try XCTUnwrap(VDF.parse(manifest)["AppState"])
        XCTAssertEqual(m["StateFlags"]?.string.flatMap(Int.init).map { $0 & 4 }, 4)
        XCTAssertEqual(m["installdir"]?.string, "Counter-Strike Source")
    }

    func testSteamGameConfigUsesThinLauncher() {
        let c = CustomGameConfig(id: "steam-240", name: "CSS", source: .steamLibrary, steamAppID: 240,
                                 exe: CustomGames.steamExe, graphics: .classic3D)
        XCTAssertTrue(CustomGames.launcherScript(for: c).contains("nokcandu-steam"))
    }
}

final class SettingsTests: XCTestCase {
    func testEnvAndSteamArgsInLaunchers() throws {
        var c = CustomGameConfig(id: "t", name: "T", source: .folder, exe: #"C:\Games\T\t.exe"#, graphics: .classic3D)
        c.environment = ["DXVK_HUD": "fps", "PATH": "/evil", "bad name": "x"]
        let s = CustomGames.launcherScript(for: c)
        XCTAssertTrue(s.contains("export DXVK_HUD='fps'"))
        XCTAssertFalse(s.contains("/evil"))
        XCTAssertFalse(s.contains("bad name"))
        var st = CustomGameConfig(id: "s", name: "S", source: .steamLibrary, steamAppID: 240, exe: CustomGames.steamExe, graphics: .classic3D)
        st.arguments = "-novid -console"
        let g = CustomGames.launcherScript(for: st)
        XCTAssertTrue(g.contains("-- '-novid' '-console'"))
        for (n, text) in [("env", s), ("steamargs", g)] {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nok-\(n).sh")
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            XCTAssertTrue(try Shell.run("/bin/bash", ["-n", tmp.path]).ok)
        }
    }

    func testOldGameJSONWithoutEnvironmentStillLoads() throws {
        let json = #"{"schema":1,"id":"x","name":"X","source":"folder","exe":"C:\\Games\\X\\x.exe","arguments":"","graphics":"dx9","detectedAPIs":[],"createdAt":"2026-10-24T22:22:27Z"}"#
        let c = try ChangeJournal.decoder.decode(CustomGameConfig.self, from: Data(json.utf8))
        XCTAssertNil(c.environment)
    }
}

final class CinematicTests: XCTestCase {
    func testLauncherRecordsExitAndQuartzErrors() throws {
        let c = CustomGameConfig(id: "t", name: "T", source: .folder, exe: #"C:\Games\T\t.exe"#, graphics: .classic3D)
        let s = CustomGames.launcherScript(for: c)
        XCTAssertTrue(s.contains("err+quartz"))
        XCTAssertTrue(s.contains("nokcandu: game exited with status"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nok-cine.sh")
        try s.write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", tmp.path]).ok)
    }

    func testDiagnosisFindsVideoErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-cine-\(UUID().uuidString)")
        let app = root.appendingPathComponent("G.app/Contents/SharedSupport/Logs")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "msync: up\n0128:err:quartz:FilterGraph2_RenderFile Failed to render source pin, hr 0x80040218.\nnokcandu: game exited with status 5 after 12s\n"
            .write(to: app.appendingPathComponent("launch.log"), atomically: true, encoding: .utf8)
        let g = InstalledGame(appURL: root.appendingPathComponent("G.app"), name: "G")
        let d = try XCTUnwrap(CinematicFix.diagnoseLastRun(g))
        XCTAssertEqual(d.exitStatus, 5); XCTAssertEqual(d.seconds, 12)
        XCTAssertTrue(d.evidence.contains("quartz"))
    }
}
