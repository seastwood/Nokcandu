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
        XCTAssertEqual(CustomGames.safeFolderName("Half-Life: Source?"), "Half-Life  Source")
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
