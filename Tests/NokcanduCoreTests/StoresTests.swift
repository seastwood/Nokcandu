import XCTest
@testable import NokcanduCore

final class StoresTests: XCTestCase {
    func testSignInCodes() {
        XCTAssertEqual(StoreAccounts.code(from: URL(string: "https://embed.gog.com/on_login_success?origin=client&code=ABC123")!, store: .gog), "ABC123")
        XCTAssertNil(StoreAccounts.code(from: URL(string: "https://auth.gog.com/auth?code=nope")!, store: .gog))
        XCTAssertEqual(StoreAccounts.code(from: URL(string: "https://www.amazon.com/?openid.assoc_handle=amzn_sonic_games_launcher&openid.oa2.authorization_code=ZZ9")!, store: .amazon), "ZZ9")
        XCTAssertEqual(StoreAccounts.epicCode(fromPageText: #"{"warning":"x","redirectUrl":"y","authorizationCode":"e123","sid":null}"#), "e123")
        XCTAssertNil(StoreAccounts.epicCode(fromPageText: "<html>"))
    }

    func testGogPlayTaskAndFuel() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nok-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let game = root.appendingPathComponent("Heroes")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        try #"{"gameId":"1207658787","playTasks":[{"category":"document","path":"manual.pdf"},{"category":"game","isPrimary":true,"path":"bin\\heroes.exe","arguments":"-windowed"}]}"#
            .write(to: game.appendingPathComponent("goggame-1207658787.info"), atomically: true, encoding: .utf8)
        let t = try StoreAccounts.gogPlayTask(in: root, id: "1207658787")
        XCTAssertTrue(t.exe.path.hasSuffix("/Heroes/bin/heroes.exe"), t.exe.path)
        XCTAssertEqual(t.arguments, "-windowed")
        let fuel = #"{ /* comment */ "SchemaVersion": "2", "Main": { "Command": "Binaries\\Win64\\Game.exe", "Args": [] } }"#
        XCTAssertEqual(StoreAccounts.jsonValue(fuel, "Command"), #"Binaries\Win64\Game.exe"#)
    }

    func testLauncherLinesAreValidBash() throws {
        for s in [Store.epic, .amazon, .gog] {
            let script = "set -euo pipefail\nCHECK_ONLY=1\nLOG_DIR=/tmp\n" + StoreAccounts.launcherLines(StoreLink(store: s, id: "Fortune'sGame")) +
                #"echo ${STORE_ARGS[@]+"${STORE_ARGS[@]}"}"# + "\n"
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("nok-store-\(s.rawValue).sh")
            try script.write(to: f, atomically: true, encoding: .utf8)
            let r = try Shell.run("/bin/bash", ["-n", f.path])
            XCTAssertTrue(r.ok, "\(s): \(r.combined)")
            let run = try Shell.run("/bin/bash", [f.path])
            XCTAssertTrue(run.ok, "\(s): \(run.combined)")
        }
    }

    func testCustomLauncherPassesStoreArgs() throws {
        var c = CustomGameConfig(id: "g-1", name: "Epic Game", source: .store, steamAppID: nil, exe: #"C:\Games\Epic Game\game.exe"#,
                                 graphics: .classic3D)
        c.store = StoreLink(store: .epic, id: "Abc")
        let s = CustomGames.launcherScript(for: c)
        XCTAssertTrue(s.contains("legendary"))
        XCTAssertTrue(s.contains(#"${STORE_ARGS[@]+"${STORE_ARGS[@]}"}"#))
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("nok-store-launcher.sh")
        try s.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", f.path]).ok)
    }

    func testHostedLauncherUsesOnlyItsOwnLiveHostAndPreservesManualEdits() throws {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent("Host with spaces-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        let support = contents.appendingPathComponent("SharedSupport")
        let lock = support.appendingPathComponent("Logs/game.lock")
        let launcher = contents.appendingPathComponent("MacOS/game-launcher")
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: lock, withIntermediateDirectories: true)
        try "#!/bin/bash\nsleep 30\n".write(to: launcher, atomically: true, encoding: .utf8)
        let running = Process(); running.executableURL = URL(fileURLWithPath: "/bin/bash"); running.arguments = [launcher.path]
        try running.run()
        defer { running.terminate() }
        let link = HostedGameLink(hostApp: app.path, launcher: .ea, id: "game", name: "Game", exe: nil)
        let check = CustomGames.shellQuote
        let script = "SUPPORT=\(check(support.path))\nHC=\(check(contents.path))\n" + PCLaunchers.hostRunningCheck(link) + "\nup\n"
        let probe = app.appendingPathComponent("check.sh")
        try script.write(to: probe, atomically: true, encoding: .utf8)
        // An unrelated live process cannot make another host appear ready.
        try "\(ProcessInfo.processInfo.processIdentifier)".write(to: lock.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try Shell.run("/bin/bash", [probe.path]).ok)
        try "\(running.processIdentifier)".write(to: lock.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", [probe.path]).ok)
        try "bad".write(to: lock.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        XCTAssertFalse(try Shell.run("/bin/bash", [probe.path]).ok)

        let game = InstalledGame(appURL: app, name: "Game", hosted: link)
        let legacy = PCLaunchers.launcherScript(link, legacyProcessDetection: true)
        try legacy.write(to: launcher, atomically: true, encoding: .utf8)
        PCLaunchers.refreshLaunchers([game])
        XCTAssertEqual(try String(contentsOf: launcher, encoding: .utf8), PCLaunchers.launcherScript(link))
        let edited = legacy + "\n# My custom launch settings\n"
        try edited.write(to: launcher, atomically: true, encoding: .utf8)
        PCLaunchers.refreshLaunchers([game])
        XCTAssertEqual(try String(contentsOf: launcher, encoding: .utf8), edited)
    }

    func testLauncherGamesFromRegistry() throws {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent("nok-pcl-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: app) }
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        let reg = #"""
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\635] 1700000000
        "InstallDir"="C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Far Cry 3/"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{ABC}] 1700000000
        "DisplayIcon"="C:\\Program Files\\EA Games\\Titanfall2\\Titanfall2.exe,0"
        "DisplayName"="Titanfall 2"
        "InstallLocation"="C:\\Program Files\\EA Games\\Titanfall2\\"
        "Publisher"="Electronic Arts"

        [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\EA app] 1700000000
        "DisplayName"="EA app"
        "InstallLocation"="C:\\Program Files\\Electronic Arts\\EA Desktop\\"
        "Publisher"="Electronic Arts"
        """#
        try reg.write(to: prefix.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
        let host = InstalledGame(appURL: app, name: "Host")
        let ubi = PCLaunchers.installedGames(.ubisoft, host: host)
        XCTAssertEqual(ubi.map(\.id), ["635"]); XCTAssertEqual(ubi.first?.name, "Far Cry 3")
        let ea = PCLaunchers.installedGames(.ea, host: host)
        XCTAssertEqual(ea.map(\.name), ["Titanfall 2"])
        XCTAssertEqual(ea.first?.exe, #"C:\Program Files\EA Games\Titanfall2\Titanfall2.exe"#)
        for l in [HostedGameLink(hostApp: app.path, launcher: .ubisoft, id: "635", name: "Far Cry 3", exe: nil),
                  HostedGameLink(hostApp: app.path, launcher: .ea, id: "Titanfall2", name: "Titanfall 2", exe: ea.first?.exe)] {
            let f = fm.temporaryDirectory.appendingPathComponent("nok-pcl-\(l.launcher.rawValue).sh")
            try PCLaunchers.launcherScript(l).write(to: f, atomically: true, encoding: .utf8)
            XCTAssertTrue(try Shell.run("/bin/bash", ["-n", f.path]).ok)
        }
    }
}
