import XCTest
@testable import NokcanduCore

final class CustomGameTests: XCTestCase {
    func config(disc: Bool) -> CustomGameConfig {
        CustomGameConfig(id: "test", name: "Test's Game", source: disc ? .disc : .installer,
                         exe: #"C:\Games\Test's Game\bin\game.exe"#, arguments: #"-windowed "-name x""#,
                         graphics: .modern3D,
                         disc: disc ? DiscSpec(imageName: "Test Disc.iso", volumeLabel: "TEST", internalMountDir: "SharedSupport/MountedDisc") : nil)
    }

    func testLauncherScriptIsValidBash() throws {
        for disc in [false, true] {
            let script = CustomGames.launcherScript(for: config(disc: disc))
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nok-launcher-\(disc).sh")
            try script.write(to: tmp, atomically: true, encoding: .utf8)
            let r = try Shell.run("/bin/bash", ["-n", tmp.path])
            XCTAssertTrue(r.ok, r.combined + "\n" + script)
            XCTAssertTrue(script.contains("WINEDLLPATH_DXVK"))
            XCTAssertTrue(script.contains(#"'-name x'"#))
            XCTAssertEqual(script.contains("hdiutil attach -readonly"), disc)
        }
    }

    func testPathsAndArguments() {
        XCTAssertEqual(CustomGames.driveCRelative(windowsPath: #"C:\Games\A\a.exe"#), "Games/A/a.exe")
        XCTAssertNil(CustomGames.driveCRelative(windowsPath: #"D:\setup.exe"#))
        let prefix = URL(fileURLWithPath: "/tmp/p")
        XCTAssertEqual(CustomGames.windowsPath(forUnix: URL(fileURLWithPath: "/tmp/p/drive_c/Games/A/a.exe"), prefix: prefix), #"C:\Games\A\a.exe"#)
        XCTAssertEqual(CustomGames.splitArguments(#"-a "b c" 'd'"#), ["-a", "b c", "d"])
        XCTAssertEqual(CustomGames.safeFolderName("Half-Life: Source?"), "Half-Life Source")
        XCTAssertEqual(config(disc: false).recipe.gameDirectory, "SharedSupport/prefix/drive_c/Games/Test's Game/bin")
    }

    func testGraphicsSuggestion() {
        XCTAssertEqual(GraphicsPreset.suggest(for: PEInfo(is64Bit: false, imports: ["KERNEL32.dll", "d3d9.dll"])), .classic3D)
        XCTAssertEqual(GraphicsPreset.suggest(for: PEInfo(is64Bit: true, imports: ["D3D12.dll"])), .appleMetal)
        XCTAssertEqual(GraphicsPreset.suggest(for: PEInfo(is64Bit: false, imports: ["d3d11.dll"])), .modern3D)
        XCTAssertEqual(GraphicsPreset.suggest(for: PEInfo(is64Bit: false, imports: ["DDRAW.dll"])), .classic2D)
    }

    func testPEOnRealWindowsExe() throws {
        // Any Windows exe from an installed Wine prefix on this Mac (skipped elsewhere).
        let candidates = ["Applications/Sikarugir/Generals Zero Hour (Nokcandu).app/Contents/SharedSupport/GameFiles/Generals.exe",
                          "Applications/Sikarugir/Worms Armageddon.app/Contents/SharedSupport/prefix/drive_c/Games/Worms Armageddon/WA.exe"]
            .map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }
        guard let exe = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("no sample exe") }
        let info = try XCTUnwrap(PEFile.inspect(exe))
        XCTAssertFalse(info.is64Bit)
        XCTAssertFalse(info.imports.isEmpty)
        let ico = try XCTUnwrap(PEFile.largestIcon(exe))
        XCTAssertEqual(Array(ico.prefix(4)), [0, 0, 1, 0])
    }
}

final class FreeAppNameTests: XCTestCase {
    func testNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("freeapp-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        XCTAssertEqual(try CustomGames.freeAppURL("StarCraft", in: dir).lastPathComponent, "StarCraft.app")
        try fm.createDirectory(at: dir.appendingPathComponent("StarCraft.app/Contents"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try CustomGames.freeAppURL("StarCraft", in: dir))          // unfinished leftover
        try Data().write(to: dir.appendingPathComponent("StarCraft.app/Contents/Info.plist"))
        XCTAssertEqual(try CustomGames.freeAppURL("StarCraft", in: dir).lastPathComponent, "StarCraft (2).app")
        XCTAssertEqual(CustomGames.safeFolderName("Counter-Strike: Source"), "Counter-Strike Source")
    }
}

final class GameDisplayTests: XCTestCase {
    func testPatternAndLaunchers() throws {
        XCTAssertEqual(GameDisplay.watchPattern(exeName: "War3.exe"), #"[w]ar3\.exe"#)
        var c = CustomGameConfig(id: "t", name: "T", source: .folder, exe: #"C:\Games\T\war3.exe"#, graphics: .classic3D)
        c.displayPixels = [2560, 1600]
        let s = CustomGames.launcherScript(for: c)
        XCTAssertTrue(s.contains("--play 2560 1600 --watch '[w]ar3\\.exe'"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gd-\(UUID().uuidString).sh")
        try s.write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", tmp.path]).ok)
        let st = SharedSteam.gameLauncherScript(appID: 730, name: "CS2", graphics: .appleMetal, steamApp: URL(fileURLWithPath: "/tmp/Steam.app"),
                                                arguments: ["+engine_low_latency_sleep_after_client_tick", "true"], displayPixels: [2560, 1600])
        try st.write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", tmp.path]).ok)
        XCTAssertTrue(st.contains(#"--watch 'steamapps[\\/]common'"#))
        // The tool's regex must find a real Windows path — and not the tool's own command line.
        let re = try NSRegularExpression(pattern: GameDisplay.steamGamePattern, options: .caseInsensitive)
        func hit(_ t: String) -> Bool { re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
        XCTAssertTrue(hit(#"D:\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\bin\win64\cs2.exe"#))
        XCTAssertFalse(hit("screen-size --play 2560 1600 --watch " + GameDisplay.steamGamePattern))
        let w3 = try NSRegularExpression(pattern: GameDisplay.watchPattern(exeName: "war3.exe"), options: .caseInsensitive)
        let t = #"C:\Games\W3\War3.exe -opengl"#
        XCTAssertNotNil(w3.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)))
        XCTAssertTrue(st.contains("mat_vsync"))
    }
    func testRetinaToggle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[Software\\\\Wine\\\\Fonts] 1\n\"LogPixels\"=dword:00000060\n\n[Software\\\\Wine\\\\Mac Driver] 2\n#time=1\n\"AllowSetGamma\"=dword:00000000\n"
            .write(to: dir.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        try GameDisplay.setRetina(true, prefix: dir)
        XCTAssertTrue(GameDisplay.retinaOn(prefix: dir))
        let u = try String(contentsOf: dir.appendingPathComponent("user.reg"), encoding: .utf8)
        XCTAssertTrue(u.contains("#time=1\n\"RetinaMode\"=\"y\"\n"), u)
        XCTAssertTrue(u.contains("dword:000000c0"))
        try GameDisplay.setRetina(false, prefix: dir)
        XCTAssertFalse(GameDisplay.retinaOn(prefix: dir))
    }
}
