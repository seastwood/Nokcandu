import XCTest
import NokcanduCore

final class PadTimingStatisticsTests: XCTestCase {
    func testAggregatesWithoutRetainingPerEventData() {
        var stats = PadTimingStatistics(budgetSeconds: 0.004)
        XCTAssertEqual(stats.meanSeconds, 0)
        for value in [0.001, 0.004, 0.010] { stats.record(seconds: value) }
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.meanSeconds, 0.005, accuracy: 0.000001)
        XCTAssertEqual(stats.maximumSeconds, 0.010)
        XCTAssertEqual(stats.overBudgetCount, 1)
    }
    func testInvalidClockDifferencesDoNotPolluteStatistics() {
        var stats = PadTimingStatistics()
        for value in [-1.0, Double.infinity, Double.nan, -Double.infinity] { stats.record(seconds: value) }
        XCTAssertEqual(stats.count, 0)
        stats.record(seconds: 0)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.meanSeconds, 0)
        XCTAssertEqual(stats.overBudgetCount, 0)
    }
}
