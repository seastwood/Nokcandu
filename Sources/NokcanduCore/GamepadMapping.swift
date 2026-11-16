import Foundation

/// SDL's controller mapping strings ("GUID,name,a:b0,leftx:a0,dpup:h0.1,…"), for controllers macOS's own
/// controller support doesn't know: their buttons and axes, numbered the way SDL numbers them (`HIDLayout`, which
/// the mappings were made for), become a standard controller's. The mappings come from the community
/// SDL_GameControllerDB (`GameControllerDBData`); a mapping SDL's documentation describes, unchanged:
/// https://wiki.libsdl.org/SDL2/SDL_GameControllerAddMapping
public struct GamepadMapping: Sendable, Equatable {
    public enum Source: Equatable, Sendable {
        case button(Int)
        case hat(Int, mask: Int)
        /// `half`: 0 the whole axis, 1 its positive half, −1 its negative half.
        case axis(Int, half: Int, invert: Bool)
    }
    public enum Target: Equatable, Sendable {
        case input(PadProfiles.Input)
        /// SDL's axis order: 0–3 the sticks (y down), 4 and 5 the triggers. `half` as for a source.
        case axis(Int, half: Int)
    }
    public var name: String
    public var vendorID: Int, productID: Int, version: Int
    public var entries: [(target: Target, source: Source)]
    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.vendorID == b.vendorID && a.productID == b.productID && a.version == b.version
            && a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.target == $1.target && $0.source == $1.source }
    }

    static let buttonNames: [String: PadProfiles.Input] = [
        "a": .a, "b": .b, "x": .x, "y": .y, "back": .back, "guide": .guide, "start": .start,
        "leftstick": .ls, "rightstick": .rs, "leftshoulder": .lb, "rightshoulder": .rb,
        "dpup": .up, "dpdown": .down, "dpleft": .left, "dpright": .right,
        "misc1": .misc, "paddle1": .paddle1, "paddle2": .paddle2, "paddle3": .paddle3, "paddle4": .paddle4, "touchpad": .touchpad,
    ]
    static let axisNames = ["leftx": 0, "lefty": 1, "rightx": 2, "righty": 3, "lefttrigger": 4, "righttrigger": 5]

    /// One line of the database, or nil when it isn't a mapping this reads.
    public init?(line: String) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3, fields[0].count == 32, let guid = Self.bytes(fields[0]) else { return nil }
        func le(_ i: Int) -> Int { Int(guid[i]) | Int(guid[i + 1]) << 8 }
        vendorID = le(4); productID = le(8); version = le(12)
        name = fields[1]
        entries = []
        for field in fields.dropFirst(2) {
            let kv = field.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2, let target = Self.target(kv[0]), let source = Self.source(kv[1]) else { continue }
            entries.append((target, source))
        }
        guard vendorID != 0, !entries.isEmpty else { return nil }
    }
    static func bytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex)
        var out: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }
    static func target(_ s: String) -> Target? {
        var name = s, half = 0
        if name.hasPrefix("+") { half = 1; name.removeFirst() } else if name.hasPrefix("-") { half = -1; name.removeFirst() }
        if let i = buttonNames[name], half == 0 { return .input(i) }
        if let a = axisNames[name] { return .axis(a, half: half) }
        return nil
    }
    static func source(_ s: String) -> Source? {
        var v = s, half = 0, invert = false
        if v.hasPrefix("+") { half = 1; v.removeFirst() } else if v.hasPrefix("-") { half = -1; v.removeFirst() }
        if v.hasSuffix("~") { invert = true; v.removeLast() }
        guard let kind = v.first else { return nil }
        let rest = String(v.dropFirst())
        switch kind {
        case "b": return Int(rest).map { .button($0) }
        case "a": return Int(rest).map { .axis($0, half: half, invert: invert) }
        case "h":
            let p = rest.split(separator: ".")
            guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
            return .hat(h, mask: m)
        default: return nil
        }
    }

    /// The standard controller's state from the device's: buttons pressed, axes −32768…32767 (y down), hat bits
    /// (1 up, 2 right, 4 down, 8 left). Returns the inputs held and all six axes (triggers 0…32767).
    public func state(buttons: [Bool], axes: [Int], hat: Int) -> (buttons: Set<PadProfiles.Input>, axes: [Int: Int]) {
        var held = Set<PadProfiles.Input>()
        var sums = [Int: Int]()
        for a in 0..<6 { sums[a] = 0 }
        func raw(_ s: Source) -> (pressed: Bool, value: Int) {
            switch s {
            case .button(let n): let d = buttons.indices.contains(n) && buttons[n]; return (d, d ? 32767 : 0)
            case .hat(_, let m): let d = hat & m != 0; return (d, d ? 32767 : 0)
            case .axis(let n, let half, let invert):
                var v = axes.indices.contains(n) ? axes[n] : 0
                if invert { v = -v }
                if half == 1 { v = max(0, v) } else if half == -1 { v = max(0, -v) }
                return (half != 0 ? v > 16384 : v > 16384, v)
            }
        }
        for (target, source) in entries {
            let r = raw(source)
            switch target {
            case .input(let i): if r.pressed { held.insert(i) }
            case .axis(let a, let half):
                var out: Int
                let isHalfSource: Bool = { if case .axis(_, let h, _) = source { return h != 0 }; return true }()
                if a >= 4 {
                    // Triggers: 0…32767. A whole axis rests at one end (−32768), a half axis or button at 0.
                    out = isHalfSource ? r.value : (r.value + 32768) / 2
                } else if half != 0 {
                    // Half a stick: a whole axis gives only its positive part.
                    out = half * (isHalfSource ? r.value : max(0, r.value))
                } else {
                    // A whole stick axis from a half axis or a button spans the axis: released −32768, full +32767.
                    out = isHalfSource ? r.value * 2 - 32767 : r.value
                    if case .button = source { out = r.pressed ? 32767 : 0 }
                    if case .hat = source { out = r.pressed ? 32767 : 0 }
                }
                sums[a, default: 0] += out
            }
        }
        var result = [Int: Int]()
        for (a, v) in sums { result[a] = a >= 4 ? min(32767, max(0, v)) : min(32767, max(-32768, v)) }
        return (held, result)
    }

    // MARK: The database

    /// The mappings for macOS, by vendor and product. A line for the exact version wins over others for the same
    /// controller; otherwise the first.
    public static let database: [Int: [GamepadMapping]] = parse(GameControllerDBData.text)
    public static func parse(_ text: String) -> [Int: [GamepadMapping]] {
        var out: [Int: [GamepadMapping]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let m = GamepadMapping(line: String(line)) else { continue }
            out[m.vendorID << 16 | m.productID, default: []].append(m)
        }
        return out
    }
    /// For a gamepad that isn't in the database: the layout most generic USB gamepads use (four face buttons,
    /// shoulders, triggers as buttons, select and start, stick clicks, then the rest), sticks on the first four axes
    /// and the d-pad on the hat. A guess, said so in its name; the controller can still be set button by button.
    public static func guessed(vendor: Int, product: Int, name: String, buttons: Int, axes: Int, hat: Bool) -> GamepadMapping? {
        guard buttons >= 4 else { return nil }
        var parts = ["a:b0", "b:b1", "x:b2", "y:b3"]
        let more = ["leftshoulder", "rightshoulder", "lefttrigger", "righttrigger", "back", "start", "leftstick", "rightstick", "guide"]
        for (i, n) in more.enumerated() where 4 + i < buttons { parts.append("\(n):b\(4 + i)") }
        for (i, n) in ["leftx", "lefty", "rightx", "righty"].enumerated() where i < axes { parts.append("\(n):a\(i)") }
        if hat { parts += ["dpup:h0.1", "dpright:h0.2", "dpdown:h0.4", "dpleft:h0.8"] }
        let guid = String(format: "03000000%02x%02x0000%02x%02x000000000000", vendor & 255, vendor >> 8 & 255, product & 255, product >> 8 & 255)
        // (A comma in the device's name would split the line.)
        return GamepadMapping(line: "\(guid),\(name.replacingOccurrences(of: ",", with: " ")) (guessed layout),\(parts.joined(separator: ","))")
    }
    public static func find(vendor: Int, product: Int, version: Int? = nil, in db: [Int: [GamepadMapping]] = database) -> GamepadMapping? {
        guard let list = db[vendor << 16 | product] else { return nil }
        if let version, let exact = list.first(where: { $0.version == version }) { return exact }
        return list.first
    }
}
