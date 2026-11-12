import Foundation

/// A socket-delivered down must release through the same process, even after
/// focus/capture changes. A failed release never falls back to an absolute click.
public struct PadMouseSocketRoute {
    private var targets: [Int: Int32] = [:]
    public init() {}
    public var held: Set<Int> { Set(targets.keys) }
    public mutating func route(button: Int, down: Bool, target: Int32, available: Bool,
                               send: (Int32, Int, Bool) -> Bool) -> Bool {
        guard (0...4).contains(button) else { return false }
        if let original = targets[button] {
            if !down { _ = send(original, button, false); targets[button] = nil }
            return true
        }
        guard down, target > 0, available, send(target, button, true) else { return false }
        targets[button] = target
        return true
    }
}
