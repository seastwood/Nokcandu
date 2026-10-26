import XCTest
@testable import NokcanduCore

final class LowLatencyTests: XCTestCase {
    func config(_ id: Int, _ args: String) -> CustomGameConfig {
        var c = CustomGameConfig(id: "x", name: "X", source: .steam, steamAppID: id, exe: #"C:\x.exe"#, graphics: .appleMetal)
        c.arguments = args
        return c
    }
    func testCS2() {
        let on = LowLatency.set(true, config(730, "-novid +fps_max 60 -windowed"))
        XCTAssertEqual(on.arguments, "-novid +fps_max 60 -windowed +engine_low_latency_sleep_after_client_tick true")
        XCTAssertTrue(LowLatency.isOn(on))
        XCTAssertEqual(LowLatency.cap(on), 60)
        let capped = LowLatency.setCap(240, on)
        XCTAssertEqual(capped.arguments, "-novid -windowed +engine_low_latency_sleep_after_client_tick true +fps_max 240")
        XCTAssertEqual(LowLatency.cap(LowLatency.setCap(nil, capped)), nil)
        XCTAssertEqual(LowLatency.set(false, capped).arguments, "-novid -windowed +fps_max 240")
        XCTAssertFalse(LowLatency.isOn(LowLatency.set(false, capped)))
        XCTAssertEqual(LowLatency.autoFPS(refresh: 60), 120)
        XCTAssertEqual(LowLatency.autoFPS(refresh: 120), 240)
    }
    func testSource1AndUnsupported() {
        XCTAssertEqual(LowLatency.set(true, config(240, "")).arguments, "+mat_vsync 0")
        XCTAssertEqual(LowLatency.set(true, config(12345, "-a")).arguments, "-a")
        XCTAssertFalse(LowLatency.supported(config(12345, "")))
    }
}
