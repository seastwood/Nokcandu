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
    case eightBitDo(product: Int), stadia, lunaUSB, lunaBluetooth

    public static func find(vendor: Int, product: Int) -> ReportPadDriver? {
        switch (vendor, product) {
        case (EightBitDoController.vendor, let p) where EightBitDoController.products.contains(p): return .eightBitDo(product: p)
        case (0x18D1, 0x9400): return .stadia
        case (0x1949, 0x0419): return .lunaUSB
        case (0x0171, 0x0419): return .lunaBluetooth
        default: return nil
        }
    }
    /// Every (vendor, product) handled, for device matching.
    public static var matching: [(vendor: Int, product: Int)] {
        EightBitDoController.products.map { (EightBitDoController.vendor, $0) } + [(0x18D1, 0x9400), (0x1949, 0x0419), (0x0171, 0x0419)]
    }

    public var name: String {
        switch self {
        case .eightBitDo(let p): return EightBitDoController.names[p] ?? "8BitDo Controller"
        case .stadia: return "Google Stadia Controller"
        case .lunaUSB, .lunaBluetooth: return "Amazon Luna Controller"
        }
    }
    /// A feature report to read (get) once at start, which some controllers need before they send everything.
    public var enableFeature: UInt8? {
        if case .eightBitDo(let p) = self { return EightBitDoController.enableFeature(product: p) }
        return nil
    }
    /// The output report for rumble at these strengths (0…1), or nil when it has none.
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
        }
    }
}

/// One controller's decoder (some keep a little state between reports).
public struct ReportPadDecoder {
    public let driver: ReportPadDriver
    private var guide = false
    public init(_ driver: ReportPadDriver) { self.driver = driver }

    public mutating func decode(_ d: [UInt8]) -> ReportPadState? {
        switch driver {
        case .eightBitDo: return EightBitDoController.decode(d)
        case .stadia: return Self.stadia(d)
        case .lunaUSB: return d.count == 10 ? Self.lunaUSB(d) : nil
        case .lunaBluetooth:
            if d.count >= 2, d[0] == 0x02 { guide = d[1] & 0x01 != 0; return nil }   // Home has a report of its own
            guard var s = Self.lunaBluetooth(d) else { return nil }
            if guide { s.buttons.insert(.guide) }
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
