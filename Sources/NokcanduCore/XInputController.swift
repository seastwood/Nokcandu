import Foundation

/// Wired Xbox 360 controllers and the many controllers that speak their protocol (XInput: USB interface class
/// 0xFF, subclass 0x5D, protocol 0x01), which macOS has no driver for. Their reports come from the interface's
/// interrupt endpoint; the layout is the long-documented one (Linux's xpad driver, SDL's xbox360 driver).
public enum XInputController {
    public static let interfaceClass = 0xFF, interfaceSubclass = 0x5D, interfaceProtocol = 0x01

    /// A 20-byte input report (type 0, length 0x14) as a standard controller: inputs held, axes in SDL's order
    /// (y down; triggers 0…32767). nil for other reports (status, headset…).
    public static func decode(_ d: [UInt8]) -> (buttons: Set<PadProfiles.Input>, axes: [Int: Int])? {
        guard d.count >= 14, d[0] == 0x00, d[1] >= 0x14 else { return nil }
        var held = Set<PadProfiles.Input>()
        let bits: [(Int, UInt8, PadProfiles.Input)] = [
            (2, 0x01, .up), (2, 0x02, .down), (2, 0x04, .left), (2, 0x08, .right),
            (2, 0x10, .start), (2, 0x20, .back), (2, 0x40, .ls), (2, 0x80, .rs),
            (3, 0x01, .lb), (3, 0x02, .rb), (3, 0x04, .guide), (3, 0x10, .a), (3, 0x20, .b), (3, 0x40, .x), (3, 0x80, .y),
        ]
        for (i, b, input) in bits where d[i] & b != 0 { held.insert(input) }
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
        func flip(_ v: Int) -> Int { v == -32768 ? 32767 : -v }          // the report's y is up
        let axes = [0: s16(6), 1: flip(s16(8)), 2: s16(10), 3: flip(s16(12)),
                    4: Int(d[4]) * 32767 / 255, 5: Int(d[5]) * 32767 / 255]
        return (held, axes)
    }
    /// Rumble: the big (low) and small (high) motors, 0…255.
    public static func rumble(low: UInt8, high: UInt8) -> [UInt8] { [0x00, 0x08, 0x00, low, high, 0x00, 0x00, 0x00] }
    /// The ring of lights: player 1 (6 is "flash, then player 1 on").
    public static let playerLight: [UInt8] = [0x01, 0x03, 0x06]
}
