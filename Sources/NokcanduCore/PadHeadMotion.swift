import Foundation

/// Incremental attitude transform with wrap handling, smoothing and fractional deltas.
public struct PadHeadMotion {
    private var previous: (Double, Double)?
    private var rest = (0.0, 0.0)
    private var filtered = (0.0, 0.0)
    public init() {}
    public mutating func recenter() { previous = nil; rest = (0, 0); filtered = (0, 0) }
    public mutating func sample(yaw: Double, pitch: Double, sensitivity: Double, deadZone: Double, smoothing: Double, active: Bool = true) -> (Int, Int) {
        guard active else { recenter(); return (0, 0) }
        guard yaw.isFinite, pitch.isFinite, sensitivity.isFinite, sensitivity >= 0 else { recenter(); return (0, 0) }
        defer { previous = (yaw, pitch) }
        guard let prior = previous else { return (0, 0) }
        func wrapped(_ x: Double) -> Double { atan2(sin(x), cos(x)) }
        let x = wrapped(yaw - prior.0), y = wrapped(pitch - prior.1)
        // Tracking reconnects/recenters must not fling the pointer.
        guard abs(x) < .pi / 4, abs(y) < .pi / 4 else { filtered = (0, 0); rest = (0, 0); return (0, 0) }
        let alpha = min(1, max(0.01, smoothing))
        filtered.0 += alpha * ((abs(x) < deadZone ? 0 : x) - filtered.0)
        filtered.1 += alpha * ((abs(y) < deadZone ? 0 : y) - filtered.1)
        rest.0 += -filtered.0 * min(10000, sensitivity); rest.1 += -filtered.1 * min(10000, sensitivity)
        let dx = Int(rest.0), dy = Int(rest.1); rest.0 -= Double(dx); rest.1 -= Double(dy)
        return (dx, dy)
    }
}
