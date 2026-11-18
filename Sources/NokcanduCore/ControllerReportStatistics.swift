import Foundation

/// Callback cadence, not a claim about a device's configured USB/Bluetooth polling rate.
public struct ControllerReportStatistics {
    private var times: [Double] = []
    private var next = 0
    public private(set) var count = 0
    public private(set) var maximumGap = 0.0
    public private(set) var last: Double?
    public init() {}
    public mutating func record(at time: Double) {
        guard time.isFinite else { return }
        if let last {
            guard time > last else { return }
            maximumGap = max(maximumGap, time - last)
        }
        last = time; count += 1
        if times.count < 256 { times.append(time) }
        else { times[next] = time; next = (next + 1) % 256 }
    }
    public func rateHz(at time: Double) -> Double? {
        guard time.isFinite, let last, time >= last else { return nil }
        if time - last > 1 { return 0 }
        guard times.count > 1 else { return nil }
        let first = times.count == 256 ? times[next] : times[0]
        return Double(times.count - 1) / (last - first)
    }
}

/// Opt-in, bounded aggregate measurements shared by HID callbacks, USB read threads and GameController.
/// No raw input or device identifiers are persisted.
public final class ControllerReportDiagnostics: @unchecked Sendable {
    public static let shared = ControllerReportDiagnostics()
    private let lock = NSLock()
    private var on = false
    private var rows: [String: Row] = [:]
    public struct Row {
        public let source: String
        public let label: String
        public var statistics = ControllerReportStatistics()
    }
    public init() {}
    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); defer { lock.unlock() }; on = newValue; rows = [:] }
    }
    public func reset() { lock.lock(); defer { lock.unlock() }; rows = [:] }
    public func record(_ source: String, label: @autoclosure () -> String, at time: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard on else { return }
        if rows[source] == nil {
            if rows.count >= 32, let oldest = rows.min(by: { ($0.value.statistics.last ?? 0) < ($1.value.statistics.last ?? 0) })?.key {
                rows.removeValue(forKey: oldest)
            }
            rows[source] = Row(source: source, label: label())
        }
        rows[source]?.statistics.record(at: time)
    }
    public func snapshot() -> [Row] {
        lock.lock(); defer { lock.unlock() }
        return rows.values.sorted { $0.source < $1.source }
    }
}
