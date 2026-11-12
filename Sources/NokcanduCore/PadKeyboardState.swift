import CoreGraphics

/// Recompute flags from held keys so releasing one Shift/Control/Option/Command
/// does not clear the other side of that modifier.
public struct PadKeyboardState {
    private var held = Set<Int>()
    public init() {}
    public static func modifier(_ key: Int) -> CGEventFlags {
        switch key {
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 55, 54: return .maskCommand
        case 63: return .maskSecondaryFn
        default: return []
        }
    }
    public mutating func update(_ key: Int, down: Bool) -> CGEventFlags {
        if down { held.insert(key) } else { held.remove(key) }
        return held.reduce(CGEventFlags()) { $0.union(Self.modifier($1)) }
    }
}
