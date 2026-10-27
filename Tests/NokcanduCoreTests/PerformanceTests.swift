import XCTest
@testable import NokcanduCore

final class PerformanceTests: XCTestCase {
    func testPerfEnvComposesWithGraphicsMode() throws {
        var s = Performance.Settings(); s.fpsCounter = true; s.vsync = true; s.fpsLimit = 60
        let env = Performance.envText(s)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("perf.env"); try Data(env.utf8).write(to: f)
        let script = #"set -euo pipefail; export DXVK_CONFIG="d3d9.maxFrameLatency = 1"; . "$1"; echo "$DXVK_CONFIG|${DXVK_HUD:-}|${DXVK_FRAME_RATE:-}|${MTL_HUD_ENABLED:-}""#
        let r = try Shell.run("/bin/bash", ["-c", script, "x", f.path])
        XCTAssertTrue(r.ok, r.combined)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "d3d9.maxFrameLatency = 1; d3d9.presentInterval = 1; dxgi.syncInterval = 1|fps,frametimes,scale=0.6|60|")
        let metal = try Shell.run("/bin/bash", ["-c", #"set -u; export WINEDLLPATH_D3DMETAL=x; . "$1"; echo "${MTL_HUD_ENABLED:-}|${DXVK_HUD:-}""#, "x", f.path])
        XCTAssertEqual(metal.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1|")
        XCTAssertTrue(Performance.Settings().isDefault)
    }

    func testLogFilterDropsFloodAndKeepsStatus() throws {
        let input = String(repeating: "msync: warn: node memory pool exhausted\n", count: 1000) + "hello\nnokcandu: game exited with status 0\n"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inF = dir.appendingPathComponent("in.txt"); try Data(input.utf8).write(to: inF)
        let r = try Shell.run("/bin/bash", ["-c", "\(CustomGames.logFilter) < \"$1\"", "x", inF.path])
        XCTAssertEqual(r.stdout, "hello\nnokcandu: game exited with status 0\n")
    }
}

final class HudStyleTests: XCTestCase {
    func testCompactHud() throws {
        var s = Performance.Settings(); s.fpsCounter = true; s.hud = "fps"
        let env = Performance.envText(s)
        XCTAssertTrue(env.contains(#"MTL_HUD_ELEMENTS="fps""#))
        XCTAssertTrue(env.contains(#"DXVK_HUD="fps,scale=0.6""#))
        XCTAssertTrue(env.contains("MTL_HUD_SCALE=0.1"))
        let r = try Shell.run("/bin/bash", ["-n", "-c", env]); XCTAssertTrue(r.ok, r.combined)
        s.hud = "full"
        XCTAssertFalse(Performance.envText(s).contains("MTL_HUD_ELEMENTS"))
    }
}

final class AudioBufferTests: XCTestCase {
    func testFindsPeriodImmediates() {
        // mov qword ptr [rcx], 100000 ; mov qword ptr [rax], 50000 (twice, like the real driver)
        let chunk: [UInt8] = [0x48, 0xC7, 0x01, 0xA0, 0x86, 0x01, 0x00, 0x90, 0x48, 0xC7, 0x00, 0x50, 0xC3, 0x00, 0x00]
        let d = Data(chunk + [0xC3] + chunk)
        XCTAssertEqual(AudioBuffer.immediates(d, value: 100_000), [3, 19])
        XCTAssertEqual(AudioBuffer.immediates(d, value: 50_000).count, 2)
    }

    func testLowLatencyMode() {
        var s = Performance.Settings()
        XCTAssertFalse(Performance.envText(s).contains("maxFrameLatency"))
        s.lowLatency = true
        s.vsync = true
        let env = Performance.envText(s)
        XCTAssertTrue(env.contains("dxgi.maxFrameLatency = 1; d3d9.maxFrameLatency = 1"))
        XCTAssertTrue(env.contains("presentInterval = 1"))          // both DXVK settings kept
        XCTAssertFalse(s.isDefault)
        // Old perf.json files (no field) still decode.
        let old = try! JSONDecoder().decode(Performance.Settings.self, from: Data(#"{"fpsCounter":true,"vsync":false,"fpsLimit":0}"#.utf8))
        XCTAssertNil(old.lowLatency)
    }

    func testFrameLimitAlsoForDXMT() {
        var s = Performance.Settings(); s.fpsLimit = 60
        let env = Performance.envText(s)
        XCTAssertTrue(env.contains("export DXVK_FRAME_RATE=60"))
        XCTAssertTrue(env.contains(#"export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}d3d11.preferredMaxFrameRate=60""#))
    }
}
