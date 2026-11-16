import Foundation

/// Which Steam Controller a report came from.
public enum SteamControllerModel: String, Sendable, Codable {
    case original, steam2026
}

/// The Steam Controller (2026): over USB (product 0x1302), Bluetooth (0x1303) and its Puck (0x1304, or 0x1305;
/// one controller per HID interface 2–5). Facts from Valve's SDL driver (SDL_hidapi_steam_triton.c and
/// steam/controller_structs.h, where it is called Triton): input is plain HID reports, no segments, and no mode to
/// restore — the controller goes back to its own desktop mode ("lizard mode") a few seconds after the last
/// keep-alive, so the keep-alive is resent every couple of seconds while Nokcandu reads it.
/// Written without the controller (November 15, 2026): see docs/steam-controller-2026.md.
public enum SteamController2026 {
    public static let wired = 0x1302, bluetooth = 0x1303, pucks = [0x1304, 0x1305]
    public static let products = [wired, bluetooth] + pucks

    /// The connection a HID interface is, or nil when it isn't the controller's.
    public static func identify(vendor: Int, product: Int, interface: Int) -> SteamControllerTransport? {
        guard vendor == 0x28de else { return nil }
        if product == wired { return .cable }
        if product == bluetooth { return .bluetooth }
        if pucks.contains(product) { return (2...5).contains(interface) ? .receiver : nil }
        return nil
    }

    // MARK: Reports in

    public static let stateReport: UInt8 = 0x42, batteryReport: UInt8 = 0x43, bluetoothStateReport: UInt8 = 0x45
    public static let timestampedStateReport: UInt8 = 0x47, wirelessReports: [UInt8] = [0x46, 0x79]

    /// Buttons (`TritonButtons` in SDL), as Nokcandu's inputs. SDL calls 0x4000 Menu and 0x40 View but sends them
    /// as Back and Start; that is followed here.
    static let buttons: [(UInt32, PadProfiles.Input)] = [
        (0x1, .a), (0x2, .b), (0x4, .x), (0x8, .y),
        (0x10, .misc), (0x20, .rs), (0x4000, .back), (0x40, .start), (0x10000, .guide), (0x8000, .ls),
        (0x200, .rb), (0x80000, .lb),
        (0x2000, .up), (0x400, .down), (0x1000, .left), (0x800, .right),
        (0x80, .paddle1), (0x20000, .paddle2), (0x100, .paddle3), (0x40000, .paddle4),
        (0x0400_0000, .touchpad), (0x0040_0000, .rpclick),
        (0x2000_0000, .lgrip), (0x1000_0000, .rgrip), (0x0100_0000, .lstouch), (0x0010_0000, .rstouch),
    ]
    static let leftPadTouch: UInt32 = 0x0200_0000, rightPadTouch: UInt32 = 0x0020_0000
    static let leftTriggerClick: UInt32 = 0x0800_0000, rightTriggerClick: UInt32 = 0x0080_0000

    /// A state report (with its report number in front) as the same state the original controller gives, with
    /// the right stick, pressures and touch sensors added. Motion is turned into the original's axes.
    public static func decode(_ report: [UInt8], counter: UInt32) -> SteamControllerReport.State? {
        guard let id = report.first, [stateReport, bluetoothStateReport, timestampedStateReport].contains(id), report.count >= 46 else { return nil }
        let p = Array(report.dropFirst())
        func u16(_ i: Int) -> UInt16 { UInt16(p[i]) | UInt16(p[i + 1]) << 8 }
        func s16(_ i: Int) -> Int16 { Int16(bitPattern: u16(i)) }
        func point(_ i: Int) -> SteamControllerReport.Point { .init(max(-1, Float(s16(i)) / 32767), max(-1, Float(s16(i + 2)) / 32767)) }
        let bits = UInt32(p[1]) | UInt32(p[2]) << 8 | UInt32(p[3]) << 16 | UInt32(p[4]) << 24
        // The timestamped report has the trackpads' timestamp before the pads, two bytes further on; the
        // motion sits in the same place either way (its own timestamp is two bytes shorter).
        let pads = id == timestampedStateReport ? 19 : 17
        let motion = 33
        let leftTouch = bits & leftPadTouch != 0, rightTouch = bits & rightPadTouch != 0
        func trigger(_ i: Int, click: UInt32) -> Float { bits & click != 0 ? 1 : max(0, min(1, Float(s16(i)) / 32767)) }
        let gyroScale = Float(2000.0 / 32768.0 * Double.pi / 180)
        // SDL gives the original's gyro as (x, z, y) and this one's as (x, z, −y): flip y to read like the original.
        let gyro = [Float(s16(motion + 6)), -Float(s16(motion + 8)), Float(s16(motion + 10))].map { $0 * gyroScale }
        let accel = [s16(motion), s16(motion + 2), s16(motion + 4)].map { Float($0) / 16384 }
        var state = SteamControllerReport.State(
            counter: counter, buttons: Set(buttons.filter { bits & $0.0 != 0 }.map(\.1)),
            stick: point(9), leftPad: leftTouch ? point(pads) : .init(), rightPad: rightTouch ? point(pads + 6) : .init(),
            leftTouch: leftTouch, rightTouch: rightTouch,
            leftTrigger: trigger(5, click: leftTriggerClick), rightTrigger: trigger(7, click: rightTriggerClick),
            gyro: gyro, acceleration: accel)
        state.kind = .steam2026
        state.rightStick = point(13)
        state.leftPressure = min(1, Float(u16(pads + 4)) / 32768)
        state.rightPressure = min(1, Float(u16(pads + 10)) / 32768)
        return state
    }

    public enum Event: Equatable { case connected, disconnected }
    /// The Puck's report that a controller connected or left.
    public static func event(_ report: [UInt8]) -> Event? {
        guard report.count >= 2, wirelessReports.contains(report[0]) else { return nil }
        switch report[1] { case 1: return .disconnected; case 2: return .connected; default: return nil }
    }

    // MARK: Reports out

    /// Feature report 1: desktop mode ("lizard mode") off and raw motion on, as SDL sends it: 64 bytes with the
    /// report number (SDL's buffer is HID_FEATURE_REPORT_BYTES long and starts with it).
    public static var keepAlive: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 1
        bytes[1] = 0x87; bytes[2] = 6                     // set settings: two of three bytes
        bytes[3] = 9; bytes[4] = 0; bytes[5] = 0          // lizard mode off
        bytes[6] = 48; bytes[7] = 0x18; bytes[8] = 0      // IMU: raw accelerometer and gyro
        return bytes
    }
    /// The original controller's haptic pulse (feature report 0x8f: side, on µs, off µs, repeats) as this
    /// controller's output report 0x81, which carries the same fields.
    public static func pulse(fromOriginal bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 9, bytes[0] == 0x8f, bytes[1] == 7 else { return nil }
        return [0x81] + Array(bytes[2..<9])
    }
    /// Output report 0x80: the grips' rumble motors, low and high frequency 0…65535. The controller stops after
    /// about 50 ms, so it is sent again every 40 ms while it should go on.
    public static func rumble(low: UInt16, high: UInt16) -> [UInt8] {
        [0x80, 0, 0, 0, UInt8(low & 255), UInt8(low >> 8), 0, UInt8(high & 255), UInt8(high >> 8), 0]
    }
}
