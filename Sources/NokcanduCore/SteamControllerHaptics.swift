import Foundation

/// Original Steam Controller's documented short haptic-pulse feature report.
/// Transient output only; never changes controller settings or mappings.
public struct SteamControllerHaptics {
    private var last: [Int: Double] = [:]
    private var distance: [Int: Double] = [:]
    private var sampled: [Int: Double] = [:]
    private var touched: Set<Int> = []
    private var lastTouch: [Int: Double] = [:]
    public init() {}
    public static func pulse(side: Int, strength: Double, spacingMS: Double = 1) -> [UInt8]? {
        guard (0...1).contains(side), strength.isFinite, strength > 0 else { return nil }
        let duration = UInt16(50 + min(1,strength) * 450)
        let interval = UInt16((spacingMS.isFinite ? min(3,max(0.1,spacingMS)) : 1) * 1000)
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x8f; bytes[1] = 7
        bytes[2] = side == 0 ? 1 : 0 // original USB protocol: left=1, right=0
        bytes[3] = UInt8(duration & 255); bytes[4] = UInt8(duration >> 8)
        bytes[5] = UInt8(interval & 255); bytes[6] = UInt8(interval >> 8)
        bytes[7] = 3 // finite burst, at most 10.5 milliseconds including gaps
        return bytes
    }
    /// A rumble: the same pulse report repeated for a short, fixed time on one pad (the controller has no
    /// rumble motor; Steam rumbles it this way too). Light: about 0.15 s, for a layer change; strong: about
    /// 0.4 s, for a test or a "Rumble" button. Finite, like every pulse here.
    public static func rumble(side: Int, strong: Bool) -> [UInt8]? {
        rumble(side: side, strength: strong ? 1 : 0.6, seconds: strong ? 0.4 : 0.15)
    }
    /// A rumble of a chosen strength (0…1, how long the pad is driven in each pulse) and length (seconds,
    /// at most one). Pulses repeat every 6 ms, a steady buzz rather than separate clicks.
    public static func rumble(side: Int, strength: Double, seconds: Double) -> [UInt8]? {
        guard (0...1).contains(side), strength.isFinite, seconds.isFinite, strength > 0, seconds > 0 else { return nil }
        let level = min(1, strength), period = 6000.0
        let on = UInt16(200 + level * 2800), off = UInt16(max(200, period - Double(on)))
        let count = UInt16(max(1, min(1, seconds) * 1_000_000 / Double(Int(on) + Int(off))))
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x8f; bytes[1] = 7
        bytes[2] = side == 0 ? 1 : 0
        bytes[3] = UInt8(on & 255); bytes[4] = UInt8(on >> 8)
        bytes[5] = UInt8(off & 255); bytes[6] = UInt8(off >> 8)
        bytes[7] = UInt8(count & 255); bytes[8] = UInt8(count >> 8)
        return bytes
    }
    /// One finite pulse per new contact, independent of motion and coast.
    /// Remember disabled contacts too: enabling feedback while held is not a touch.
    public mutating func touch(side: Int, down: Bool, strength: Double, at now: Double) -> [UInt8]? {
        guard (0...1).contains(side), now.isFinite else { return nil }
        let wasDown = touched.contains(side)
        if down { touched.insert(side) } else { touched.remove(side) }
        guard down, !wasDown, let bytes = Self.pulse(side: side, strength: strength) else { return nil }
        if let prior = lastTouch[side], now >= prior, now - prior < 0.025 { return nil }
        lastTouch[side] = now
        last[side] = now // avoid an overlapping movement burst on the same sample
        return bytes
    }
    public mutating func movement(side: Int, dx: Int, dy: Int, strength: Double, rate: Double = 40, spacingMS: Double = 1, followsMovement: Bool = false, at now: Double) -> [UInt8]? {
        guard now.isFinite, dx != 0 || dy != 0, let bytes = Self.pulse(side: side, strength: strength, spacingMS: spacingMS) else { return nil }
        if followsMovement {
            // Integrate emitted cursor distance, independent of input report frequency.
            // Keep at most one pending burst, so fast flicks cannot queue a buzz later.
            if let prior = sampled[side], now < prior || now - prior > 0.15 { distance[side] = 0 }
            sampled[side] = now
            distance[side] = min(16, (distance[side] ?? 0) + hypot(Double(dx), Double(dy)))
            guard (distance[side] ?? 0) >= 16 else { return nil }
        } else {
            distance[side] = nil; sampled[side] = nil
        }
        let frequency = rate.isFinite ? min(40,max(5,rate)) : 40
        if let prior = last[side], now >= prior, now - prior < 1 / frequency { return nil }
        if followsMovement { distance[side] = 0 }
        last[side] = now
        return bytes
    }
    public mutating func reset() { last = [:]; distance = [:]; sampled = [:]; touched = []; lastTouch = [:] }
}
