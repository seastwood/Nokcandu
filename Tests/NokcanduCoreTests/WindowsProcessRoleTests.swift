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
            const char *background[] = {"EAGEP.exe", "C:\\Program Files\\EA\\eagep.EXE", "/wine/EALocalHostSvc.exe",
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
}
