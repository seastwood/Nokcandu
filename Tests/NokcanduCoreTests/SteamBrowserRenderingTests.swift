import XCTest
@testable import NokcanduCore

final class SteamBrowserRenderingTests: XCTestCase {
    func testBrowserSelectionDoesNotChangeGamesOrUnrelatedHelpers() throws {
        let fm = FileManager.default, work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try NokPaths.ensure(work); defer { try? fm.removeItem(at: work) }
        let source = work.appendingPathComponent("test.c"), exe = work.appendingPathComponent("test")
        let header = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/rawmouse")
        try #"""
        #include "browser-renderer.h"
        int main(void) {
            unsetenv("NOKCANDU_BROWSER_DXMT_ROOT");
            setenv("WINEDLLPATH_DXVK", "game-renderer", 1);
            setenv("WINEDLLOVERRIDES", "d3d8,d3d9=b;binkw32=n,b", 1);
            if (nokcandu_configure_browser_renderer("steamwebhelper.exe")) return 1;
            setenv("NOKCANDU_BROWSER_DXMT_ROOT", "/tmp", 1);
            const char *other[] = {NULL, "", "steam.exe", "game.exe", "mysteamwebhelper.exe", "steamwebhelper.exe.bak", "EACefSubProcess.exe"};
            for (unsigned i=0; i<sizeof(other)/sizeof(other[0]); ++i)
                if (nokcandu_configure_browser_renderer(other[i])) return 2;
            if (strcmp(getenv("WINEDLLPATH_DXVK"), "game-renderer")) return 3;
            if (strcmp(getenv("WINEDLLOVERRIDES"), "d3d8,d3d9=b;binkw32=n,b")) return 4;
            if (!nokcandu_configure_browser_renderer("C:\\Steam\\STEAMWEBHELPER.EXE")) return 5;
            if (getenv("WINEDLLPATH_DXVK")) return 6;
            if (strcmp(getenv("WINEDLLPATH_DXMT"), "/tmp")) return 7;
            if (strcmp(getenv("WINEDLLOVERRIDES"), "d3d8,d3d9=b;binkw32=n,b;dxgi,d3d10core,d3d11,winemetal=b")) return 8;
            setenv("NOKCANDU_BROWSER_DXMT_ROOT", "/no-such-nokcandu-renderer", 1);
            if (nokcandu_configure_browser_renderer("steamwebhelper.exe")) return 9;
            return 0;
        }
        """#.write(to: source, atomically: true, encoding: .utf8)
        let compiled = try Shell.run("/usr/bin/clang", ["-Wall", "-Werror", "-I", header.path, source.path, "-o", exe.path])
        XCTAssertTrue(compiled.ok, compiled.combined)
        if compiled.ok { XCTAssertTrue(try Shell.run(exe.path, []).ok) }
    }

    func testDrawingDefaultTracksEngineAndPreservesExplicitChoices() throws {
        let fm = FileManager.default, h = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: h) }
        let wine = h.appendingPathComponent("SharedSupport/wine")
        let renderer = h.appendingPathComponent("SharedSupport/renderer/dxmt/wine/x86_64-windows")
        let state = h.appendingPathComponent("SharedSupport/nokcandu")
        for d in [wine, renderer, state] { try NokPaths.ensure(d) }
        try Data().write(to: renderer.appendingPathComponent("d3d11.dll"))
        try Data().write(to: state.appendingPathComponent("nokcandu-rawmouse.dylib"))
        try "wine sikarugir 10.0 (revision 8)".write(to: wine.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        XCTAssertFalse(SharedSteam.gpuDrawing(contents: h))
        try "wine sikarugir 11.0 (revision 1)".write(to: wine.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SharedSteam.gpuDrawing(contents: h))
        try Data().write(to: state.appendingPathComponent("steam-software"))
        XCTAssertFalse(SharedSteam.gpuDrawing(contents: h))
        try Data().write(to: state.appendingPathComponent("steam-gpu"))
        XCTAssertTrue(SharedSteam.gpuDrawing(contents: h))
        try fm.removeItem(at: state.appendingPathComponent("steam-gpu"))
        try fm.removeItem(at: state.appendingPathComponent("steam-software"))
        try fm.removeItem(at: renderer.appendingPathComponent("d3d11.dll"))
        XCTAssertFalse(SharedSteam.gpuDrawing(contents: h))
    }

    func testGeneratedHelperSyntaxAndRestartIdentityIncludeBrowserPolicy() throws {
        let fm = FileManager.default, script = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: script) }
        let text = SharedSteam.helperScript()
        try text.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run("/bin/bash", ["-n", script.path]).ok)
        XCTAssertTrue(text.contains("browser=$STEAM_METAL_BROWSER gpu=$STEAM_GPU"))
        XCTAssertTrue(text.contains("export DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1"))
        XCTAssertTrue(text.contains("steam-software"))
        XCTAssertTrue(text.contains("/v GPUAccelWebViewsV3 /t REG_DWORD /d \"$STEAM_GPU\" /f"))
    }
}
