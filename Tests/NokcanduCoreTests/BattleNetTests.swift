import XCTest
@testable import NokcanduCore

final class BattleNetTests: XCTestCase {
    func testParsesBlizzardGamesAndPaths() throws {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent("bnet-\(UUID().uuidString.prefix(4))/Battle.net.app")
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/d:").path, withDestinationPath: "/Volumes/Elements/Games")
        let reg = #"""
        WINE REGISTRY Version 2

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Battle.net] 1
        "DisplayName"="Battle.net"
        "UninstallString"="\"C:\\ProgramData\\Battle.net\\Agent\\Blizzard Uninstaller.exe\" --lang=enUS --uid=battle.net --displayname=\"Battle.net\""

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Diablo II Resurrected] 1
        "DisplayIcon"="D:\\Diablo II Resurrected\\D2R.exe"
        "DisplayName"="Diablo II Resurrected"
        "InstallLocation"="D:\\Diablo II Resurrected"
        "UninstallString"="\"C:\\ProgramData\\Battle.net\\Agent\\Blizzard Uninstaller.exe\" --lang=enUS --uid=osi --displayname=\"Diablo II Resurrected\""

        """#
        try Data(reg.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        let host = InstalledGame(appURL: app, name: "Battle.net")
        let games = BattleNet.installedGames(host: host)
        XCTAssertEqual(games.map(\.uid), ["osi"])
        XCTAssertEqual(games.first?.code, "OSI")
        XCTAssertEqual(games.first?.exe, #"D:\Diablo II Resurrected\D2R.exe"#)
        XCTAssertEqual(BattleNet.unixPath(games[0].exe!, prefix: prefix)?.path, "/Volumes/Elements/Games/Diablo II Resurrected/D2R.exe")
        XCTAssertEqual(BattleNet.code(for: "s1"), "S1")

        let script = BattleNet.launcherScript(BattleNetLink(hostApp: app.path, uid: "osi", code: "OSI", name: "Diablo II: Resurrected"))
        let f = app.deletingLastPathComponent().appendingPathComponent("l.sh"); try Data(script.utf8).write(to: f)
        let r = try Shell.run("/bin/bash", ["-n", f.path]); XCTAssertTrue(r.ok, r.combined)
        XCTAssertTrue(script.contains(#"--exec="launch $CODE""#))
    }
}
