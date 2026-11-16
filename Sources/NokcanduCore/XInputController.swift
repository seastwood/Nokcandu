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

    /// The Xbox 360 Wireless Receiver: one interface (protocol 0x81) per controller slot, each speaking this
    /// (SDL's xbox360w driver).
    public enum Wireless {
        public static let interfaceProtocol = 0x81
        /// Asks the receiver whether a controller is connected to this slot.
        public static let presence: [UInt8] = [0x08, 0x00, 0x0F, 0xC0, 0, 0, 0, 0, 0, 0, 0, 0]
        public enum Packet: Equatable { case connected(Bool), state(buttons: Set<PadProfiles.Input>, axes: [Int: Int]) }
        public static func decode(_ d: [UInt8]) -> Packet? {
            if d.count == 2, d[0] == 0x08 { return .connected(d[1] & 0x80 != 0) }
            // A controller's state: the wired report's layout from byte 4 (its own header differs).
            guard d.count == 29, d[0] == 0x00, d[1] & 0x01 != 0, !(d[1] == 0x0F && d[3] == 0xF0), !(d[1] == 0x05 && d[5] == 0x12) else { return nil }
            guard let s = XInputController.decode([0x00, 0x14] + d[6...]) else { return nil }
            return .state(buttons: s.buttons, axes: s.axes)
        }
        public static func rumble(low: UInt8, high: UInt8) -> [UInt8] { [0x00, 0x01, 0x0F, 0xC0, 0x00, low, high, 0, 0, 0, 0, 0] }
        /// The slot's light on, as the player for that slot (0…3).
        public static func light(slot: Int) -> [UInt8] { [0x00, 0x00, 0x08, UInt8(0x40 + (0x06 + slot) % 0x0E), 0, 0, 0, 0, 0, 0, 0, 0] }
    }
}

/// Wired Xbox One and Series controllers and compatible ones (GIP: interface class 0xFF, subclass 0x47, protocol
/// 0xD0), for when macOS doesn't drive them itself. They wait for a "power on" message before sending input.
/// Layout as Linux's xpad driver documents it.
public enum GIPController {
    public static let interfaceClass = 0xFF, interfaceSubclass = 0x47, interfaceProtocol = 0xD0
    /// Power on (sequence number 1).
    public static let powerOn: [UInt8] = [0x05, 0x20, 0x01, 0x01, 0x00]
    /// Rumble (Linux's xpad): both handle motors, 0…255 each, the trigger motors off.
    public static func rumble(strong: UInt8, weak: UInt8, sequence: UInt8) -> [UInt8] {
        [0x09, 0x00, sequence, 0x09, 0x00, 0x0F, 0x00, 0x00, strong / 2, weak / 2, 0xFF, 0x00, 0xFF]
    }
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
