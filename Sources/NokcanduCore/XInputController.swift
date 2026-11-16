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

/// Wired Xbox One and Series controllers and compatible ones (GIP: interface class 0xFF, subclass 0x47, protocol
/// 0xD0), for when macOS doesn't drive them itself. They wait for a "power on" message before sending input.
/// Layout as Linux's xpad driver documents it.
public enum GIPController {
    public static let interfaceClass = 0xFF, interfaceSubclass = 0x47, interfaceProtocol = 0xD0
    /// Power on (sequence number 1).
    public static let powerOn: [UInt8] = [0x05, 0x20, 0x01, 0x01, 0x00]
    /// Acknowledges a message that asks for it (byte 1 has 0x10): the controller repeats it until answered.
    public static func acknowledge(_ m: [UInt8]) -> [UInt8]? {
        guard m.count >= 4, m[1] & 0x10 != 0 else { return nil }
        return [0x01, 0x20, m[2], 0x09, 0x00, m[0], 0x20, m[3], 0x00, 0x00, 0x00, 0x00, 0x00]
    }

    /// Keeps the guide button, which comes in its own message (0x07), between input messages.
    public struct Decoder: Sendable {
        public private(set) var guide = false
        public init() {}
        /// An input (0x20) or guide (0x07) message as a standard controller (axes in SDL's order, y down,
        /// triggers 0…32767); nil for other messages.
        public mutating func decode(_ d: [UInt8], last: (buttons: Set<PadProfiles.Input>, axes: [Int: Int])?) -> (buttons: Set<PadProfiles.Input>, axes: [Int: Int])? {
            guard d.count >= 4 else { return nil }
            if d[0] == 0x07, d.count >= 5 {
                guide = d[4] & 0x01 != 0
                guard var l = last else { return nil }
                if guide { l.buttons.insert(.guide) } else { l.buttons.remove(.guide) }
                return l
            }
            guard d[0] == 0x20, d.count >= 18 else { return nil }
            var held = Set<PadProfiles.Input>()
            let bits: [(Int, UInt8, PadProfiles.Input)] = [
                (4, 0x04, .start), (4, 0x08, .back), (4, 0x10, .a), (4, 0x20, .b), (4, 0x40, .x), (4, 0x80, .y),
                (5, 0x01, .up), (5, 0x02, .down), (5, 0x04, .left), (5, 0x08, .right),
                (5, 0x10, .lb), (5, 0x20, .rb), (5, 0x40, .ls), (5, 0x80, .rs),
            ]
            for (i, b, input) in bits where d[i] & b != 0 { held.insert(input) }
            if guide { held.insert(.guide) }
            func u16(_ i: Int) -> Int { Int(UInt16(d[i]) | UInt16(d[i + 1]) << 8) }
            func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
            func flip(_ v: Int) -> Int { v == -32768 ? 32767 : -v }
            let axes = [0: s16(10), 1: flip(s16(12)), 2: s16(14), 3: flip(s16(16)),
                        4: min(1023, u16(6)) * 32767 / 1023, 5: min(1023, u16(8)) * 32767 / 1023]
            return (held, axes)
        }
    }
}
