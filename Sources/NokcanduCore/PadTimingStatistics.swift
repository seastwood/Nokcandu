/// Bounded, aggregate-only diagnostics. Measures local processing, not hardware-to-screen latency.
public struct PadTimingStatistics {
    public private(set) var count = 0
    public private(set) var totalSeconds = 0.0
    public private(set) var maximumSeconds = 0.0
    public private(set) var overBudgetCount = 0
    public let budgetSeconds: Double
    public init(budgetSeconds: Double = 0.004) { self.budgetSeconds = budgetSeconds }
    public var meanSeconds: Double { count == 0 ? 0 : totalSeconds / Double(count) }
    public mutating func record(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        count += 1; totalSeconds += seconds
        maximumSeconds = max(maximumSeconds, seconds)
        if seconds > budgetSeconds { overBudgetCount += 1 }
    }
}
