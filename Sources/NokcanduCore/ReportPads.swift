import Foundation

/// A controller read straight from its own HID reports (ReportPadDriver).
public struct ReportPadState: Equatable {
    public var buttons: Set<PadProfiles.Input>
    /// SDL's order, y down; triggers 0…32767.
    public var axes: [Int: Int]
    /// In Nokcandu's axes: gyro rad/s, acceleration g; nil when the report has none.
    public var gyro: [Float]?, acceleration: [Float]?
    public init(buttons: Set<PadProfiles.Input>, axes: [Int: Int], gyro: [Float]? = nil, acceleration: [Float]? = nil) {
        self.buttons = buttons; self.axes = axes; self.gyro = gyro; self.acceleration = acceleration
    }
}

/// Controllers whose own reports carry more than their generic HID description lets macOS see (extra buttons,
/// motion, rumble): each driver's decoder, start-up and rumble, from SDL's HIDAPI drivers.
public enum ReportPadDriver: Equatable {
    case eightBitDo(product: Int), stadia, lunaUSB, lunaBluetooth, sinput, zuiki(product: Int), horiSteam, gameSir, shield(product: Int), wii, ps4, ps5

    public static func find(vendor: Int, product: Int) -> ReportPadDriver? {
        switch (vendor, product) {
        case (EightBitDoController.vendor, let p) where EightBitDoController.products.contains(p): return .eightBitDo(product: p)
        case (0x18D1, 0x9400): return .stadia
        case (0x1949, 0x0419): return .lunaUSB
        case (0x0171, 0x0419): return .lunaBluetooth
        case (0x2E8A, let p) where SInput.raspberryPiProducts.contains(p): return .sinput
        case (0x38D2, 0x1014): return .sinput
        case (0x33DD, let p) where Zuiki.names[p] != nil: return .zuiki(product: p)
        case (0x0F0D, 0x01AB), (0x0F0D, 0x0196): return .horiSteam
        case (0x3537, 0x10B8), (0x3537, 0x103C): return .gameSir
        case (0x0955, let p) where p == 0x7210 || p == 0x7214: return .shield(product: p)
        case (WiiController.vendor, let p) where WiiController.products.contains(p): return .wii
        case let (v, p) where PlayStationPad.ps4.contains(PlayStationPad.key(v, p)): return .ps4
        case let (v, p) where PlayStationPad.ps5.contains(PlayStationPad.key(v, p)): return .ps5
        default: return nil
        }
    }
    /// Every (vendor, product) handled, for device matching.
    public static var matching: [(vendor: Int, product: Int)] {
        EightBitDoController.products.map { (EightBitDoController.vendor, $0) } + [(0x18D1, 0x9400), (0x1949, 0x0419), (0x0171, 0x0419)]
            + SInput.raspberryPiProducts.map { (0x2E8A, $0) } + [(0x38D2, 0x1014)] + Zuiki.names.keys.map { (0x33DD, $0) }
            + [(0x0F0D, 0x01AB), (0x0F0D, 0x0196), (0x3537, 0x10B8), (0x3537, 0x103C), (0x0955, 0x7210), (0x0955, 0x7214)]
            + WiiController.products.map { (WiiController.vendor, $0) }
            + PlayStationPad.ps4.union(PlayStationPad.ps5).map { ($0 >> 16, $0 & 0xFFFF) }
    }

    public var name: String {
        switch self {
        case .eightBitDo(let p): return EightBitDoController.names[p] ?? "8BitDo Controller"
        case .stadia: return "Google Stadia Controller"
        case .lunaUSB, .lunaBluetooth: return "Amazon Luna Controller"
        case .sinput: return "SInput Controller"
        case .zuiki(let p): return Zuiki.names[p] ?? "ZUIKI Controller"
        case .horiSteam: return "Wireless HORIPAD for Steam"
        case .gameSir: return "GameSir 8K Controller"
        case .shield: return "NVIDIA SHIELD Controller"
        case .wii: return "Wii Remote"
        case .ps4: return "PlayStation 4 Controller"
        case .ps5: return "PlayStation 5 Controller"
        }
    }
    /// A feature report to read (get) once at start, which some controllers need before they send everything.
    public var enableFeature: UInt8? {
        if case .eightBitDo(let p) = self { return EightBitDoController.enableFeature(product: p) }
        return nil
    }
    /// An output report to send once at start (SInput: ask for its features, which answer with its motion ranges).
    public var startOutput: [UInt8]? {
        if case .sinput = self { return SInput.command(0x02, []) }
        if case .gameSir = self { return Self.gameSirCommand([0x01, 0x00]) }      // its full ("SDL") mode
        return nil
    }
    /// The output report for rumble at these strengths (0…1), or nil when it has none. A first byte of 0 is "no
    /// report ID" (not sent), as with hidapi.
    public func rumble(low: Double, high: Double) -> [UInt8]? {
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
        switch self {
        case .eightBitDo: return EightBitDoController.rumble(low: byte(low), high: byte(high))
        case .stadia:
            let l = UInt16(max(0, min(1, low)) * 65535), h = UInt16(max(0, min(1, high)) * 65535)
            return [0x05, UInt8(l & 0xFF), UInt8(l >> 8), UInt8(h & 0xFF), UInt8(h >> 8)]
        case .lunaBluetooth:
            return [0x03, 0x0F, 0x00, 0x00, UInt8(max(0, min(1, low)) * 100), UInt8(max(0, min(1, high)) * 100), 0xFF, 0x00, 0xEB]
        case .lunaUSB: return nil
        case .sinput: return SInput.command(0x01, [2, byte(low), 0, byte(high), 0])
        case .zuiki(let p): return p == 0x0020 ? nil : [0, 0, 0, 0, byte(low), byte(high), 0, 0]
        case .horiSteam: return nil
        case .gameSir: return Self.gameSirCommand([0x03, byte(low), byte(high)])
        case .shield(let p): return p == 0x7210 ? [0x01, 0x00, byte(low), 0x00, byte(high), 0x00, 0x00] : nil
        case .wii: return WiiController.rumble(max(low, high) > 0.2)
        case .ps4:
            var r = [UInt8](repeating: 0, count: 32); r[0] = 0x05; r[1] = 0x01; r[4] = byte(high); r[5] = byte(low); return r
        case .ps5:
            var r = [UInt8](repeating: 0, count: 48); r[0] = 0x02; r[1] = 0x03; r[3] = byte(high); r[4] = byte(low); return r
        }
    }
    static func gameSirCommand(_ body: [UInt8]) -> [UInt8] { [0xA2] + body + [UInt8](repeating: 0, count: 63 - body.count) }
}

/// One controller's decoder (some keep a little state between reports).
public struct ReportPadDecoder {
    public let driver: ReportPadDriver
    private var guide = false
    private var sinput = SInput.Features()
    private var touchClick = false
    private var wii = WiiController()
    /// The name to show: the driver's, or for a Wii controller what's attached to it.
    public var name: String { driver == .wii ? wii.name : driver.name }
    /// Reports to send at start (beyond the driver's fixed `startOutput`).
    public mutating func start() -> [[UInt8]] { driver == .wii ? wii.start() : [] }
    /// Reports the last decoded input calls for.
    public mutating func takeOutputs() -> [[UInt8]] { driver == .wii ? wii.takeOutputs() : [] }
    public init(_ driver: ReportPadDriver) { self.driver = driver }

    public mutating func decode(_ d: [UInt8]) -> ReportPadState? {
        switch driver {
        case .eightBitDo(let p): return EightBitDoController.decode(d, product: p)
        case .stadia: return Self.stadia(d)
        case .lunaUSB: return d.count == 10 ? Self.lunaUSB(d) : nil
        case .lunaBluetooth:
            if d.count >= 2, d[0] == 0x02 { guide = d[1] & 0x01 != 0; return nil }   // Home has a report of its own
            guard var s = Self.lunaBluetooth(d) else { return nil }
            if guide { s.buttons.insert(.guide) }
            return s
        case .sinput:
            if let f = SInput.features(d) { sinput = f; return nil }
            return SInput.decode(d, sinput)
        case .zuiki(let p): return p == 0x0017 ? Zuiki.bluetooth(d) : Zuiki.usb(d)
        case .horiSteam: return Self.horiSteam(d)
        case .gameSir: return Self.gameSir(d)
        case .wii: return wii.decode(d)
        case .ps4: return PlayStationPad.ps4Report(d)
        case .ps5: return PlayStationPad.ps5Report(d)
        case .shield:
            if d.count >= 2, d[0] == 0x02 { touchClick = d[1] & 0x01 != 0; return nil }   // the touchpad's report
            guard var s = Self.shield(d) else { return nil }
            if touchClick { s.buttons.insert(.touchpad) }
            return s
        }
    }

    static func bits(_ v: UInt8, _ list: [(UInt8, PadProfiles.Input)]) -> Set<PadProfiles.Input> {
        Set(list.filter { v & $0.0 != 0 }.map(\.1))
    }
    /// A stick byte centred on `centre`, as −32767…32767.
    static func stick(_ v: UInt8, centre: Int) -> Int {
        let x = Int(v) - centre
        if x == 0 { return 0 }
        return max(-32767, min(32767, x < 0 ? x * 32767 / max(1, centre) : x * 32767 / max(1, 255 - centre)))
    }
    static func trigger(_ v: UInt8) -> Int { Int(v) * 32767 / 255 }

    /// HORI's Wireless HORIPAD for Steam (SDL_hidapi_steam_hori.c): back buttons M1/M2 and FL/FR, Quick Access,
    /// touch-sensing sticks and a gyro.
    static func horiSteam(_ d: [UInt8]) -> ReportPadState? {
        guard d.count >= 24, d[0] == 0x07 || d[0] == 0x00 else { return nil }
        var held = EightBitDoController.hat(d[5] & 0x0F)
        held.formUnion(bits(d[5], [(0x10, .a), (0x20, .b), (0x40, .misc), (0x80, .x)]))
        held.formUnion(bits(d[6], [(0x01, .y), (0x02, .paddle2), (0x04, .lb), (0x08, .rb), (0x40, .back), (0x80, .start)]))
        held.formUnion(bits(d[7], [(0x01, .guide), (0x02, .ls), (0x04, .rs), (0x08, .paddle1), (0x10, .lstouch), (0x20, .rstouch),
                                   (0x40, .paddle3), (0x80, .paddle4)]))
        func s16(_ i: Int) -> Float { Float(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
        // SDL's gyro is (−16, −12, −14) of the report's, its acceleration (22, −20, 18); Nokcandu's axes (SDL's x,
        // z, y) then (−16, −14, −12) and (22, 18, −20). ±2048 °/s and ±8 g over the Int16 range.
        let g = Float(2048.0 * Double.pi / 180 / 32767), a = Float(8.0 / 32768)
        return ReportPadState(buttons: held,
                              axes: [0: stick(d[1], centre: 0x80), 1: stick(d[2], centre: 0x80),
                                     2: stick(d[3], centre: 0x80), 3: stick(d[4], centre: 0x80),
                                     4: trigger(d[9]), 5: trigger(d[8])],
                              gyro: [-s16(16) * g, -s16(14) * g, -s16(12) * g], acceleration: [s16(22) * a, s16(18) * a, -s16(20) * a])
    }
    /// GameSir G7 Pro 8K and Tarantula 8K in their full mode (SDL_hidapi_gamesir.c): back buttons L4/R4 and L5/R5,
    /// Share, gyro. The other reports (its plain modes) are left to the generic mapping.
    static func gameSir(_ r: [UInt8]) -> ReportPadState? {
        let d: ArraySlice<UInt8>
        if r.count >= 3, r[0] == 0x43, r[1] == 0xA1, r[2] == 0xC8 { d = r[3...] }
        else if r.count >= 2, r[0] == 0xA1, r[1] == 0xC8 { d = r[2...] }
        else { return nil }
        let p = Array(d)
        guard p.count >= 14 else { return nil }
        let h = p[2] & 0x0F
        var held = (1...8).contains(h) ? EightBitDoController.hat(h - 1) : []
        held.formUnion(bits(p[0], [(0x01, .a), (0x02, .b), (0x08, .x), (0x10, .y), (0x40, .lb), (0x80, .rb)]))
        held.formUnion(bits(p[1], [(0x04, .back), (0x08, .start), (0x10, .guide), (0x20, .ls), (0x40, .rs), (0x80, .misc)]))
        held.formUnion(bits(p[2], [(0x40, .paddle2), (0x80, .paddle1)]))
        held.formUnion(bits(p[3], [(0x01, .paddle4), (0x02, .paddle3)]))
        func be(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(p[i]) << 8 | UInt16(p[i + 1]))) }
        func flip(_ v: Int) -> Int { v == -32768 ? 32767 : -v }
        var gyro: [Float]?, accel: [Float]?
        if p.count >= 26 {
            // SDL's axes are the report's own; Nokcandu's (SDL's x, z, y). 1/16 °/s per unit; ±4 g.
            let g = Float(Double.pi / 180 / 16), a = Float(4.0 / 32768)
            gyro = [Float(be(20)) * g, Float(be(24)) * g, Float(be(22)) * g]
            accel = [Float(be(14)) * a, Float(be(18)) * a, Float(be(16)) * a]
            if gyro == [0, 0, 0], accel == [0, 0, 0] { gyro = nil; accel = nil }
        }
        return ReportPadState(buttons: held, axes: [0: max(-32767, be(4)), 1: flip(be(6)), 2: max(-32767, be(8)), 3: flip(be(10)),
                                                    4: trigger(p[12]), 5: trigger(p[13])],
                              gyro: gyro, acceleration: accel)
    }
    /// NVIDIA SHIELD controllers (SDL_hidapi_shield.c): the 2015 one (v1.03, 16-byte report; + and − as paddles,
    /// touchpad click) and the 2017 one (v1.04).
    static func shield(_ d: [UInt8]) -> ReportPadState? {
        guard d.count >= 16, d[0] == 0x01 else { return nil }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        func stick(_ i: Int) -> Int { max(-32767, u16(i) - 0x8000) }
        let face: [(UInt8, PadProfiles.Input)] = [(0x01, .a), (0x02, .b), (0x04, .x), (0x08, .y), (0x10, .lb), (0x20, .rb), (0x40, .ls), (0x80, .rs)]
        if d.count == 16 {
            var held = EightBitDoController.hat(d[3])
            held.formUnion(bits(d[1], face))
            held.formUnion(bits(d[2], [(0x02, .start), (0x08, .paddle1), (0x10, .paddle2), (0x40, .back), (0x80, .guide)]))
            return ReportPadState(buttons: held, axes: [0: stick(4), 1: stick(6), 2: stick(8), 3: stick(10), 4: u16(12) / 2, 5: u16(14) / 2])
        }
        guard d.count >= 23 else { return nil }
        var held = EightBitDoController.hat(d[2])
        held.formUnion(bits(d[3], face))
        held.formUnion(bits(d[4], [(0x01, .start)]))
        held.formUnion(bits(d[17], [(0x01, .guide), (0x02, .back)]))
        return ReportPadState(buttons: held, axes: [0: stick(9), 1: stick(11), 2: stick(13), 3: stick(15), 4: u16(19) / 2, 5: u16(21) / 2])
    }
    /// Google Stadia Controller (SDL_hidapi_stadia.c): report 3; Capture and Assistant as Share and a paddle.
    static func stadia(_ d: [UInt8]) -> ReportPadState? {
        guard d.count >= 10, d[0] == 0x03 else { return nil }
        var held = EightBitDoController.hat(d[1])
        held.formUnion(bits(d[2], [(0x40, .back), (0x10, .guide), (0x20, .start), (0x80, .rs), (0x01, .misc), (0x02, .paddle1)]))
        held.formUnion(bits(d[3], [(0x40, .a), (0x20, .b), (0x10, .x), (0x08, .y), (0x04, .lb), (0x02, .rb), (0x01, .ls)]))
        return ReportPadState(buttons: held, axes: [0: stick(d[4], centre: 0x80), 1: stick(d[5], centre: 0x80),
                                                    2: stick(d[6], centre: 0x80), 3: stick(d[7], centre: 0x80),
                                                    4: trigger(d[8]), 5: trigger(d[9])])
    }
    /// Amazon Luna Controller by USB (SDL_hidapi_luna.c): a 10-byte report; the microphone button as Share.
    static func lunaUSB(_ d: [UInt8]) -> ReportPadState {
        var held = EightBitDoController.hat(d[3] & 0x0F)
        held.formUnion(bits(d[1], [(0x01, .a), (0x02, .b), (0x04, .x), (0x08, .y), (0x10, .lb), (0x20, .rb), (0x40, .back), (0x80, .start)]))
        held.formUnion(bits(d[2], [(0x01, .guide), (0x02, .misc), (0x04, .ls), (0x08, .rs)]))
        return ReportPadState(buttons: held, axes: [0: stick(d[4], centre: 0x7F), 1: stick(d[5], centre: 0x7F),
                                                    2: stick(d[6], centre: 0x7F), 3: stick(d[7], centre: 0x7F),
                                                    4: trigger(d[8]), 5: trigger(d[9])])
    }
    /// Amazon Luna Controller by Bluetooth: report 1, d-pad 1…8, 10-bit triggers.
    static func lunaBluetooth(_ d: [UInt8]) -> ReportPadState? {
        guard d.count >= 17, d[0] == 0x01 else { return nil }
        let h = d[13] & 0x0F
        var held = (1...8).contains(h) ? EightBitDoController.hat(h - 1) : []
        held.formUnion(bits(d[14], [(0x01, .a), (0x02, .b), (0x08, .x), (0x10, .y), (0x40, .lb), (0x80, .rb)]))
        held.formUnion(bits(d[15], [(0x08, .start), (0x20, .ls), (0x40, .rs)]))
        held.formUnion(bits(d[16], [(0x01, .back), (0x02, .misc)]))
        func t10(_ i: Int) -> Int { ((Int(d[i]) | Int(d[i + 1]) << 8) & 0x3FF) * 32767 / 1023 }
        return ReportPadState(buttons: held, axes: [0: stick(d[2], centre: 0x7F), 1: stick(d[4], centre: 0x7F),
                                                    2: stick(d[6], centre: 0x7F), 3: stick(d[8], centre: 0x7F),
                                                    4: t10(9), 5: t10(11)])
    }
}

/// SInput, Handheld Legend's open controller protocol (GP2040-CE and others; SDL_hidapi_sinput.c): fixed button
/// bits, 16-bit sticks and triggers, motion with ranges the controller states, and rumble.
public enum SInput {
    public static let raspberryPiProducts: Set<Int> = [0x10C6, 0x10DF, 0x10DD, 0x10E0, 0x10E5]
    public struct Features: Equatable {
        public var gyroRange = 2000, accelRange = 8          // °/s and g, either way
        public var leftTrigger = true, rightTrigger = true
    }
    /// A command (output report 3), padded to its 48 bytes.
    static func command(_ id: UInt8, _ body: [UInt8]) -> [UInt8] {
        var r: [UInt8] = [0x03, id] + body
        r += [UInt8](repeating: 0, count: max(0, 48 - r.count))
        return r
    }
    /// The answer to the features command (report 2, command 2).
    static func features(_ d: [UInt8]) -> Features? {
        guard d.count >= 14, d[0] == 0x02, d[1] == 0x02 else { return nil }
        var f = Features()
        let g = Int(d[12]) | Int(d[13]) << 8, a = Int(d[10]) | Int(d[11]) << 8
        if g > 0 { f.gyroRange = g }
        if a > 0 { f.accelRange = a }
        f.leftTrigger = d[4] & 0x40 != 0; f.rightTrigger = d[4] & 0x80 != 0
        return f
    }
    static func decode(_ d: [UInt8], _ f: Features) -> ReportPadState? {
        guard d.count >= 35, d[0] == 0x01 else { return nil }
        let order: [PadProfiles.Input?] = [.b, .a, .y, .x, .up, .down, .left, .right, .ls, .rs, .lb, .rb, nil, nil,
                                           .paddle2, .paddle1, .start, .back, .guide, .misc, .paddle4, .paddle3, .touchpad, .touchpad]
        let bits = UInt32(d[3]) | UInt32(d[4]) << 8 | UInt32(d[5]) << 16 | UInt32(d[6]) << 24
        var held = Set<PadProfiles.Input>()
        for (i, input) in order.enumerated() where bits & (1 << UInt32(i)) != 0 { if let input { held.insert(input) } }
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
        func stick(_ i: Int) -> Int { max(-32767, s16(i)) }
        func trigger(_ i: Int, analog: Bool, digital: Bool) -> Int {
            max(analog ? (s16(i) + 32768) / 2 : 0, digital ? 32767 : 0)
        }
        let axes = [0: stick(7), 1: stick(9), 2: stick(11), 3: stick(13),
                    4: trigger(15, analog: f.leftTrigger, digital: bits & (1 << 12) != 0),
                    5: trigger(17, analog: f.rightTrigger, digital: bits & (1 << 13) != 0)]
        // SDL's axes are (−x, z, −y) of the controller's; Nokcandu's (SDL's x, z, y) are then (−x, −y, z).
        let g = Float(Double(f.gyroRange) * Double.pi / 180 / 32768), a = Float(f.accelRange) / 32768
        let gx = Float(s16(29)), gy = Float(s16(31)), gz = Float(s16(33))
        let ax = Float(s16(23)), ay = Float(s16(25)), az = Float(s16(27))
        var gyro: [Float]? = [-gx * g, -gy * g, gz * g], accel: [Float]? = [-ax * a, -ay * a, az * a]
        if gyro == [0, 0, 0], accel == [0, 0, 0] { gyro = nil; accel = nil }
        return ReportPadState(buttons: held, axes: axes, gyro: gyro, acceleration: accel)
    }
}

/// ZUIKI's controllers (SDL_hidapi_zuiki.c): the EVOTOP (gyro on its PC and 2.4 GHz modes and some Bluetooth
/// firmware), the EVOTOP AXIS and the MASCON PRO, in their D-input modes.
public enum Zuiki {
    public static let names: [Int: String] = [0x0006: "ZUIKI MASCON PRO", 0x001C: "ZUIKI EVOTOP", 0x001D: "ZUIKI EVOTOP",
                                              0x0017: "ZUIKI EVOTOP", 0x0020: "ZUIKI EVOTOP AXIS"]
    static func s16(_ d: [UInt8], _ i: Int) -> Float { Float(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
    /// Gyro ±1024 °/s and acceleration ±8 g over the Int16 range. SDL's axes are (x, z, −y) of these; Nokcandu's
    /// (SDL's x, z, y) then (x, −y, z).
    static func motion(_ d: [UInt8], gyro gi: Int, accel ai: Int) -> ([Float]?, [Float]?) {
        guard d.count >= ai + 6 else { return (nil, nil) }
        let g = Float(1024.0 * Double.pi / 180 / 32768), a = Float(8.0 / 32768)
        let gyro = [s16(d, gi) * g, -s16(d, gi + 2) * g, s16(d, gi + 4) * g]
        let accel = [s16(d, ai) * a, -s16(d, ai + 2) * a, s16(d, ai + 4) * a]
        return gyro == [0, 0, 0] && accel == [0, 0, 0] ? (nil, nil) : (gyro, accel)
    }
    /// By USB or its 2.4 GHz receiver: no report ID; the d-pad as a hat in byte 2.
    static func usb(_ d: [UInt8]) -> ReportPadState? {
        guard d.count >= 7 else { return nil }
        var held = EightBitDoController.hat(d[2])
        held.formUnion(ReportPadDecoder.bits(d[0], [(0x01, .y), (0x02, .b), (0x04, .a), (0x08, .x), (0x10, .lb), (0x20, .rb)]))
        held.formUnion(ReportPadDecoder.bits(d[1], [(0x01, .back), (0x02, .start), (0x04, .ls), (0x08, .rs), (0x10, .guide), (0x20, .misc)]))
        let (gyro, accel) = motion(d, gyro: 8, accel: 14)
        return ReportPadState(buttons: held, axes: [0: EightBitDoController.stick(d[3]), 1: EightBitDoController.stick(d[4]),
                                                    2: EightBitDoController.stick(d[5]), 3: EightBitDoController.stick(d[6]),
                                                    4: d[0] & 0x40 != 0 ? 32767 : 0, 5: d[0] & 0x80 != 0 ? 32767 : 0],
                              gyro: gyro, acceleration: accel)
    }
    /// The EVOTOP by Bluetooth: 16-bit sticks, 10-bit triggers, d-pad 1…8.
    static func bluetooth(_ d: [UInt8]) -> ReportPadState? {
        guard d.count >= 16 else { return nil }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        func stick(_ i: Int) -> Int { max(-32767, u16(i) - 32768) }
        func trigger(_ i: Int) -> Int { min(1023, u16(i)) * 32767 / 1023 }
        let h = d[13]
        var held = (1...8).contains(h) ? EightBitDoController.hat(h - 1) : []
        held.formUnion(ReportPadDecoder.bits(d[14], [(0x01, .a), (0x02, .b), (0x08, .x), (0x10, .y), (0x40, .lb), (0x80, .rb)]))
        held.formUnion(ReportPadDecoder.bits(d[15], [(0x04, .back), (0x08, .start), (0x10, .guide), (0x20, .ls), (0x40, .rs)]))
        let (gyro, accel) = motion(d, gyro: 17, accel: 23)
        return ReportPadState(buttons: held, axes: [0: stick(1), 1: stick(3), 2: stick(5), 3: stick(7), 4: trigger(9), 5: trigger(11)],
                              gyro: gyro, acceleration: accel)
    }
}

/// PlayStation 4 and 5 controllers (licensed and compatible ones: HORI, Nacon, Razer, PDP, Mad Catz…) that macOS's
/// own controller support doesn't read: their reports give the gyro, the touchpad's click and, by USB, rumble.
/// IDs from SDL's controller list; layouts from SDL's PS4 and PS5 drivers.
public enum PlayStationPad {
    static func key(_ v: Int, _ p: Int) -> Int { v << 16 | p }
    public static let ps4: Set<Int> = Set([
        (0x0079, 0x181b), (0x046d, 0xc260), (0x044f, 0xd00e), (0x054c, 0x05c4), (0x054c, 0x05c5), (0x054c, 0x09cc), (0x054c, 0x0ba0),
        (0x0738, 0x8250), (0x0738, 0x8384), (0x0738, 0x8480), (0x0738, 0x8481), (0x0c12, 0x0e10), (0x0c12, 0x0e13), (0x0c12, 0x0e15),
        (0x0c12, 0x0e20), (0x0c12, 0x0ef6), (0x0c12, 0x1cf6), (0x0c12, 0x1e10), (0x0c12, 0x2e18), (0x0e6f, 0x0203), (0x0e6f, 0x0207),
        (0x0e6f, 0x020a), (0x0f0d, 0x0055), (0x0f0d, 0x005e), (0x0f0d, 0x0066), (0x0f0d, 0x0084), (0x0f0d, 0x0087), (0x0f0d, 0x008a),
        (0x0f0d, 0x009c), (0x0f0d, 0x00a0), (0x0f0d, 0x00c9), (0x0f0d, 0x00ee), (0x0f0d, 0x011c), (0x0f0d, 0x0123), (0x0f0d, 0x0162),
        (0x11c0, 0x4001), (0x146b, 0x0d01), (0x146b, 0x0d02), (0x146b, 0x0d06), (0x146b, 0x0d08), (0x146b, 0x0d09), (0x146b, 0x0d10),
        (0x146b, 0x0d13), (0x146b, 0x1103), (0x1532, 0x1000), (0x1532, 0x1004), (0x1532, 0x1007), (0x1532, 0x1008), (0x1532, 0x1009),
        (0x1532, 0x100A), (0x1532, 0x1100), (0x20d6, 0x792a), (0x2c22, 0x2000), (0x2c22, 0x2300), (0x2c22, 0x2500), (0x3285, 0x0d16),
        (0x3285, 0x0d17), (0x7545, 0x0104), (0x9886, 0x0025), (0x7545, 0x1122),
    ].map { key($0.0, $0.1) })
    public static let ps5: Set<Int> = Set([
        (0x054c, 0x0ce6), (0x054c, 0x0e5f), (0x0e6f, 0x0209), (0x0f0d, 0x0163), (0x0f0d, 0x0184), (0x0f0d, 0x01b0), (0x1532, 0x100b),
        (0x1532, 0x100c), (0x1532, 0x1012), (0x1532, 0x1024), (0x1532, 0x1026), (0x3285, 0x0d18), (0x3285, 0x0d19), (0x358a, 0x0104),
        (0x358a, 0x0304),
    ].map { key($0.0, $0.1) })

    static let face: [(UInt8, PadProfiles.Input)] = [(0x10, .x), (0x20, .a), (0x40, .b), (0x80, .y)]
    static let shoulders: [(UInt8, PadProfiles.Input)] = [(0x01, .lb), (0x02, .rb), (0x10, .back), (0x20, .start), (0x40, .ls), (0x80, .rs)]
    /// Motion: gyro 1/16 °/s per unit (DS4's usual calibration) and 8192 a g, in SDL's axes, which are these
    /// controllers' own; Nokcandu's (SDL's x, z, y).
    static func motion(_ d: [UInt8], gyro gi: Int, accel ai: Int) -> ([Float]?, [Float]?) {
        guard d.count >= ai + 6 else { return (nil, nil) }
        func s16(_ i: Int) -> Float { Float(Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)) }
        let g = Float(Double.pi / 180 / 16), a = Float(1.0 / 8192)
        let gyro = [s16(gi) * g, s16(gi + 4) * g, s16(gi + 2) * g], accel = [s16(ai) * a, s16(ai + 4) * a, s16(ai + 2) * a]
        return gyro == [0, 0, 0] && accel == [0, 0, 0] ? (nil, nil) : (gyro, accel)
    }
    /// PS4: report 1 by USB (or the short Bluetooth report), report 0x11 (2 bytes further on) by Bluetooth.
    static func ps4Report(_ r: [UInt8]) -> ReportPadState? {
        let o: Int
        if r.first == 0x01, r.count >= 10 { o = 0 } else if r.first == 0x11, r.count >= 12 { o = 2 } else { return nil }
        let d = Array(r.dropFirst(o))
        var held = EightBitDoController.hat(d[5] & 0x0F)
        held.formUnion(ReportPadDecoder.bits(d[5], face))
        held.formUnion(ReportPadDecoder.bits(d[6], shoulders))
        held.formUnion(ReportPadDecoder.bits(d[7], [(0x01, .guide), (0x02, .touchpad)]))
        let (gyro, accel) = d.count >= 25 ? motion(d, gyro: 13, accel: 19) : (nil, nil)
        return ReportPadState(buttons: held, axes: [0: ReportPadDecoder.stick(d[1], centre: 0x80), 1: ReportPadDecoder.stick(d[2], centre: 0x80),
                                                    2: ReportPadDecoder.stick(d[3], centre: 0x80), 3: ReportPadDecoder.stick(d[4], centre: 0x80),
                                                    4: ReportPadDecoder.trigger(d[8]), 5: ReportPadDecoder.trigger(d[9])],
                              gyro: gyro, acceleration: accel)
    }
    /// PS5: report 1 by USB, report 0x31 (1 byte further on) by Bluetooth. The mute button is Share.
    static func ps5Report(_ r: [UInt8]) -> ReportPadState? {
        let o: Int
        if r.first == 0x01, r.count >= 11 { o = 0 } else if r.first == 0x31, r.count >= 12 { o = 1 } else { return nil }
        let d = Array(r.dropFirst(o))
        var held = EightBitDoController.hat(d[8] & 0x0F)
        held.formUnion(ReportPadDecoder.bits(d[8], face))
        held.formUnion(ReportPadDecoder.bits(d[9], shoulders))
        held.formUnion(ReportPadDecoder.bits(d[10], [(0x01, .guide), (0x02, .touchpad), (0x04, .misc)]))
        let (gyro, accel) = d.count >= 28 ? motion(d, gyro: 16, accel: 22) : (nil, nil)
        return ReportPadState(buttons: held, axes: [0: ReportPadDecoder.stick(d[1], centre: 0x80), 1: ReportPadDecoder.stick(d[2], centre: 0x80),
                                                    2: ReportPadDecoder.stick(d[3], centre: 0x80), 3: ReportPadDecoder.stick(d[4], centre: 0x80),
                                                    4: ReportPadDecoder.trigger(d[5]), 5: ReportPadDecoder.trigger(d[6])],
                              gyro: gyro, acceleration: accel)
    }
}
