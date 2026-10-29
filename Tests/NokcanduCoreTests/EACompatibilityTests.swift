import XCTest
@testable import NokcanduCore

final class EACompatibilityTests: XCTestCase {
    func testOnlyStandaloneElevationTokenIsRemoved() throws {
        let fm = FileManager.default, work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(work); defer { try? fm.removeItem(at: work) }
        let source = work.appendingPathComponent("test.c"), exe = work.appendingPathComponent("test")
        let header = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/borderless")
        try #"""
        #include "compat-flags.h"
        int main(void) {
            wchar_t out[100];
            if(!remove_admin(L"~ RUNASADMIN WINXPSP3 HIGHDPIAWARE",out,100)||wcscmp(out,L"~ WINXPSP3 HIGHDPIAWARE"))return 1;
            if(!remove_admin(L"runasadmin",out,100)||*out)return 2;
            if(remove_admin(L"WINXPSP3 MYRUNASADMIN",out,100))return 3;
            if(!remove_admin(L"RUNASADMIN\tWIN7RTM  RUNASADMIN",out,100)||wcscmp(out,L"WIN7RTM"))return 4;
            if(remove_admin(L"RUNASADMIN LONGFLAG",out,2))return 5;
            return 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiled = try Shell.run("/usr/bin/clang", ["-Wall", "-Werror", "-I", header.path, source.path, "-o", exe.path])
        XCTAssertTrue(compiled.ok, compiled.combined)
        if compiled.ok { XCTAssertTrue(try Shell.run(exe.path, []).ok) }
    }
    func testFreshEAAndHostedLaunchersIncludeRepairButOtherClientsDoNot() throws {
        let (host, _) = try EASetupRecoveryTests().fixture()
        defer { try? FileManager.default.removeItem(at: host.appURL) }
        let config = try XCTUnwrap(host.custom)
        let client = CustomGames.launcherScript(for: config)
        XCTAssertTrue(client.contains("nokcandu-ea-compat.exe"))
        XCTAssertTrue(client.contains("--watch"))
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", "-c", client]).ok)
        let ea = HostedGameLink(hostApp: host.appURL.path, launcher: .ea, id: "test", name: "Game", exe: #"C:\Games\Game.exe"#)
        let ubisoft = HostedGameLink(hostApp: host.appURL.path, launcher: .ubisoft, id: "test", name: "Game", exe: nil)
        XCTAssertTrue(HostedSettings.script(ea, settings: .init()).contains("nokcandu-ea-compat.exe"))
        XCTAssertFalse(HostedSettings.script(ubisoft, settings: .init()).contains("nokcandu-ea-compat.exe"))
    }
    func testBothRepairModesHaveValidShellAndForegroundCheck() throws {
        for watch in [false, true] {
            let block = EACompatibility.block(watch: watch)
            XCTAssertTrue(block.contains("'C:\\nokcandu\\nokcandu-ea-compat.exe'"))
            XCTAssertEqual(block.contains("--watch"), watch)
            XCTAssertTrue(try Shell.run("/bin/bash", ["-n", "-c", block]).ok)
            let scoped = HelperPatch.scopeWineLibrary(block)
            XCTAssertTrue(scoped.contains(#"DYLD_INSERT_LIBRARIES="${NOKCANDU_HELPER_LIBRARY:-}" "$SUPPORT/wine/bin/wine""#))
        }
    }
}
