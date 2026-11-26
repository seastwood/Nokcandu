import Foundation

/// A trackpad that drives a stick the way a mouse drives a pointer: the stick tilts by how fast the finger
/// moves, in the direction it moves, and returns to centre when the finger stops. Optionally a flick keeps
/// the stick tilted after the finger lifts, easing back to centre (inertia). No delay is added: a new
/// reading is reflected on the same report, with only a 20 ms average to steady the pad's own noise.
public struct PadVelocityStick: Sendable {
    /// Finger speed, in pad widths a second, that tilts the stick all the way.
    public static let defaultFullSpeed = 1.5
    /// How quickly the speed reading follows the finger (seconds).
    static let response = 0.02
    public static let responseMS = 20.0
    private var lastX = 0.0, lastY = 0.0
    private var lastReport: Double?, lastTick: Double?
    private var touching = false, coasting = false
    /// Finger speed in pad widths a second, y up.
    private(set) var vx = 0.0, vy = 0.0
    public init() {}
    public mutating func reset() { self = Self() }
    public var isActive: Bool { touching || coasting }

    /// A report: pad position -1…1 (y up), as the controller gives it.
    public mutating func touch(down: Bool, x: Double, y: Double, at now: Double, settings: PadSteamTrackpadSettings) {
        guard now.isFinite, x.isFinite, y.isFinite else { reset(); return }
        let p = settings.rotatedPosition(x: x, y: y)
        guard down else {
            if touching {
                touching = false
                coasting = settings.velocityInertia == true && (vx != 0 || vy != 0)
                if !coasting { vx = 0; vy = 0 }
            }
            return
        }
        guard touching else {
            // A new touch starts still: where the finger lands never moves the stick, and it stops a coast.
            touching = true; coasting = false; vx = 0; vy = 0
            lastX = p.x; lastY = p.y; lastReport = now
            return
        }
        let dt = now - (lastReport ?? now)
        guard dt > 0.0005 else { return }
        let step = min(dt, 0.05)
        // The pad is 2 units across: half the change is in pad widths.
        let ix = (p.x - lastX) / 2 / step, iy = (p.y - lastY) / 2 / step
        let a = 1 - exp(-step / Self.response(settings))
        vx += (ix - vx) * a; vy += (iy - vy) * a
        lastX = p.x; lastY = p.y; lastReport = now
    }

    /// On the 4 ms timer: a resting finger (no new reading) returns the stick to centre; a coast eases off.
    /// Returns true when the output changed.
    public mutating func tick(at now: Double, settings: PadSteamTrackpadSettings) -> Bool {
        guard now.isFinite else { reset(); return false }
        defer { lastTick = now }
        guard let previous = lastTick, now > previous, vx != 0 || vy != 0 else { return false }
        let dt = min(now - previous, 0.1)
        if touching {
            guard let r = lastReport, now - r > 0.012 else { return false }
            let a = exp(-dt / Self.returnTime(settings)); vx *= a; vy *= a
        } else if coasting {
            let h = settings.halfLife.isFinite ? min(1, max(0.02, settings.halfLife)) : 0.16
            let a = pow(0.5, dt / h); vx *= a; vy *= a
        } else { return false }
        if hypot(vx, vy) < 0.01 * Self.fullSpeed(settings) { vx = 0; vy = 0; coasting = false }
        return true
    }

    static func response(_ s: PadSteamTrackpadSettings) -> Double {
        guard let ms = s.velocityResponseMS, ms.isFinite else { return response }
        return min(0.2, max(0.002, ms / 1000))
    }
    static func returnTime(_ s: PadSteamTrackpadSettings) -> Double {
        guard let ms = s.velocityReturnMS, ms.isFinite else { return response }
        return min(0.5, max(0.005, ms / 1000))
    }

    public static func fullSpeed(_ s: PadSteamTrackpadSettings) -> Double {
        guard let v = s.velocityFullSpeed, v.isFinite else { return defaultFullSpeed }
        return min(10, max(0.1, v))
    }

    /// The stick, -1…1 each way (y up).
    public func vector(_ settings: PadSteamTrackpadSettings) -> (x: Double, y: Double) {
        let full = Self.fullSpeed(settings)
        var x = vx / full * (settings.velocityXScale ?? 1), y = vy / full * (settings.velocityYScale ?? 1)
        var m = hypot(x, y)
        if m < 0.02 { return (0, 0) }
        if m > 1 { x /= m; y /= m; m = 1 }
        // The curve shapes the tilt (direction kept); the least tilt lifts any movement past a game's dead zone.
        let curve = min(4, max(0.25, settings.velocityCurve ?? 1)), least = min(0.6, max(0, settings.velocityMinimum ?? 0))
        let shaped = least + (1 - least) * pow(m, curve)
        x = x / m * shaped; y = y / m * shaped
        if settings.invertY { y = -y }
        return (x, y)
    }

    /// Puts the pad's stick into the engine's axes (SDL order, y down): the left pad drives the left stick,
    /// the right pad the right stick. A real stick pushed further still wins.
    public static func apply(_ v: (x: Double, y: Double), side: Int, to axes: inout [Int: Int], state: SteamControllerReport.State) {
        let real: SteamControllerReport.Point = side == 0 ? state.stick : (state.kind == .original ? .init() : state.rightStick)
        guard v.x * v.x + v.y * v.y > Double(real.x * real.x + real.y * real.y) else { return }
        func axis(_ f: Double) -> Int { Int(max(-32768, min(32767, f * 32767))) }
        axes[side == 0 ? 0 : 2] = axis(v.x); axes[side == 0 ? 1 : 3] = axis(-v.y)
    }
}
