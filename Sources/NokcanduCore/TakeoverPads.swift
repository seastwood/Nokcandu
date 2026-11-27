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
    /// Switch Pro motion calibration: the factory one, replaced by the user's (from Switch's System Settings) if any.
    public private(set) var proMotion = SwitchProPad.MotionCalibration.default
    private var userMotion = false

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
        // Motion calibration, as macOS applies it: without it the gyro reads a different bias here than when macOS
        // reads the controller, so each takeover or hand-back undoes the profile's gyro calibration.
        out.append(proSubcommand(0x10, [0x20, 0x60, 0x00, 0x00, 24]))   // factory
        out.append(proSubcommand(0x10, [0x26, 0x80, 0x00, 0x00, 26]))   // user (magic B2 A1, then the same 24 bytes)
        return out
    }

    public mutating func decode(_ r: [UInt8]) -> ReportPadState? {
        switch kind {
        case .ps4: return PlayStationPad.ps4Report(r)
        case .ps5: return PlayStationPad.ps5Report(r)
        case .xbox: return XboxBluetoothPad.decode(r)
        case .switchPro:
            if let c = SwitchProPad.calibration(fromReply: r) { proSticks = c }
            if let (m, user) = SwitchProPad.motionCalibration(fromReply: r), user || !userMotion { proMotion = m; userMotion = userMotion || user }
            return SwitchProPad.decode(r, calibration: proSticks, motion: proMotion)
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

    /// Per axis (x, y, z, report axes): accelerometer and gyro origin and sensitivity, raw units.
    public struct MotionCalibration: Equatable, Sendable {
        public var accelOrigin: [Int], accelSensitivity: [Int], gyroOrigin: [Int], gyroSensitivity: [Int]
        public static let `default` = MotionCalibration(accelOrigin: [0, 0, 0], accelSensitivity: [16384, 16384, 16384],
                                                        gyroOrigin: [0, 0, 0], gyroSensitivity: [13371, 13371, 13371])
    }
    /// The factory (0x6020) or user (0x8026, behind the B2 A1 magic) motion calibration from a flash-read reply,
    /// and whether it's the user's. 4 g at the accelerometer's sensitivity, 936 °/s at the gyro's (dekuNukem's notes).
    public static func motionCalibration(fromReply r: [UInt8]) -> (MotionCalibration, user: Bool)? {
        guard r.count >= 20, r[0] == 0x21, r[14] == 0x10 else { return nil }
        let address = Int(r[15]) | Int(r[16]) << 8
        var start = 20
        let user: Bool
        switch (address, Int(r[19])) {
        case (0x6020, 24): user = false
        case (0x8026, 26):
            guard r.count >= 46, r[20] == 0xB2, r[21] == 0xA1 else { return nil }
            user = true; start = 22
        default: return nil
        }
        guard r.count >= start + 24 else { return nil }
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(r[start + i]) | UInt16(r[start + i + 1]) << 8)) }
        let c = MotionCalibration(accelOrigin: [s16(0), s16(2), s16(4)], accelSensitivity: [s16(6), s16(8), s16(10)],
                                  gyroOrigin: [s16(12), s16(14), s16(16)], gyroSensitivity: [s16(18), s16(20), s16(22)])
        // An erased flash (all 0xFF) or nonsense: keep what there was.
        let sane = (0..<3).allSatisfy { abs(c.accelSensitivity[$0] - c.accelOrigin[$0]) > 1000 && abs(c.gyroSensitivity[$0] - c.gyroOrigin[$0]) > 1000 }
            && c.gyroOrigin.allSatisfy { abs($0) < 2000 }
        return sane ? (c, user) : nil
    }

    public static func decode(_ d: [UInt8], calibration c: Calibration = .default, motion m: MotionCalibration = .default) -> ReportPadState? {
        guard d.count >= 13, d[0] == 0x30 || d[0] == 0x21 else { return nil }
        var held = ReportPadDecoder.bits(d[3], [(0x01, .y), (0x02, .x), (0x04, .b), (0x08, .a), (0x40, .rb)])
        held.formUnion(ReportPadDecoder.bits(d[4], [(0x01, .back), (0x02, .start), (0x04, .rs), (0x08, .ls), (0x10, .guide), (0x20, .misc)]))
        held.formUnion(ReportPadDecoder.bits(d[5], [(0x01, .down), (0x02, .up), (0x04, .right), (0x08, .left), (0x40, .lb)]))
        let zl = d[5] & 0x80 != 0, zr = d[3] & 0x80 != 0
        let l = unpack(d, 6), r = unpack(d, 9)
        var gyro: [Float]?, accel: [Float]?
        if d[0] == 0x30, d.count >= 49 {
            // The newest of the report's three motion samples, less the controller's calibrated origin: 4 g at the
            // accelerometer's sensitivity, 936 °/s at the gyro's (uncalibrated: 4096 a g, 14.2857 a °/s, as SDL).
            // Report axes to SDL's: (−y, z, −x); Nokcandu's are SDL's (x, z, y).
            func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
            let o = 13 + 24
            let raw = (0..<6).map { s16(o + 2 * $0) }
            if raw.contains(where: { $0 != 0 }) {
                func acc(_ i: Int) -> Float { Float(raw[i] - m.accelOrigin[i]) * 4 / Float(m.accelSensitivity[i] - m.accelOrigin[i]) }
                func rot(_ i: Int) -> Float {
                    Float(Double(raw[3 + i] - m.gyroOrigin[i]) * 936 / Double(m.gyroSensitivity[i] - m.gyroOrigin[i]) * Double.pi / 180)
                }
                let ax = acc(0), ay = acc(1), az = acc(2), gx = rot(0), gy = rot(1), gz = rot(2)
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

/// Which of these controllers the Mac Steam client's Steam Input reads (Steam → Settings → Controller), from
/// Steam's config.vdf. Steam reads them itself and gives Steam games its own copy; once Nokcandu takes one, Steam
/// loses it and doesn't pick it back up when Nokcandu hands it back, so a layer that passes the controller on does
/// nothing in those games. Unset keys follow Steam's defaults (PlayStation and Switch on, Xbox off).
public enum SteamInputSupport {
    public static func readsItself(configVDF text: String) -> Set<TakeoverPad> {
        func value(_ key: String) -> String? {
            guard let r = text.range(of: "\"\(key)\"\\s+\"([^\"]*)\"", options: [.regularExpression, .caseInsensitive]) else { return nil }
            let line = String(text[r])
            return line.split(separator: "\"").last.map(String.init)
        }
        var out: Set<TakeoverPad> = []
        if (value("SteamController_PSSupport") ?? "1") != "0" { out.formUnion([.ps4, .ps5]) }
        if (value("SteamController_SwitchSupport") ?? "1") != "0" { out.insert(.switchPro) }
        if (value("SteamController_XBoxSupport") ?? "0") != "0" { out.insert(.xbox) }
        return out
    }
}
