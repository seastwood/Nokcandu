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
    /// Flags a real keyboard puts on a key's own events. macOS's shortcuts match them: ⌃↑ (Mission Control)
    /// and ⌃← / ⌃→ (Spaces) are stored with Fn and keypad set, so an arrow posted without them is never
    /// recognised as the shortcut.
    public static func keyFlags(_ key: Int) -> CGEventFlags {
        switch key {
        case 123...126: return [.maskNumericPad, .maskSecondaryFn]                    // arrows
        case 114, 115, 116, 117, 119, 121: return .maskSecondaryFn                     // Help, Home, Page Up, ⌦, End, Page Down
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,                   // F1–F12
             105, 107, 113, 106, 64, 79, 80, 90: return .maskSecondaryFn              // F13–F20
        case 65, 67, 69, 71, 75, 76, 78, 81...89, 91, 92: return .maskNumericPad       // keypad
        default: return []
        }
    }
    public mutating func update(_ key: Int, down: Bool) -> CGEventFlags {
        if down { held.insert(key) } else { held.remove(key) }
        return held.reduce(CGEventFlags()) { $0.union(Self.modifier($1)) }
    }
}
