// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Controllers macOS's own controller support reads (DualShock 4, DualSense, Xbox Wireless over Bluetooth, Switch Pro),
/// for the times Nokcandu takes one over: it opens the controller exclusively so games and other apps stop seeing it
/// (no double input next to Nokcandu's mappings or its virtual controller), and then reads its reports itself.
/// Report layouts, start-up and rumble follow SDL's HIDAPI drivers.
public enum TakeoverPad: Equatable, Sendable {
    case ps4, ps5, xbox, switchPro

    public static func find(vendor: Int, product: Int) -> TakeoverPad? {
        switch (vendor, product) {
        case (0x054C, 0x05C4), (0x054C, 0x09CC), (0x054C, 0x0BA0): return .ps4
        case (0x054C, 0x0CE6), (0x054C, 0x0DF2): return .ps5
        // Firmware 5 and later (Bluetooth report 0x01 with 16-bit sticks): Series X|S, One S, Elite Series 2.
        // Older firmware (02E0, 02FD) reports another layout and stays with macOS.
        case (0x045E, 0x0B13), (0x045E, 0x0B20), (0x045E, 0x0B22): return .xbox
        case (0x057E, 0x2009): return .switchPro
        default: return nil
        }
    }
    public static let matching: [(vendor: Int, product: Int)] = [
        (0x054C, 0x05C4), (0x054C, 0x09CC), (0x054C, 0x0BA0), (0x054C, 0x0CE6), (0x054C, 0x0DF2),
        (0x045E, 0x0B13), (0x045E, 0x0B20), (0x045E, 0x0B22), (0x057E, 0x2009),
    ]
    public var name: String {
        switch self {
        case .ps4: "DualShock 4"; case .ps5: "DualSense"; case .xbox: "Xbox Wireless Controller"; case .switchPro: "Switch Pro Controller"
        }
    }
    /// GameController's `productCategory` for this kind: the copy macOS shows for a controller taken over is ignored.
    public var gameControllerCategories: [String] {
        switch self {
        case .ps4: ["DualShock 4"]; case .ps5: ["DualSense", "DualSense Edge"]; case .xbox: ["Xbox One"]; case .switchPro: ["Switch Pro Controller"]
        }
    }
    /// A feature report to read once at start: what makes DualShock 4 and DualSense send their full reports by Bluetooth.
    public var enableFeature: UInt8? {
        switch self { case .ps4: 0x02; case .ps5: 0x05; default: nil }
    }
}

/// One taken-over controller's decoder, start-up and rumble.
public struct TakeoverPadDecoder: Sendable {
    public let kind: TakeoverPad
    public let bluetooth: Bool
    private var counter: UInt8 = 0
    /// Switch Pro stick calibration (factory, from its flash): centre and reach on each side, per axis (lx, ly, rx, ry).
    public private(set) var proSticks = SwitchProPad.Calibration.default

    public init(_ kind: TakeoverPad, bluetooth: Bool) { self.kind = kind; self.bluetooth = bluetooth }

    private var lastMotion: Double?, firstFull: Double?, lastRepair = -Double.infinity
    /// Switch Pro: commands that put it back the way Nokcandu set it up, when a report shows something else changed it.
    /// Other programs that open the controller (SDL in a game, which turns motion off unless the game asks for it)
    /// can switch its motion off or its reports back to simple ones; without this the gyro just stops.
    /// At most once a second.
    public mutating func repairs(after r: [UInt8], at now: Double) -> [[UInt8]] {
        guard kind == .switchPro, let id = r.first else { return [] }
        var broken = false, motionOff = false
        if id == 0x3F { broken = true }
        else if id == 0x30 {
            // At rest the accelerometer still reads gravity, so a motion block of zeros means motion is off.
            if r.count >= 49, r[13..<49].contains(where: { $0 != 0 }) { lastMotion = now; return [] }
            if firstFull == nil { firstFull = now }
            motionOff = now - (lastMotion ?? firstFull ?? now) > 0.5
        }
        guard broken || motionOff, now - lastRepair >= 1 else { return [] }
        let out = broken ? [proSubcommand(0x03, [0x30]), proSubcommand(0x40, [0x01])] : [proSubcommand(0x40, [0x01])]
        if !out.isEmpty { lastRepair = now }
        return out
    }

    /// Reports to send at start, in order, a little apart.
    public mutating func start() -> [[UInt8]] {
        guard kind == .switchPro else { return [] }
        var out: [[UInt8]] = []
        if !bluetooth { out += [[0x80, 0x02], [0x80, 0x03], [0x80, 0x02], [0x80, 0x04]] }   // handshake, fast link, USB only
        out.append(proSubcommand(0x03, [0x30]))              // full reports
        out.append(proSubcommand(0x40, [0x01]))              // motion on
        out.append(proSubcommand(0x48, [0x01]))              // rumble on
        out.append(proSubcommand(0x10, [0x3D, 0x60, 0x00, 0x00, 18]))   // factory stick calibration
        return out
    }

    public mutating func decode(_ r: [UInt8]) -> ReportPadState? {
        switch kind {
        case .ps4: return PlayStationPad.ps4Report(r)
        case .ps5: return PlayStationPad.ps5Report(r)
        case .xbox: return XboxBluetoothPad.decode(r)
        case .switchPro:
            if let c = SwitchProPad.calibration(fromReply: r) { proSticks = c }
            return SwitchProPad.decode(r, calibration: proSticks)
        }
    }

    /// The output report for rumble at these strengths (0…1). A first byte of 0 is "no report ID", as with hidapi.
    public mutating func rumble(low: Double, high: Double) -> [UInt8] {
        func byte(_ v: Double, _ top: Double = 255) -> UInt8 { UInt8((max(0, min(1, v)) * top).rounded()) }
        switch kind {
        case .ps4:
            if !bluetooth { var r = [UInt8](repeating: 0, count: 32); r[0] = 0x05; r[1] = 0x01; r[4] = byte(high); r[5] = byte(low); return r }
            var r = [UInt8](repeating: 0, count: 78)
            r[0] = 0x11; r[1] = 0xC4; r[3] = 0x01; r[6] = byte(high); r[7] = byte(low)
            return PlayStationPad.signed(r)
        case .ps5:
            if !bluetooth { var r = [UInt8](repeating: 0, count: 48); r[0] = 0x02; r[1] = 0x03; r[3] = byte(high); r[4] = byte(low); return r }
            var r = [UInt8](repeating: 0, count: 78)
            r[0] = 0x31; r[1] = 0x02; r[2] = 0x03; r[4] = byte(high); r[5] = byte(low)
            return PlayStationPad.signed(r)
        case .xbox:
            return [0x03, 0x0F, 0x00, 0x00, byte(low, 100), byte(high, 100), 0xFF, 0x00, 0xEB]
        case .switchPro:
            counter = (counter + 1) & 0x0F
            return [0x10, counter] + SwitchProPad.rumble(max(low, high)) + SwitchProPad.rumble(max(low, high))
        }
    }

    private mutating func proSubcommand(_ id: UInt8, _ args: [UInt8]) -> [UInt8] {
        counter = (counter + 1) & 0x0F
        let neutral = SwitchProPad.rumble(0)
        var r = [0x01, counter] + neutral + neutral + [id] + args
        r += [UInt8](repeating: 0, count: max(0, (bluetooth ? 49 : 64) - r.count))
        return r
    }
}

/// Xbox Wireless Controller by Bluetooth (firmware 5+), report 0x01: sticks 0…65535 (y down), triggers 0…1023, a hat,
/// then A B · X Y · LB RB · · View Menu Xbox LS RS, and Share in the next byte (SDL_hidapi_xboxone.c).
public enum XboxBluetoothPad {
    public static func decode(_ d: [UInt8]) -> ReportPadState? {
        guard d.count >= 16, d[0] == 0x01 else { return nil }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        func stick(_ i: Int) -> Int { max(-32767, u16(i) - 32768) }
        func trigger(_ i: Int) -> Int { min(1023, u16(i)) * 32767 / 1023 }
        let h = d[13] & 0x0F
        var held = (1...8).contains(h) ? EightBitDoController.hat(h - 1) : []
        held.formUnion(ReportPadDecoder.bits(d[14], [(0x01, .a), (0x02, .b), (0x08, .x), (0x10, .y), (0x40, .lb), (0x80, .rb)]))
        held.formUnion(ReportPadDecoder.bits(d[15], [(0x04, .back), (0x08, .start), (0x10, .guide), (0x20, .ls), (0x40, .rs)]))
        if d.count >= 17, d[16] & 0x01 != 0 { held.insert(.misc) }
        return ReportPadState(buttons: held, axes: [0: stick(1), 1: stick(3), 2: stick(5), 3: stick(7), 4: trigger(9), 5: trigger(11)])
    }
}

/// Nintendo Switch Pro Controller full report 0x30 (or a subcommand reply 0x21, which carries the same state).
/// Buttons by the letters printed on them, as macOS's own controller support reports Nintendo controllers (and
/// Switch2Controller does), so a profile made with the controller shared works the same once it's taken over.
public enum SwitchProPad {
    public struct Calibration: Equatable, Sendable {
        /// Per axis (lx, ly, rx, ry): centre, reach below, reach above (raw 12-bit units).
        public var centre: [Int], below: [Int], above: [Int]
        public static let `default` = Calibration(centre: [2048, 2048, 2048, 2048], below: [1600, 1600, 1600, 1600], above: [1600, 1600, 1600, 1600])
    }

    static func unpack(_ d: [UInt8], _ i: Int) -> (Int, Int) {
        (Int(d[i]) | (Int(d[i + 1]) & 0x0F) << 8, Int(d[i + 1]) >> 4 | Int(d[i + 2]) << 4)
    }

    /// The factory calibration from the reply to an 18-byte flash read at 0x603D (left stick, then right).
    public static func calibration(fromReply r: [UInt8]) -> Calibration? {
        guard r.count >= 20 + 18, r[0] == 0x21, r[14] == 0x10, r[15] == 0x3D, r[16] == 0x60, r[19] == 18 else { return nil }
        let d = Array(r[20..<38])
        // Left: above, centre, below. Right: centre, below, above.
        let la = unpack(d, 0), lc = unpack(d, 3), lb = unpack(d, 6)
        let rc = unpack(d, 9), rb = unpack(d, 12), ra = unpack(d, 15)
        let c = Calibration(centre: [lc.0, lc.1, rc.0, rc.1], below: [lb.0, lb.1, rb.0, rb.1], above: [la.0, la.1, ra.0, ra.1])
        // An erased or odd flash: keep the defaults.
        let sane = c.centre.allSatisfy { (1024...3072).contains($0) } && (c.below + c.above).allSatisfy { (400...2047).contains($0) }
        return sane ? c : nil
    }

    static func axis(_ raw: Int, _ i: Int, _ c: Calibration, invert: Bool) -> Int {
        let x = raw - c.centre[i]
        var v = x >= 0 ? x * 32767 / max(1, c.above[i]) : x * 32767 / max(1, c.below[i])
        if invert { v = -v }
        return max(-32767, min(32767, v))
    }

    public static func decode(_ d: [UInt8], calibration c: Calibration = .default) -> ReportPadState? {
        guard d.count >= 13, d[0] == 0x30 || d[0] == 0x21 else { return nil }
        var held = ReportPadDecoder.bits(d[3], [(0x01, .y), (0x02, .x), (0x04, .b), (0x08, .a), (0x40, .rb)])
        held.formUnion(ReportPadDecoder.bits(d[4], [(0x01, .back), (0x02, .start), (0x04, .rs), (0x08, .ls), (0x10, .guide), (0x20, .misc)]))
        held.formUnion(ReportPadDecoder.bits(d[5], [(0x01, .down), (0x02, .up), (0x04, .right), (0x08, .left), (0x40, .lb)]))
        let zl = d[5] & 0x80 != 0, zr = d[3] & 0x80 != 0
        let l = unpack(d, 6), r = unpack(d, 9)
        var gyro: [Float]?, accel: [Float]?
        if d[0] == 0x30, d.count >= 49 {
            // The newest of the report's three motion samples. Report axes to SDL's: (−y, z, −x); Nokcandu's are SDL's
            // (x, z, y). Accelerometer 4096 a g, gyro 14.2857 a degree per second (SDL's defaults for this controller).
            func s16(_ i: Int) -> Float { Float(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
            let o = 13 + 24, a = Float(1.0 / 4096), g = Float(Double.pi / 180 / 14.2857)
            let ax = s16(o) * a, ay = s16(o + 2) * a, az = s16(o + 4) * a
            let gx = s16(o + 6) * g, gy = s16(o + 8) * g, gz = s16(o + 10) * g
            if [ax, ay, az, gx, gy, gz].contains(where: { $0 != 0 }) {
                gyro = [-gy, -gx, gz]; accel = [-ay, -ax, az]
            }
        }
        return ReportPadState(buttons: held,
                              axes: [0: axis(l.0, 0, c, invert: false), 1: axis(l.1, 1, c, invert: true),
                                     2: axis(r.0, 2, c, invert: false), 3: axis(r.1, 3, c, invert: true),
                                     4: zl ? 32767 : 0, 5: zr ? 32767 : 0],
                              gyro: gyro, acceleration: accel)
    }

    /// One side's 4 rumble bytes: neutral, or SDL's fixed rumble (high band 0x74 at 0xBE, low band 0x3D at 0x806F)
    /// while asked to rumble at all. The Pro's amplitude coding isn't linear, so strength only turns it on.
    public static func rumble(_ strength: Double) -> [UInt8] {
        strength > 0.02 ? [0x74, 0xBE, 0xBD, 0x6F] : [0x00, 0x01, 0x40, 0x40]
    }
}

extension PlayStationPad {
    /// A Bluetooth output report with its CRC-32 (over 0xA2 then the report) in its last four bytes.
    static func signed(_ report: [UInt8]) -> [UInt8] {
        var r = report
        let crc = crc32([0xA2] + r[0..<(r.count - 4)])
        for i in 0..<4 { r[r.count - 4 + i] = UInt8((crc >> (8 * UInt32(i))) & 0xFF) }
        return r
    }
    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }
}
