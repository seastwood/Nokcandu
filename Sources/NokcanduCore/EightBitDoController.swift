import Foundation

/// 8BitDo's own report for its Pro 2, Pro 3, SN30 Pro, SF30 Pro and Ultimate 2/2C/3 controllers in their
/// D-input (Bluetooth or "D" switch) mode: back paddles, Share and, on most, a gyro and rumble, none of which the
/// generic HID description gives. Layout from SDL's driver (SDL_hidapi_8bitdo.c).
public enum EightBitDoController {
    public static let vendor = 0x2DC8
    public static let names: [Int: String] = [
        0x6000: "8BitDo SF30 Pro", 0x6100: "8BitDo SF30 Pro", 0x6001: "8BitDo SN30 Pro", 0x6101: "8BitDo SN30 Pro",
        0x6003: "8BitDo Pro 2", 0x6006: "8BitDo Pro 2", 0x6009: "8BitDo Pro 3",
        0x6012: "8BitDo Ultimate 2 Wireless", 0x301B: "8BitDo Ultimate 2C Wireless", 0x202F: "8BitDo Ultimate 3",
    ]
    public static var products: Set<Int> { Set(names.keys) }
    /// The feature report to read (get) that turns on the full report: Ultimate 3 0x30, the rest 0x06.
    public static func enableFeature(product: Int) -> UInt8? {
        switch product {
        case 0x202F: return 0x30
        case 0x6012, 0x301B: return nil
        default: return 0x06
        }
    }

    public typealias State = ReportPadState

    public static func decode(_ d: [UInt8]) -> State? {
        if d.count == 9 { return old(d) }
        guard d.count >= 10, [0x01, 0x03, 0x04].contains(d[0]) else { return nil }
        var held = hat(d[1])
        let bits: [(UInt8, PadProfiles.Input)] = [(0x01, .a), (0x02, .b), (0x08, .x), (0x10, .y), (0x40, .lb), (0x80, .rb)]
        for (b, input) in bits where d[8] & b != 0 { held.insert(input) }
        // The two back buttons: PL/PR on the Pro 2/3 and Ultimate 2, L4/R4 on the others.
        if d[8] & 0x20 != 0 { held.insert(.paddle2) }
        if d[8] & 0x04 != 0 { held.insert(.paddle1) }
        let bits9: [(UInt8, PadProfiles.Input)] = [(0x10, .guide), (0x04, .back), (0x08, .start), (0x20, .ls), (0x40, .rs), (0x80, .misc)]
        for (b, input) in bits9 where d[9] & b != 0 { held.insert(input) }
        if d.count > 10 {
            if d[10] & 0x01 != 0 { held.insert(.paddle4) }
            if d[10] & 0x02 != 0 { held.insert(.paddle3) }
        }
        var axes = [0: stick(d[2]), 1: stick(d[3]), 2: stick(d[4]), 3: stick(d[5]),
                    4: Int(d[7]) * 32767 / 255, 5: Int(d[6]) * 32767 / 255]
        var gyro: [Float]?, accel: [Float]?
        if d.count >= 27 {
            func s16(_ i: Int) -> Float { Float(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
            let ax = s16(15), ay = s16(17), az = s16(19), gx = s16(21), gy = s16(23), gz = s16(25)
            // SDL's axes are (−y, z, −x) of the controller's; Nokcandu's (as the original Steam Controller's, from
            // SDL's x, z, y) are then (−y, −x, z). Gyro ±2000°/s over the Int16 range; acceleration 4096 per g.
            let g = Float(2000.0 * Double.pi / 180 / 32767)
            gyro = [-gy * g, -gx * g, gz * g]
            accel = [-ay / 4096, -ax / 4096, az / 4096]
            if gyro == [0, 0, 0], accel == [0, 0, 0] { gyro = nil; accel = nil }
        }
        return State(buttons: held, axes: axes, gyro: gyro, acceleration: accel)
    }

    /// Older SF30/SN30 Pro firmware by USB: a 9-byte report.
    static func old(_ d: [UInt8]) -> State {
        var held = hat(d[2])
        let bits: [(UInt8, PadProfiles.Input)] = [(0x01, .a), (0x02, .b), (0x08, .x), (0x10, .y), (0x40, .lb), (0x80, .rb)]
        for (b, input) in bits where d[0] & b != 0 { held.insert(input) }
        let bits1: [(UInt8, PadProfiles.Input)] = [(0x10, .guide), (0x04, .back), (0x08, .start), (0x20, .ls), (0x40, .rs)]
        for (b, input) in bits1 where d[1] & b != 0 { held.insert(input) }
        return State(buttons: held, axes: [0: stick(d[3]), 1: stick(d[4]), 2: stick(d[5]), 3: stick(d[6]),
                                           4: d[1] & 0x01 != 0 ? 32767 : 0, 5: d[1] & 0x02 != 0 ? 32767 : 0],
                     gyro: nil, acceleration: nil)
    }

    public static func hat(_ v: UInt8) -> Set<PadProfiles.Input> {
        switch v {
        case 0: return [.up]
        case 1: return [.up, .right]
        case 2: return [.right]
        case 3: return [.down, .right]
        case 4: return [.down]
        case 5: return [.down, .left]
        case 6: return [.left]
        case 7: return [.up, .left]
        default: return []
        }
    }
    public static func stick(_ v: UInt8) -> Int {
        if v == 0x7F { return 0 }
        let x = Double(Int(v) - 0x7F)
        return Int(x < 0 ? x / 127 * 32768 : x / 128 * 32767).clamped(-32767, 32767)
    }
    /// Rumble (output report 5): low- and high-frequency motors, 0…255.
    public static func rumble(low: UInt8, high: UInt8) -> [UInt8] { [0x05, low, high, 0, 0] }
}

private extension Int { func clamped(_ a: Int, _ b: Int) -> Int { Swift.max(a, Swift.min(b, self)) } }
