import Foundation

/// Wii Remotes (alone, with a Nunchuk or with a Classic Controller) and the Wii U Pro Controller, by Bluetooth
/// (057E:0306, 0330). They need a conversation: the extension is reset and identified, then the controller is told
/// which report to send. Protocol from SDL's driver (SDL_hidapi_wii.c); Motion Plus and the IR camera aren't used.
public struct WiiController {
    public static let vendor = 0x057E
    public static let products: Set<Int> = [0x0306, 0x0330]

    public enum Extension: Equatable { case none, nunchuk, classic, wiiUPro, unknown }
    public private(set) var ext: Extension? = nil
    private enum Stage { case reset1, reset2, identify, running }
    private var stage = Stage.reset1
    private var sticks = [Calibration](repeating: Calibration(min: 0, max: 0, deadzone: 0), count: 4)
    private var outputs: [[UInt8]] = []
    public var name: String {
        switch ext {
        case .wiiUPro?: return "Wii U Pro Controller"
        case .classic?: return "Wii Remote + Classic Controller"
        case .nunchuk?: return "Wii Remote + Nunchuk"
        default: return "Wii Remote"
        }
    }
    public init() {}

    /// What to send at start: reset the extension (step one of identifying it).
    public mutating func start() -> [[UInt8]] { stage = .reset1; return [Self.write(0xA400F0, [0x55])] }
    /// Reports to send now, from what came in.
    public mutating func takeOutputs() -> [[UInt8]] { defer { outputs = [] }; return outputs }

    static func write(_ address: Int, _ data: [UInt8]) -> [UInt8] {
        var r: [UInt8] = [0x16, 0x04, UInt8(address >> 16 & 0xFF), UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF), UInt8(data.count)] + data
        r += [UInt8](repeating: 0, count: max(0, 22 - r.count))
        return r
    }
    static func read(_ address: Int, _ size: Int) -> [UInt8] {
        [0x17, 0x04, UInt8(address >> 16 & 0xFF), UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF), UInt8(size >> 8), UInt8(size & 0xFF)]
    }
    var reportType: UInt8 {
        switch ext { case .wiiUPro?: return 0x3D; case .nunchuk?, .classic?: return 0x32; default: return 0x30 }
    }
    /// Continuous reporting of the report this extension needs.
    var reportingMode: [UInt8] { [0x12, 0x04, reportType] }
    public static let playerOneLight: [UInt8] = [0x11, 0x10]
    public static func rumble(_ on: Bool) -> [UInt8] { [0x10, on ? 0x01 : 0x00] }

    struct Calibration {
        var min: Int, max: Int, deadzone: Int, centre = 0
        /// −32767…32767 (centred on the first reading, the range growing as it's used), as SDL does.
        mutating func value(_ v: Int) -> Int {
            if centre == 0 { centre = v; return 0 }
            min = Swift.min(min, v); max = Swift.max(max, v)
            if v < centre - deadzone {
                let zero = centre - deadzone
                return -Int(Double(zero - v) / Double(Swift.max(1, zero - min)) * 32767)
            }
            if v > centre + deadzone {
                let zero = centre + deadzone
                return Int(Double(v - zero) / Double(Swift.max(1, max - zero)) * 32767)
            }
            return 0
        }
    }
    mutating func calibrate() {
        switch ext {
        case .wiiUPro?: sticks = (0..<4).map { _ in Calibration(min: 1000, max: 3000, deadzone: 100) }
        case .classic?: sticks = (0..<4).map { i in i < 2 ? Calibration(min: 9, max: 54, deadzone: 4) : Calibration(min: 5, max: 26, deadzone: 2) }
        case .nunchuk?: sticks = (0..<4).map { _ in Calibration(min: 40, max: 215, deadzone: 10) }
        default: break
        }
    }

    public mutating func decode(_ d: [UInt8]) -> ReportPadState? {
        guard let id = d.first else { return nil }
        switch id {
        case 0x22:                                              // acknowledge
            guard d.count >= 5, d[3] == 0x16 else { return base(d) }
            if stage == .reset1 { stage = .reset2; outputs.append(Self.write(0xA400FB, [0x00])) }
            else if stage == .reset2 { stage = .identify; outputs.append(Self.read(0xA400FE, 2)) }
            return base(d)
        case 0x21:                                              // memory read
            if stage == .identify, d.count >= 8, d[4] == 0x00, d[5] == 0xFE {
                let error = d[3] & 0x0F
                if error == 7 { ext = Extension.none }
                else if error == 0 {
                    switch Int(d[6]) << 8 | Int(d[7]) {
                    case 0x2E2E: ext = Extension.none
                    case 0x0000: ext = .nunchuk
                    case 0x0101: ext = .classic
                    case 0x0120: ext = .wiiUPro
                    default: ext = .unknown
                    }
                } else { ext = .unknown }
                stage = .running
                calibrate()
                outputs.append(reportingMode); outputs.append(Self.playerOneLight)
            }
            return base(d)
        case 0x20:                                              // status: the extension may have changed
            guard d.count >= 4 else { return nil }
            let has = d[3] & 0x02 != 0
            if stage == .running, let ext, has != (ext != .none) { outputs.append(contentsOf: start()) }
            else if stage == .running { outputs.append(reportingMode) }
            return base(d)
        case 0x30...0x3F:
            guard stage == .running else { return nil }
            if id != reportType { outputs.append(reportingMode) }
            switch id {
            case 0x30, 0x31, 0x33: return base(d)
            case 0x32: return withExtension(d, Array(d.dropFirst(3).prefix(8)))
            case 0x34: return withExtension(d, Array(d.dropFirst(3).prefix(19)))
            case 0x35: return withExtension(d, Array(d.dropFirst(6).prefix(16)))
            case 0x3D: return wiiUPro(Array(d.dropFirst(1).prefix(21)))
            default: return nil
            }
        default: return nil
        }
    }

    /// The Wii Remote's own buttons, mapped as SDL maps a remote used as the whole controller.
    func remoteButtons(_ d: [UInt8]) -> Set<PadProfiles.Input> {
        guard d.count >= 3 else { return [] }
        var held = ReportPadDecoder.bits(d[1], [(0x01, .left), (0x02, .right), (0x04, .down), (0x08, .up), (0x10, .start)])
        held.formUnion(ReportPadDecoder.bits(d[2], [(0x01, .y), (0x02, .x), (0x04, .a), (0x08, .b), (0x10, .back), (0x80, .guide)]))
        return held
    }
    func base(_ d: [UInt8]) -> ReportPadState? {
        guard ext != .wiiUPro, ext != .classic, d.count >= 3 else { return nil }
        return ReportPadState(buttons: remoteButtons(d), axes: [:])
    }
    mutating func withExtension(_ d: [UInt8], _ e: [UInt8]) -> ReportPadState? {
        guard e.count >= 6, !e.allSatisfy({ $0 == 0xFF }) else { return base(d) }
        switch ext {
        case .nunchuk?:
            var held = remoteButtons(d)
            if e[5] & 0x02 == 0 { held.insert(.lb) }            // C
            let z = e[5] & 0x01 == 0
            let x = sticks[0].value(Int(e[0])), y = sticks[1].value(Int(e[1]))
            return ReportPadState(buttons: held, axes: [0: x, 1: -y, 4: z ? 32767 : 0])
        case .classic?:
            // Buttons are active-low; by position, as SDL maps them.
            var held = Set<PadProfiles.Input>()
            let row0: [(UInt8, PadProfiles.Input)] = [(0x02, .rb), (0x04, .start), (0x08, .guide), (0x10, .back), (0x20, .lb), (0x40, .down), (0x80, .right)]
            let row1: [(UInt8, PadProfiles.Input)] = [(0x01, .up), (0x02, .left), (0x08, .y), (0x10, .b), (0x20, .x), (0x40, .a)]
            for (b, i) in row0 where e[4] & b == 0 { held.insert(i) }
            for (b, i) in row1 where e[5] & b == 0 { held.insert(i) }
            let lx = Int(e[0] & 0x3F), ly = Int(e[1] & 0x3F)
            let rx = Int(e[2] >> 7) | Int((e[1] >> 5) & 0x06) | Int((e[0] >> 3) & 0x18), ry = Int(e[2] & 0x1F)
            return ReportPadState(buttons: held, axes: [0: sticks[0].value(lx), 1: -sticks[1].value(ly), 2: sticks[2].value(rx), 3: -sticks[3].value(ry),
                                                        4: e[5] & 0x80 == 0 ? 32767 : 0, 5: e[5] & 0x04 == 0 ? 32767 : 0])
        default: return base(d)
        }
    }
    mutating func wiiUPro(_ e: [UInt8]) -> ReportPadState? {
        guard e.count >= 11, ext == .wiiUPro else { return nil }
        var held = Set<PadProfiles.Input>()
        let row0: [(UInt8, PadProfiles.Input)] = [(0x02, .rb), (0x04, .start), (0x08, .guide), (0x10, .back), (0x20, .lb), (0x40, .down), (0x80, .right)]
        let row1: [(UInt8, PadProfiles.Input)] = [(0x01, .up), (0x02, .left), (0x08, .y), (0x10, .b), (0x20, .x), (0x40, .a)]
        let row2: [(UInt8, PadProfiles.Input)] = [(0x01, .rs), (0x02, .ls)]
        for (b, i) in row0 where e[8] & b == 0 { held.insert(i) }
        for (b, i) in row1 where e[9] & b == 0 { held.insert(i) }
        for (b, i) in row2 where e[10] & b == 0 { held.insert(i) }
        func u16(_ i: Int) -> Int { Int(e[i]) | Int(e[i + 1]) << 8 }
        // Stick order in the report: left x, right x, left y, right y.
        let lx = sticks[0].value(u16(0)), rx = sticks[1].value(u16(2)), ly = sticks[2].value(u16(4)), ry = sticks[3].value(u16(6))
        return ReportPadState(buttons: held, axes: [0: lx, 1: -ly, 2: rx, 3: -ry,
                                                    4: e[9] & 0x80 == 0 ? 32767 : 0, 5: e[9] & 0x04 == 0 ? 32767 : 0])
    }
}
