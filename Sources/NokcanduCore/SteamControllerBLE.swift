import Foundation

/// The original (2015) Steam Controller over Bluetooth LE (firmware with BLE support; product 0x1105 or 0x1106).
/// Facts from Valve's SDL driver (SDL_hidapi_steam.c, controller_structs.h): everything, input and commands,
/// travels as report 3 in 20-byte segments — the report number, a header (0x80 data, 0x40 last, low three bits
/// the segment's number) and 18 bytes of payload — which join into one packet.
/// A state packet starts with its type (4) in the low nibble and a bitmask of the chunks it carries (the high
/// nibble plus the next byte); a chunk is only sent when it changed, so the rest is kept from earlier packets.
/// See docs/steam-controller-bluetooth.md.
public enum SteamControllerBLE {
    public static let products = [0x1105, 0x1106]
    public static let reportID: UInt8 = 3
    public static let payloadSize = 18
    public static let segmentSize = payloadSize + 2

    // MARK: Commands

    /// A command as the cable takes it (64 bytes: its id, the length of what follows, then that) in the
    /// feature-report segments Bluetooth takes, each starting with the report number. Only the command's own
    /// bytes are sent, as SDL does, not the 64-byte padding.
    public static func segments(_ command: [UInt8]) -> [[UInt8]] {
        guard !command.isEmpty else { return [] }
        let length = command.count >= 2 ? min(command.count, max(2, 2 + Int(command[1]))) : command.count
        let data = Array(command.prefix(length))
        var result: [[UInt8]] = []
        var index = 0
        while index < data.count {
            let piece = data[index..<min(data.count, index + payloadSize)]
            index += piece.count
            var segment = [UInt8](repeating: 0, count: segmentSize)
            segment[0] = reportID
            segment[1] = 0x80 | UInt8(result.count & 7) | (index >= data.count ? 0x40 : 0)
            segment.replaceSubrange(2..<(2 + piece.count), with: piece)
            result.append(segment)
        }
        return result
    }

    // MARK: Joining segments

    /// Joins segments into packets: an input state packet, or the reply to a command (which then reads as the
    /// cable's 64-byte reply, starting with the command's id).
    public struct Assembler: Sendable {
        private var buffer: [UInt8] = []
        private var expected = 0
        public init() {}
        public mutating func reset() { buffer = []; expected = 0 }
        /// One report as IOKit hands it over: with its report number in front (on macOS a feature reply can carry
        /// it twice), or without it. Returns the whole packet once its last segment is in.
        public mutating func add(_ report: [UInt8]) -> [UInt8]? {
            var s = report
            if s.count == segmentSize - 1, s.first != SteamControllerBLE.reportID { s.insert(SteamControllerBLE.reportID, at: 0) }
            if s.count > segmentSize, s[0] == SteamControllerBLE.reportID, s[1] == SteamControllerBLE.reportID { s.removeFirst() }
            guard s.count >= segmentSize, s[0] == SteamControllerBLE.reportID else { return nil }   // keyboard/mouse reports
            let header = s[1]
            guard header & 0x80 != 0 else { return nil }                // empty segments come now and then
            let number = Int(header & 7)
            if number != expected {
                reset()
                if number != 0 { return nil }                           // a segment went missing: wait for the next packet
            }
            buffer += s[2..<segmentSize]
            if header & 0x40 != 0 {
                let packet = buffer
                reset()
                return packet
            }
            expected += 1
            if expected > 7 { reset() }
            return nil
        }
    }

    // MARK: State

    /// The controller's state, kept from the chunks each packet brings.
    public struct Decoder: Sendable {
        /// The cable's 8-byte button and trigger block: buttons in bytes 0–2 and 5–7, triggers in 3 and 4.
        private var block = [UInt8](repeating: 0, count: 8)
        private var stick = [Int16](repeating: 0, count: 2)
        private var left = [Int16](repeating: 0, count: 2)
        private var right = [Int16](repeating: 0, count: 2)
        private var accel = [Int16](repeating: 0, count: 3)
        private var gyro = [Int16](repeating: 0, count: 3)
        private var counter: UInt32 = 0
        public init() {}
        public static func isState(_ packet: [UInt8]) -> Bool { packet.count >= 2 && packet[0] & 0x0F == 4 }

        public mutating func decode(_ packet: [UInt8]) -> SteamControllerReport.State? {
            guard Self.isState(packet) else { return nil }
            let mask = UInt32(packet[0] & 0xF0) | UInt32(packet[1]) << 8
            var i = 2
            func take(_ n: Int) -> [UInt8]? {
                guard i + n <= packet.count else { return nil }
                defer { i += n }
                return Array(packet[i..<(i + n)])
            }
            func values(_ n: Int) -> [Int16]? {
                take(n * 2).map { b in (0..<n).map { Int16(bitPattern: UInt16(b[$0 * 2]) | UInt16(b[$0 * 2 + 1]) << 8) } }
            }
            // A packet cut short leaves what it didn't carry as it was.
            if mask & 0x10 != 0 { guard let b = take(3) else { return nil }; block.replaceSubrange(0..<3, with: b) }
            if mask & 0x20 != 0 { guard let b = take(2) else { return nil }; block.replaceSubrange(3..<5, with: b) }
            if mask & 0x40 != 0 { guard let b = take(3) else { return nil }; block.replaceSubrange(5..<8, with: b) }
            if mask & 0x80 != 0 { guard let v = values(2) else { return nil }; stick = v }
            if mask & 0x100 != 0 { guard let v = values(2) else { return nil }; left = v }
            if mask & 0x200 != 0 { guard let v = values(2) else { return nil }; right = v }
            if mask & 0x400 != 0 { guard let v = values(3) else { return nil }; accel = v }
            if mask & 0x800 != 0 { guard let v = values(3) else { return nil }; gyro = v }
            counter &+= 1
            let flags = UInt32(block[0]) | UInt32(block[1]) << 8 | UInt32(block[2]) << 16
            let leftTouch = flags & (1 << 19) != 0
            return SteamControllerReport.state(counter: counter, flags: flags, leftTrigger: block[3], rightTrigger: block[4],
                                               stick: stick, leftPad: leftTouch ? left : [0, 0], rightPad: right,
                                               leftTouch: leftTouch, gyro: gyro, acceleration: accel)
        }
    }
}
