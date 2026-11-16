import Foundation

/// Nintendo Switch 2 controllers over USB: the Pro Controller (0x2069) and the GameCube controller (0x2073).
/// Facts from SDL's driver (SDL_hidapi_switch2.c): over USB they send nothing until a start-up sequence goes to
/// their second interface's bulk endpoints; then 64-byte HID reports carry buttons, 12-bit sticks and motion.
/// Stick calibration is read from the controller's flash. Written without the controllers (November 15, 2026):
/// see docs/switch-2-controllers.md.
public enum Switch2Controller {
    public static let vendor = 0x057E
    public static let pro = 0x2069, gameCube = 0x2073, joyConLeft = 0x2067, joyConRight = 0x2066
    public static let products = [pro, gameCube, joyConLeft, joyConRight]
    public static func isJoyCon(_ product: Int) -> Bool { product == joyConLeft || product == joyConRight }

    /// Each command, then up to 64 bytes of reply read back. Exactly SDL's sequence; the length of a command is
    /// its byte 5 plus 8.
    public static let startup: [[UInt8]] = [
        [0x07, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        [0x0c, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00],
        [0x11, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        [0x0a, 0x91, 0x00, 0x08, 0x00, 0x14, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
         0xff, 0x35, 0x00, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x0c, 0x91, 0x00, 0x04, 0x00, 0x04, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00],     // motion on (bit 4)
        [0x01, 0x91, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00],
        [0x01, 0x91, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
        [0x08, 0x91, 0x00, 0x02, 0x00, 0x04, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00],
        [0x03, 0x91, 0x00, 0x0a, 0x00, 0x04, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00],
        [0x03, 0x91, 0x00, 0x0d, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
    ]
    /// Player light 1 on (SDL's pattern for the first player).
    public static let playerLight: [UInt8] = [0x09, 0x91, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0]
    /// Reads 64 bytes of flash at `address`; the reply's data starts 16 bytes in.
    public static func flashRead(_ address: UInt32) -> [UInt8] {
        [0x02, 0x91, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0, 0, 0, 0,
         UInt8(address & 255), UInt8(address >> 8 & 255), UInt8(address >> 16 & 255), UInt8(address >> 24)]
    }
    public static let factoryLeftStick: UInt32 = 0x13080, factoryRightStick: UInt32 = 0x130C0
    public static let userLeftStick: UInt32 = 0x1FC040, userRightStick: UInt32 = 0x1FC080, triggerZero: UInt32 = 0x13140

    public struct Axis: Equatable, Sendable { public var neutral = 0, max = 0, min = 0 }
    public struct Stick: Equatable, Sendable { public var x = Axis(), y = Axis() }
    public struct Calibration: Equatable, Sendable {
        public var left = Stick(), right = Stick()
        public var leftTriggerZero = 0, rightTriggerZero = 0
        public init() {}
    }
    /// Nine packed bytes: neutral, max and min (distances from neutral), 12 bits each for x and y.
    public static func stick(_ d: ArraySlice<UInt8>) -> Stick? {
        let b = Array(d)
        guard b.count >= 9 else { return nil }
        func x(_ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) & 0x0F) << 8 }
        func y(_ i: Int) -> Int { Int(b[i + 1]) >> 4 | Int(b[i + 2]) << 4 }
        return Stick(x: Axis(neutral: x(0), max: x(3), min: x(6)), y: Axis(neutral: y(0), max: y(3), min: y(6)))
    }
    /// A flash reply's 64 data bytes (they start 16 bytes into the reply).
    public static func flashData(_ reply: [UInt8]) -> [UInt8]? { reply.count >= 0x50 ? Array(reply[0x10..<0x50]) : nil }

    /// −32768…32767 from a 12-bit reading, with the calibration if it has one (SDL's MapJoystickAxis).
    static func axis(_ raw: Int, _ c: Axis, invert: Bool) -> Int {
        var v: Int
        if c.neutral != 0, c.min != 0, c.max != 0 {
            let d = Double(raw - c.neutral)
            v = Int(max(-32768, min(32767, (d < 0 ? d / Double(c.min) : d / Double(c.max)) * 32767)))
        } else {
            v = Int(max(-32768, min(32767, Double(raw) / 4096 * 65535 - 32768)))
        }
        return invert ? ~v : v
    }

    public struct State: Equatable, Sendable {
        public var buttons: Set<PadProfiles.Input>
        /// SDL's order, y down; triggers 0…32767.
        public var axes: [Int: Int]
        /// Nokcandu's axes (as the original Steam Controller's): rad/s and g.
        public var gyro: [Float], acceleration: [Float]
    }

    /// A 64-byte report, as IOKit hands it over.
    public static func decode(_ d: [UInt8], product: Int, calibration c: Calibration) -> State? {
        guard d.count >= 64, products.contains(product) else { return nil }
        var held = Set<PadProfiles.Input>()
        func on(_ byte: Int, _ bit: UInt8, _ i: PadProfiles.Input) { if d[byte] & bit != 0 { held.insert(i) } }
        var lt = 0, rt = 0
        if product != gameCube {
            // Joy-Con 2 use the same bytes for their half of the controller (SDL's "combined" layout).
            // The Pro Controller's buttons by the letters printed on them, as macOS reports Nintendo controllers.
            on(5, 0x01, .y); on(5, 0x02, .x); on(5, 0x04, .b); on(5, 0x08, .a); on(5, 0x40, .rb)
            on(6, 0x01, .back); on(6, 0x02, .start); on(6, 0x04, .rs); on(6, 0x08, .ls); on(6, 0x10, .guide); on(6, 0x20, .misc); on(6, 0x40, .paddle3)
            on(7, 0x40, .lb)
            on(8, 0x01, .paddle1); on(8, 0x02, .paddle2)
            rt = d[5] & 0x80 != 0 ? 32767 : 0; lt = d[7] & 0x80 != 0 ? 32767 : 0
        } else {
            // GameCube: by position (A bottom, B right, X left, Y top), as the picture shows them.
            on(5, 0x01, .x); on(5, 0x02, .y); on(5, 0x04, .a); on(5, 0x08, .b); on(5, 0x80, .rb)
            on(6, 0x02, .start); on(6, 0x10, .guide); on(6, 0x20, .misc); on(6, 0x40, .paddle3)
            on(7, 0x80, .lb)
            func trigger(_ v: UInt8, zero: Int, click: Bool) -> Int {
                click ? 32767 : Int(max(0, min(1, (Double(v) - Double(zero)) / (232 - Double(zero)))) * 32767)
            }
            lt = trigger(d[61], zero: c.leftTriggerZero, click: d[7] & 0x40 != 0)
            rt = trigger(d[62], zero: c.rightTriggerZero, click: d[5] & 0x40 != 0)
        }
        on(7, 0x01, .down); on(7, 0x02, .up); on(7, 0x04, .right); on(7, 0x08, .left)
        let lx = Int(d[11]) | (Int(d[12]) & 0x0F) << 8, ly = Int(d[12]) >> 4 | Int(d[13]) << 4
        let rx = Int(d[14]) | (Int(d[15]) & 0x0F) << 8, ry = Int(d[15]) >> 4 | Int(d[16]) << 4
        // A right Joy-Con's one stick has its calibration where other controllers keep the left stick's.
        let rightCal = product == joyConRight ? c.left : c.right
        var axes = [0: axis(lx, c.left.x, invert: false), 1: axis(ly, c.left.y, invert: true),
                    2: axis(rx, rightCal.x, invert: false), 3: axis(ry, rightCal.y, invert: true), 4: lt, 5: rt]
        // A Joy-Con has only its own half: the other half's sticks and trigger aren't there.
        if product == joyConLeft { axes[2] = nil; axes[3] = nil; axes[5] = nil }
        if product == joyConRight { axes[0] = nil; axes[1] = nil; axes[4] = nil }
        func s16(_ i: Int) -> Float { Float(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
        // SDL gives gyro (0x37, 0x3b, −0x39) and acceleration (0x31, 0x35, −0x33) in its axes; the original Steam
        // Controller's SDL axes (x, z, y) of its own make this, in Nokcandu's: gyro (0x37, −0x39, 0x3b), and
        // acceleration (0x31, −0x33, 0x35). Gyro: 34.8 rad/s full scale; acceleration: ±8 g.
        let g = Float(34.8) / 32767, a = Float(8) / 32767
        return State(buttons: held, axes: axes, gyro: [s16(0x37) * g, -s16(0x39) * g, s16(0x3b) * g],
                     acceleration: [s16(0x31) * a, -s16(0x33) * a, s16(0x35) * a])
    }

    /// A left and a right Joy-Con 2 as one controller (either may be missing): buttons and axes from both, motion
    /// from the right one when it's there (as SDL does).
    public static func merge(left: State?, right: State?) -> State? {
        guard left != nil || right != nil else { return nil }
        var axes = [0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0]
        for s in [left, right].compactMap({ $0 }) { for (k, v) in s.axes { axes[k] = v } }
        let motion = right ?? left!
        return State(buttons: (left?.buttons ?? []).union(right?.buttons ?? []), axes: axes, gyro: motion.gyro, acceleration: motion.acceleration)
    }

    /// Rumble state: sent with every input report while it's on (SDL sends it every 12 ms at most).
    public struct Rumble: Equatable, Sendable {
        public var low: UInt16 = 0, high: UInt16 = 0
        var sequence: UInt8 = 0, error: UInt32 = 0
        public init() {}
        public var isOn: Bool { low != 0 || high != 0 }
        /// The 64-byte output report (its first byte is the report ID) for this controller, advancing the sequence.
        public mutating func report(product: Int) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 64)
            r[1] = 0x50 | (sequence & 0x0F)
            sequence &+= 1
            if product == gameCube {
                // On or off only: spread over time to give the strength.
                r[0] = 0x03
                let m = UInt32(max(low, high))
                if m == 0 { r[2] = 2; error = 0 }
                else if error < m { r[2] = 1; error += 65535 - m }
                else { r[2] = 0; error -= m }
                return r
            }
            // Kept short of the motors' full strength, as SDL does (29000 of 65535).
            let lo = UInt16(Int(low) * 29000 / 65535), hi = UInt16(Int(high) * 29000 / 65535)
            let hiFreq: UInt16 = 0x187, loFreq: UInt16 = 0x112
            r[2] = UInt8(hiFreq & 0xFF)
            r[3] = UInt8(((hi >> 4) & 0xFC) | ((hiFreq >> 8) & 0x03))
            r[4] = UInt8(((hi >> 12) | (loFreq << 4)) & 0xFF)
            r[5] = UInt8((lo & 0xC0) | ((loFreq >> 4) & 0x3F))
            r[6] = UInt8(lo >> 8)
            if product == pro { r[0] = 0x02; for i in 0..<6 { r[0x11 + i] = r[1 + i] } } else { r[0] = 0x01 }
            return r
        }
    }
}
