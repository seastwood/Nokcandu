import XCTest
import NokcanduCore

final class ControllerReportStatisticsTests: XCTestCase {
    func testDeviceCadenceIsMeasuredAcrossRingWrapAndIdle() throws {
        for hz in [125.0, 250, 1000, 8000] {
            var stats = ControllerReportStatistics()
            for i in 0..<1000 { stats.record(at: 10 + Double(i) / hz) }
            let now = 10 + 999 / hz
            XCTAssertEqual(try XCTUnwrap(stats.rateHz(at: now)), hz, accuracy: 0.00001)
            XCTAssertEqual(stats.maximumGap, 1 / hz, accuracy: 0.00001)
            XCTAssertEqual(stats.count, 1000)
            XCTAssertEqual(stats.rateHz(at: now + 1.01), 0)
            XCTAssertNil(stats.rateHz(at: .nan))
        }
    }
    func testGapsAreVisibleAndInvalidTimesDoNotCorruptRate() throws {
        var stats = ControllerReportStatistics()
        stats.record(at: 1)
        XCTAssertNil(stats.rateHz(at: 1))
        stats.record(at: 1.008); stats.record(at: 1.5)
        for t in [Double.nan, .infinity, 0, 1.5] { stats.record(at: t) }
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.maximumGap, 0.492, accuracy: 0.00001)
        XCTAssertEqual(stats.rateHz(at: 1.5), 4)
    }
    func testDiagnosticsAreOptInBoundedAndResettable() {
        let diagnostics = ControllerReportDiagnostics()
        diagnostics.record("off", label: "Off", at: 1)
        XCTAssertTrue(diagnostics.snapshot().isEmpty)
        diagnostics.enabled = true
        for i in 0..<40 { diagnostics.record("source\(i)", label: "Reader", at: Double(i)) }
        XCTAssertEqual(diagnostics.snapshot().count, 32)
        XCTAssertFalse(diagnostics.snapshot().contains { $0.source == "source0" })
        diagnostics.reset()
        XCTAssertTrue(diagnostics.snapshot().isEmpty)
        diagnostics.record("new", label: "Reader", at: 1)
        diagnostics.enabled = false
        XCTAssertTrue(diagnostics.snapshot().isEmpty)
    }
    func testConcurrentUSBReadersKeepIndependentCadence() {
        let diagnostics = ControllerReportDiagnostics()
        diagnostics.enabled = true
        DispatchQueue.concurrentPerform(iterations: 8) { reader in
            for i in 0..<1000 {
                diagnostics.record("\(reader)", label: "USB reader", at: 1 + Double(i) / 1000)
            }
        }
        XCTAssertEqual(diagnostics.snapshot().count, 8)
        for row in diagnostics.snapshot() {
            XCTAssertEqual(row.statistics.count, 1000)
            XCTAssertEqual(row.statistics.rateHz(at: 1.999) ?? 0, 1000, accuracy: 0.00001)
        }
    }
}
