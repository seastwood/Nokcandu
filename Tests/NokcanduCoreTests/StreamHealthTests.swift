import XCTest
@testable import NokcanduCore

final class StreamHealthTests: XCTestCase {
    private func samples(_ n: Int, _ edit: (Int, inout StreamTelemetry.Sample) -> Void = { _, _ in }) -> [StreamTelemetry.Sample] {
        (0..<n).map { i in
            var s = StreamTelemetry.Sample(); s.time = Double(i); s.duration = 1; s.receivedFPS = 120
            s.arrivalGapMaxMs = 12; s.decodeMaxMs = 4; s.hostMaxMs = 6; s.networkVariationMs = 2
            edit(i, &s); return s
        }
    }
    func testSmoothNetworkStallsMacAndHost() {
        XCTAssertNil(StreamHealth.verdict(samples(60)))
        XCTAssertNil(StreamHealth.verdict(samples(5)), "too little to say")
        let lan = StreamHealth.verdict(samples(60) { i, s in if i % 8 == 0 { s.arrivalGapMaxMs = 90; s.networkVariationMs = 30 } })
        XCTAssertEqual(lan?.title, "The network stalled"); XCTAssertTrue(lan?.detail.contains("up to 90 ms") ?? false)
        XCTAssertEqual(StreamHealth.verdict(samples(60) { i, s in if i % 5 == 0 { s.decodeMaxMs = 40; s.arrivalGapMaxMs = 60 } })?.title, "This Mac fell behind")
        XCTAssertEqual(StreamHealth.verdict(samples(60) { i, s in if i % 5 == 0 { s.hostMaxMs = 50; s.arrivalGapMaxMs = 60 } })?.title, "The host fell behind")
    }
}
