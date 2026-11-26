import Foundation

/// Short labels for what a control does, drawn on the controller overlay's buttons and pads: a key's own symbol
/// where it has one (⇧ ⌃ ⌥ ⌘ ␣ ↩ ⇥ ⎋ ⌫ and the arrows), a letter or digit as itself, and anything longer
/// abbreviated to a few characters. Only what fits on a button cap: the overlay's legend has the full names.
public enum PadLabel {
    /// Symbols for keys that have one (Mac key codes).
    static let symbols: [Int: String] = [
        56: "⇧", 60: "⇧", 59: "⌃", 62: "⌃", 58: "⌥", 61: "⌥", 55: "⌘", 54: "⌘", 63: "fn",
        49: "␣", 36: "↩", 76: "⌤", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦", 57: "⇪",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// A key: its symbol, a single character as itself, F-keys and keypad keys short, anything else to four letters.
    public static func key(_ code: Int) -> String {
        if let s = symbols[code] { return s }
        let title = PadProfiles.keyTitle(code)
        if title.count == 1 { return title.uppercased() }
        if title.hasPrefix("F"), title.count <= 3, Int(title.dropFirst()) != nil { return title }
        if title.hasPrefix("Keypad ") { let k = title.dropFirst("Keypad ".count); return k.count == 1 ? "⌗" + k : "⌗" + k.prefix(3) }
        return abbreviate(title)
    }

    /// One output.
    public static func output(_ o: PadProfiles.Output, family: Controllers.Family? = nil, macros: [String: String] = [:], menus: [String: String] = [:]) -> String {
        switch o {
        case .key(let k), .keyToggle(let k): return key(k)
        case .mouse(let m), .mouseToggle(let m): return mouse(m)
        case .pad(.guide), .padToggle(.guide): return "⌂"
        case .pad(let p), .padToggle(let p): return abbreviate(p.title(family), limit: 3)
        case .trigger(let r), .triggerToggle(let r): return PadProfiles.Input(rawValue: r ? "rt" : "lt")!.title(family)
        case .wheel(let up): return up ? "⇡" : "⇣"
        case .gyroOn, .gyroOff, .gyroToggle: return "Gyro"
        case .layerHold(let n), .layerToggle(let n): return abbreviate(n)
        case .macro(let id): return abbreviate(macros[id] ?? "Macro")
        case .menu(let id): return abbreviate(menus[id] ?? "Menu")
        case .keyboard: return "⌨"
        case .calibrate: return "◎"
        case .rumble: return "≋"
        case .overlayMappings: return "Map"
        case .recenterHead: return "⊕"
        case .nothing: return "–"
        }
    }

    static func mouse(_ m: PadProfiles.MouseButton) -> String {
        switch m { case .left: "LMB"; case .right: "RMB"; case .middle: "MMB"; case .back: "M4"; case .forward: "M5" }
    }

    /// Several outputs together: modifiers run into the key ("⌃C", "⇧W"), others join with "+".
    public static func outputs(_ list: [PadProfiles.Output], family: Controllers.Family? = nil, macros: [String: String] = [:], menus: [String: String] = [:]) -> String {
        let parts = list.filter { $0 != .nothing }.map { output($0, family: family, macros: macros, menus: menus) }
        guard !parts.isEmpty else { return list.isEmpty ? "" : "–" }
        let modifiers: Set<String> = ["⇧", "⌃", "⌥", "⌘"]
        if parts.dropLast().allSatisfy(modifiers.contains) { return parts.joined() }
        return parts.prefix(2).joined(separator: "+") + (parts.count > 2 ? "…" : "")
    }

    /// What a control's label says: the main action (pressed or tapped) and, smaller, a hold or double tap.
    public struct Text: Equatable, Sendable {
        public var main: String
        public var second: String?
        /// The main action switches on and off (toggle), drawn with a ring.
        public var toggles: Bool
        /// A stick's four directions (up, down, left, right), drawn around its cap with `main` small in the middle.
        public var around: [String]?
        public init(main: String, second: String? = nil, toggles: Bool = false, around: [String]? = nil) {
            self.main = main; self.second = second; self.toggles = toggles; self.around = around
        }
    }

    public static func text(_ b: PadProfiles.Binding, family: Controllers.Family? = nil, macros: [String: String] = [:], menus: [String: String] = [:]) -> Text? {
        func o(_ x: [PadProfiles.Output]) -> String { outputs(x, family: family, macros: macros, menus: menus) }
        let main = !b.press.isEmpty ? o(b.pressOutputs) : !b.tap.isEmpty ? o(b.tap) : !b.double.isEmpty ? o(b.double) : !b.hold.isEmpty ? o(b.hold) : ""
        guard !main.isEmpty else { return nil }
        var second: String?
        if !b.hold.isEmpty, !(b.press.isEmpty && b.tap.isEmpty && b.double.isEmpty) { second = "⏱" + o(b.hold) }
        else if !b.double.isEmpty, !(b.press.isEmpty && b.tap.isEmpty) { second = "²" + o(b.double) }
        let toggles = b.togglesOnPress || b.press.contains { if case .layerToggle = $0 { return true }; if case .gyroToggle = $0 { return true }; return false }
        return Text(main: main, second: second, toggles: toggles)
    }

    /// Words to a short form: initials of several words ("Crouch Walk" → "CW"), else the first letters.
    public static func abbreviate(_ s: String, limit: Int = 4) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count > limit else { return t }
        let words = t.split { $0 == " " || $0 == "-" || $0 == "_" }
        if words.count >= 2 { return String(words.prefix(limit).compactMap(\.first)).uppercased() }
        return String(t.prefix(limit))
    }
}
