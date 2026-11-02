import XCTest
@testable import NokcanduCore

final class GameMicrophoneTests: XCTestCase {
    func testPolicyPrecedesSetupAndOverridesInheritedFlagsForBothStates() throws {
        var game = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let bin = game.support.appendingPathComponent("wine/bin")
        try NokPaths.ensure(bin)
        let trace = game.support.appendingPathComponent("microphone-calls.txt")
        let fake = "#!/bin/bash\nprintf '%s|%s\\n' \"${1:-}\" \"${NOKCANDU_NO_MICROPHONE-unset}\" >> " + CustomGames.shellQuote(trace.path) + "\nexit 0\n"
        let wine = bin.appendingPathComponent("wine")
        try fake.write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try Data("fixture".utf8).write(to: game.nokcanduState.appendingPathComponent(RawMouse.dylibName))
        for allowed in [false, true] {
            try? FileManager.default.removeItem(at: trace)
            try? FileManager.default.removeItem(at: game.nokcanduState.appendingPathComponent("registry-env"))
            var config = game.custom!; config.microphone = allowed
            config.environment = [GameMicrophone.variable: allowed ? "1" : "0"]
            // This test executes a shell fixture, not Wine. Do not ask dyld to load the
            // deliberately non-library helper marker into its Bash interpreter. The native
            // audio boundary is exercised independently in the compiled guard test below.
            let script = HelperPatch.scopeWineLibrary(CustomGames.launcherScript(for: config))
                .replacingOccurrences(of: "DYLD_INSERT_LIBRARIES", with: "NOK_TEST_INJECTION")
            let file = game.contents.appendingPathComponent("MacOS/game-launcher")
            try script.write(to: file, atomically: true, encoding: .utf8)
            var inherited = ProcessInfo.processInfo.environment
            inherited[GameMicrophone.variable] = allowed ? "1" : "0"
            inherited["TMPDIR"] = FileManager.default.temporaryDirectory.path
            let result = try Shell.run("/bin/bash", [file.path], env: inherited, timeout: 10)
            let launchLog = (try? String(contentsOf: game.support.appendingPathComponent("Logs/launch.log"), encoding: .utf8)) ?? ""
            XCTAssertTrue(result.ok, result.combined + launchLog)
            let calls = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertTrue(calls.contains(where: { $0.hasPrefix("regedit|") }), calls.description)
            XCTAssertGreaterThanOrEqual(calls.count, 2)
            XCTAssertTrue(calls.allSatisfy { $0.hasSuffix(allowed ? "|0" : "|1") }, calls.description)
            config.launcherSHA = Hashing.sha256(data: Data(script.utf8))
            try config.encoded().write(to: CustomGameConfig.url(in: game.contents))
            game = GameLibrary.inspect(game.appURL)!
            let env = WineTools.environment(contents: game.contents)
            XCTAssertEqual(env[GameMicrophone.variable], allowed ? "0" : "1")
            XCTAssertEqual(env["DYLD_INSERT_LIBRARIES"], game.nokcanduState.appendingPathComponent(RawMouse.dylibName).path)
        }
    }
    func testSharedSteamPolicyPersistsWithPerGameRendererSettings() throws {
        var game = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        game.custom!.source = .steamLibrary
        game.custom!.steamAppID = 123
        game.custom!.microphone = true
        try ProgramSettings.update(launcher: game.contents, key: "steam:123", graphics: .classic3D, game: game)
        game.custom!.microphone = nil
        try ProgramSettings.update(launcher: game.contents, key: "steam:456", graphics: .compatible, game: game)
        let text = try String(contentsOf: ProgramSettings.file(game.contents), encoding: .utf8)
        XCTAssertTrue(text.split(separator: "\n").contains { $0.hasPrefix("steam:123\t") && $0.contains("NOKCANDU_NO_MICROPHONE=0") && $0.contains("WINEDLLPATH_D9VK=") })
        XCTAssertTrue(text.split(separator: "\n").contains { $0.hasPrefix("steam:456\t") && $0.contains("NOKCANDU_NO_MICROPHONE=1") })
        XCTAssertTrue(SharedSteam.helperScript().contains(GameMicrophone.launcherExports(allowed: false)))
    }
    func testSteamClientHasSeparateExplicitOptIn() throws {
        var host = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: host.appURL) }
        try FileManager.default.removeItem(at: CustomGameConfig.url(in: host.contents))
        host.custom = nil; host.recipe = SharedSteam.hostRecipe(wineVersion: nil)
        try Data("{}".utf8).write(to: host.nokcanduState.appendingPathComponent(SharedSteam.hostMarker))
        XCTAssertTrue(GameMicrophone.supported(host)); XCTAssertFalse(GameMicrophone.isOn(host))
        try GameMicrophone.set(true, for: host)
        XCTAssertTrue(GameMicrophone.isOn(host))
        XCTAssertEqual(WineTools.environment(contents: host.contents)[GameMicrophone.variable], "0")
        try GameMicrophone.set(false, for: host)
        XCTAssertFalse(GameMicrophone.isOn(host))
        XCTAssertEqual(WineTools.environment(contents: host.contents)[GameMicrophone.variable], "1")
    }
    func testPerProgramPolicyIsReadableBeforeConstructorAndDoesNotLeakIntoClient() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mic-routes-" + UUID().uuidString)
        try NokPaths.ensure(work); defer { try? FileManager.default.removeItem(at: work) }
        let table = work.appendingPathComponent("routes.tsv"), source = work.appendingPathComponent("test.c"), binary = work.appendingPathComponent("test")
        try "steam:123\tNOKCANDU_NO_MICROPHONE=0\nsteam:456\tNOKCANDU_NO_MICROPHONE=1\nWar3.exe\tNOKCANDU_NO_MICROPHONE=1\n".write(to: table, atomically: true, encoding: .utf8)
        try #"""
        #include "microphone-policy.h"
        int main(int argc,char**argv){
          (void)argc;
          if(nokcandu_microphone_route(argv[1],"C:\\Games\\Game.exe","123")!=0)return 1;
          if(nokcandu_microphone_route(argv[1],"C:\\Games\\Game.exe","456")!=1)return 2;
          if(nokcandu_microphone_route(argv[1],"STEAM.EXE","123")!=-1)return 3;
          if(nokcandu_microphone_route(argv[1],"c:/Games/WAR3.EXE",NULL)!=1)return 4;
          if(nokcandu_microphone_route(argv[1],"unrelated.exe",NULL)!=-1)return 5;
          return 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let header = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/rawmouse")
        let compile = try Shell.run("/usr/bin/xcrun", ["clang", "-Wall", "-Wextra", "-Werror", "-I", header.path, source.path, "-o", binary.path], timeout: 30)
        XCTAssertTrue(compile.ok, compile.combined)
        XCTAssertTrue(try Shell.run(binary.path, [table.path]).ok)
    }
    func testPrivatePrefixPolicySurvivesMissingChildEnvironment() throws {
        let game = try IPXNetworkingTests().fixture()
        defer { try? FileManager.default.removeItem(at: game.appURL) }
        let bin = game.support.appendingPathComponent("wine/bin")
        try NokPaths.ensure(bin)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("wine"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        try GameMicrophone.refreshPolicies([game])
        XCTAssertEqual(try String(contentsOf: game.nokcanduState.appendingPathComponent(GameMicrophone.policyFile), encoding: .utf8), "1\n")
        var config = game.custom!; config.microphone = true
        try config.encoded().write(to: CustomGameConfig.url(in: game.contents))
        try GameMicrophone.refreshPolicies([game])
        XCTAssertEqual(try String(contentsOf: game.nokcanduState.appendingPathComponent(GameMicrophone.policyFile), encoding: .utf8), "0\n")
    }
    func testAudioBoundaryBlocksCaptureWithoutTouchingHardwareAndKeepsOutput() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mic-guard-" + UUID().uuidString)
        try NokPaths.ensure(work); defer { try? FileManager.default.removeItem(at: work) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let executable = work.appendingPathComponent("test")
        let compile = try Shell.run("/usr/bin/xcrun", ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-Wno-unused-function", "-I", root.appendingPathComponent("Resources/rawmouse").path, root.appendingPathComponent("Tools/audio-guard/test.m").path, "-framework", "AudioToolbox", "-framework", "CoreAudio", "-o", executable.path], timeout: 30)
        XCTAssertTrue(compile.ok, compile.combined)
        for state in ["off", "on", "stripped"] {
            if state == "stripped" { try Data("1\n".utf8).write(to: work.appendingPathComponent("microphone-policy")) }
            let result = try Shell.run(executable.path, [state], timeout: 10)
            XCTAssertTrue(result.ok, result.combined)
            XCTAssertTrue(result.stdout.contains("output preserved, no hardware calls"))
        }
    }
}
