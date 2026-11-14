// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics

/// Where the next controller pointer movement starts from. Nokcandu keeps the pointer's exact position
/// (between pixels) so that consecutive moves add up, and starts afresh from the real position when anything
/// else has moved the pointer. macOS applies a posted move a moment later (about half a millisecond, measured
/// November 2026), so the position it reports can still be the one from before Nokcandu's latest moves: that
/// is not "something else moved it". Treating it so threw away a trackpad's movement whenever a second
/// source (gyro aiming) moved the pointer in the same report: the pointer jumped forward and straight back.
public struct PadPointerContinuity {
    /// Nokcandu's latest position, and the positions macOS may still be showing: the ones Nokcandu posted
    /// just before, and where the pointer was seen before those.
    private var last: CGPoint?, lastAt = 0.0
    private var pending: [(at: Double, p: CGPoint)] = []
    /// A position stays in doubt this long after it was posted or seen; macOS has caught up well within it.
    public static let catchUp = 0.03
    /// After this long without a move, the pointer is taken from where macOS has it.
    public static let idle = 0.25
    /// How far the reported position may be from a known one and still be it (macOS rounds).
    public static let tolerance = 2.5
    public init() {}
    public mutating func reset() { self = Self() }
    /// The position to add the next movement to. `actual`: where macOS reports the pointer now.
    public mutating func base(actual: CGPoint, at now: Double, realMouseRecently: Bool) -> CGPoint {
        pending.removeAll { now - $0.at > Self.catchUp || now < $0.at }
        func near(_ a: CGPoint) -> Bool { abs(a.x - actual.x) <= Self.tolerance && abs(a.y - actual.y) <= Self.tolerance }
        // Seen here before: its first sighting stands, so a pointer macOS is holding somewhere else (a screen
        // edge) stops counting as "not caught up" once that time has passed.
        defer {
            if !pending.contains(where: { near($0.p) }) { pending.append((now, actual)) }
            if pending.count > 16 { pending.removeFirst(pending.count - 16) }
        }
        guard let last, !realMouseRecently, now >= lastAt, now - lastAt < Self.idle else { pending = []; return actual }
        if near(last) || pending.contains(where: { near($0.p) }) { return last }
        pending = []
        return actual
    }
    /// Nokcandu posted a move to `p`.
    public mutating func posted(_ p: CGPoint, at now: Double) {
        if let last { pending.append((lastAt, last)) }
        last = p; lastAt = now
    }
}
