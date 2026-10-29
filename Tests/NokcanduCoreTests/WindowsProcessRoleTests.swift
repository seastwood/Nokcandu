import XCTest
@testable import NokcanduCore

final class WindowsProcessRoleTests: XCTestCase {
    func testBackgroundServicesSkipGameHooksButGameProgramsKeepThem() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("nok-process-role-" + UUID().uuidString)
        try NokPaths.ensure(work)
        defer { try? fm.removeItem(at: work) }
        let source = work.appendingPathComponent("test.c"), executable = work.appendingPathComponent("test")
        let header = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/rawmouse")
        try #"""
        #include "windows-process-role.h"
        int main(void) {
            const char *background[] = {"nokcandu-ea-compat.exe", "EAGEP.exe", "C:\\Program Files\\EA\\eagep.EXE", "/wine/EALocalHostSvc.exe",
                "EABackgroundService.exe", "services.exe", "steamservice.exe", "QtWebEngineProcess.exe", NULL};
            const char *foreground[] = {"EADesktop.exe", "BF1942.exe", "DOSBox.exe", "C:\\Games\\A Game\\game.exe",
                "upc.exe", "myEAGEP.exe", "", NULL};
            for (unsigned i=0; background[i]; ++i) if (!nokcandu_background_program(background[i])) return 1;
            for (unsigned i=0; foreground[i]; ++i) if (nokcandu_background_program(foreground[i])) return 2;
            return nokcandu_background_program(NULL) ? 3 : 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiled = try Shell.run("/usr/bin/clang", ["-Wall", "-Werror", "-I", header.path, source.path, "-o", executable.path])
        XCTAssertTrue(compiled.ok, compiled.combined)
        if compiled.ok { XCTAssertTrue(try Shell.run(executable.path, []).ok) }
    }
    func testPerGameInputRoutingUsesExactPathAndUniqueFallback() throws {
        let fm = FileManager.default, work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(work); defer { try? fm.removeItem(at: work) }
        let source = work.appendingPathComponent("test.c"), exe = work.appendingPathComponent("test"), routes = work.appendingPathComponent("routes.tsv")
        try "game.exe\t/fallback/raw-mouse\nC:\\Games\\First\\Game.exe\t/first/raw-mouse\nC:\\Games\\Second\\Game.exe\t/second/raw-mouse\n".write(to: routes, atomically: true, encoding: .utf8)
        let header = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/rawmouse")
        try #"""
        #include "program-input-settings.h"
        int main(int argc,char **argv) {
            (void)argc;char out[4096]="";
            if(!nokcandu_program_input(argv[1],"c:/Games/First/GAME.EXE",out,sizeof out)||strcmp(out,"/first/raw-mouse"))return 1;
            if(!nokcandu_program_input(argv[1],"C:\\Games\\Second\\Game.exe",out,sizeof out)||strcmp(out,"/second/raw-mouse"))return 2;
            if(!nokcandu_program_input(argv[1],"game.exe",out,sizeof out)||strcmp(out,"/fallback/raw-mouse"))return 3;
            if(nokcandu_program_input(argv[1],"unrelated.exe",out,sizeof out))return 4;
            if(nokcandu_program_input(argv[1],"game.exe",out,4))return 5;
            return 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let result = try Shell.run("/usr/bin/clang", ["-Wall", "-Werror", "-I", header.path, source.path, "-o", exe.path])
        XCTAssertTrue(result.ok, result.combined)
        if result.ok { XCTAssertTrue(try Shell.run(exe.path, [routes.path]).ok) }
    }

}
