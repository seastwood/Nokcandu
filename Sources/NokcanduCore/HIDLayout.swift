import Foundation

/// How SDL — and so Windows games in Wine — numbers a joystick's buttons, hat and axes on a Mac, so Nokcandu reads
/// devices the same way and "Axis 3" means the same control everywhere. From SDL's IOKit joystick code: buttons
/// (Button and Consumer pages, the d-pad and Start/Select usages) and axes (X…Wheel, and the Simulation page's
/// rudder, throttle, accelerator and brake) are each kept in order of usage number — across pages — with the device's
/// own order for equal usages; elements already seen are skipped. Nokcandu uses the first hat switch.
public enum HIDLayout {
    public struct Element: Sendable {
        public let type: Int, page: Int, usage: Int, cookie: UInt32, min: Int, max: Int
        public init(type: Int, page: Int, usage: Int, cookie: UInt32, min: Int, max: Int) {
            self.type = type; self.page = page; self.usage = usage; self.cookie = cookie; self.min = min; self.max = max
        }
    }
    public struct Part: Sendable { public let cookie: UInt32; public let name: String; public let min: Int, max: Int }

    // IOHIDElementType input kinds (misc, button, axis), and usage pages and usages.
    static let inputTypes: Set<Int> = [1, 2, 3]
    static let genericDesktop = 0x01, simulation = 0x02, button = 0x09, consumer = 0x0C
    static let hat = 0x39
    static let desktopButtons: Set<Int> = [0x90, 0x91, 0x92, 0x93, 0x3D, 0x3E, 0x85]    // d-pad up/down/right/left, start, select, system main menu
    static let simAxes: Set<Int> = [0xBA, 0xBB, 0xC4, 0xC5]                            // rudder, throttle, accelerator, brake

    public static func axisName(page: Int, usage: Int) -> String {
        if page == simulation { return [0xBA: "Rudder", 0xBB: "Throttle", 0xC4: "Accelerator", 0xC5: "Brake"][usage] ?? "Axis" }
        return [0x30: "X", 0x31: "Y", 0x32: "Z", 0x33: "Rx", 0x34: "Ry", 0x35: "Twist", 0x36: "Slider", 0x37: "Dial", 0x38: "Wheel"][usage] ?? "Axis"
    }

    public static func layout(_ list: [Element]) -> (buttons: [Part], axes: [Part], hat: Part?) {
        var buttons: [(usage: Int, order: Int, e: Element)] = [], axes: [(usage: Int, order: Int, e: Element)] = []
        var hatPart: Part?
        var seen = Set<UInt32>()
        for (i, e) in list.enumerated() {
            guard inputTypes.contains(e.type), seen.insert(e.cookie).inserted else { continue }
            switch e.page {
            case genericDesktop:
                if (0x30...0x38).contains(e.usage) { axes.append((e.usage, i, e)) }
                else if e.usage == hat { if hatPart == nil { hatPart = Part(cookie: e.cookie, name: "Hat", min: e.min, max: e.max) } }
                else if desktopButtons.contains(e.usage) { buttons.append((e.usage, i, e)) }
            case simulation: if simAxes.contains(e.usage) { axes.append((e.usage, i, e)) }
            case button, consumer: buttons.append((e.usage, i, e))
            default: break
            }
        }
        buttons.sort { ($0.usage, $0.order) < ($1.usage, $1.order) }
        axes.sort { ($0.usage, $0.order) < ($1.usage, $1.order) }
        var counts: [String: Int] = [:]
        let named = axes.map { a -> Part in
            let base = axisName(page: a.e.page, usage: a.e.usage)
            counts[base, default: 0] += 1
            let n = counts[base]!
            return Part(cookie: a.e.cookie, name: n == 1 ? base : "\(base) \(n)", min: a.e.min, max: a.e.max)
        }
        return (buttons.map { Part(cookie: $0.e.cookie, name: "Button", min: $0.e.min, max: $0.e.max) }, named, hatPart)
    }

    /// An axis reading as SDL scales it: −32768…32767 across the element's range.
    public static func axisValue(_ raw: Int, min: Int, max: Int) -> Int {
        let span = Swift.max(1, max - min)
        return Int(Swift.max(-32768, Swift.min(32767, (Double(raw - min) * 65535 / Double(span) - 32768).rounded())))
    }
    /// A hat reading as SDL's direction bits (1 up, 2 right, 4 down, 8 left): 8 positions clockwise from up, a
    /// 4-position hat counting double; anything else is centred.
    public static func hatBits(_ raw: Int, min: Int, max: Int) -> Int {
        var pos = raw - min
        let range = max - min + 1
        if range == 4 { pos *= 2 } else if range != 8 { return 0 }
        return pos >= 0 && pos < 8 ? [1, 3, 2, 6, 4, 12, 8, 9][pos] : 0
    }
}
