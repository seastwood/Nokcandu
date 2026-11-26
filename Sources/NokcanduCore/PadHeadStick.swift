import Foundation

/// Attitude relative to the activation/recenter pose, expressed as a stick.
/// Mouse keeps its separate incremental transform; stick holds persist while turned.
public struct PadHeadStick {
    private var center: (Double,Double)?
    private var filtered = (0.0,0.0)
    private var lastTime: Double?
    public init() {}
    public mutating func recenter() { center = nil; filtered = (0,0); lastTime = nil }
    public mutating func sample(yaw: Double, pitch: Double, range: Double = 0.25,
                                deadZone: Double = 0.001, smoothing: Double = 0.5,
                                active: Bool = true, settleTime: Double = 0, settleBelow: Double = 0,
                                now: Double? = nil) -> (Double,Double) {
        guard active, yaw.isFinite, pitch.isFinite, range.isFinite, range > 0,
              deadZone.isFinite, smoothing.isFinite else { recenter(); return (0,0) }
        guard let center else { self.center = (yaw,pitch); return (0,0) }
        var x = -atan2(sin(yaw-center.0),cos(yaw-center.0))
        var y = -atan2(sin(pitch-center.1),cos(pitch-center.1))
        // Settling: while the head stays inside `settleBelow` (of the range), the centre slowly follows it, so
        // drift and posture changes fade and only a deliberate turn reaches the edge.
        if settleTime > 0, let now {
            let dt = lastTime.map { min(0.2, max(0, now - $0)) } ?? 0
            lastTime = now
            if (x * x + y * y).squareRoot() < settleBelow * range, dt > 0 {
                let k = 1 - exp(-dt / settleTime)
                self.center = (center.0 - x * k, center.1 - y * k)
                x *= 1 - k; y *= 1 - k
            }
        }
        let alpha = min(1,max(0.05,smoothing))
        func value(_ v: Double) -> Double { abs(v) <= max(0,deadZone) ? 0 : max(-1,min(1,v/range)) }
        filtered.0 += alpha*(value(x)-filtered.0); filtered.1 += alpha*(value(y)-filtered.1)
        // Return exact neutral after returning to center, so mapped holds release promptly.
        if abs(x) <= max(0,deadZone) { filtered.0 = 0 }; if abs(y) <= max(0,deadZone) { filtered.1 = 0 }
        return filtered
    }
}
