import Foundation

/// Steam Input layouts (the .vdf files Steam keeps for each game and controller, and community layouts) as a
/// Nokcandu controller profile. What converts: buttons, bumpers, back grips, D-pad, triggers (soft and full
/// pull), joysticks (stick, mouse, flick, scrolling, directions, click, outer ring), trackpads (mouse,
/// mouse-like stick, stick, directions, scroll wheel, mouse region, radial and touch menus as buttons), the gyro
/// (to the mouse or a stick), each button's press, long press, double press, release, start press and toggle,
/// action layers (as layers) and mode shifts (as layers held while their button is). Anything else is named in
/// the notes, not dropped silently.
public enum SteamInputImport {
    public struct Result {
        public var profile: PadProfiles.Profile
        public var notes: [String]
    }

    // MARK: KeyValues (VDF) text

    indirect enum Node { case text(String), group([(String, Node)]) }

    static func parse(_ s: String) throws -> [(String, Node)] {
        var tokens: [String] = [], braces: [Bool] = []          // braces[i]: token i is { or }
        var i = s.startIndex
        func peek() -> Character? { i < s.endIndex ? s[i] : nil }
        while let c = peek() {
            if c.isWhitespace { i = s.index(after: i); continue }
            if c == "/", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "/" {
                while let d = peek(), d != "\n" { i = s.index(after: i); _ = d }
                continue
            }
            if c == "{" || c == "}" { tokens.append(String(c)); braces.append(true); i = s.index(after: i); continue }
            if c == "\"" {
                i = s.index(after: i)
                var t = ""
                while let d = peek(), d != "\"" {
                    if d == "\\", s.index(after: i) < s.endIndex {
                        i = s.index(after: i)
                        let e = s[i]; t.append(e == "n" ? "\n" : e == "t" ? "\t" : e)
                    } else { t.append(d) }
                    i = s.index(after: i)
                }
                if peek() == "\"" { i = s.index(after: i) }
                tokens.append(t); braces.append(false); continue
            }
            var t = ""
            while let d = peek(), !d.isWhitespace, d != "{", d != "}", d != "\"" { t.append(d); i = s.index(after: i) }
            // Conditions ([$WIN32]) apply to the key before them; this reads them as nothing.
            if !(t.hasPrefix("[") && t.hasSuffix("]")) { tokens.append(t); braces.append(false) }
        }
        var k = 0, depth = 0
        // Real layouts nest about ten deep; a file nested thousands deep would overflow the stack (found by
        // UntrustedInputFuzzTests), so it's refused.
        func list() throws -> [(String, Node)] {
            depth += 1; defer { depth -= 1 }
            guard depth <= 64 else { throw NokError("That Steam Input layout couldn't be read.") }
            var out: [(String, Node)] = []
            while k < tokens.count {
                if braces[k] && tokens[k] == "}" { k += 1; return out }
                guard !braces[k] else { throw NokError("That Steam Input layout couldn't be read.") }
                let key = tokens[k]; k += 1
                guard k < tokens.count else { break }
                if braces[k] && tokens[k] == "{" { k += 1; out.append((key, .group(try list()))) }
                else { out.append((key, .text(tokens[k]))); k += 1 }
            }
            return out
        }
        return try list()
    }

    static func group(_ pairs: [(String, Node)], _ key: String) -> [(String, Node)]? {
        for (k, v) in pairs where k.caseInsensitiveCompare(key) == .orderedSame { if case .group(let g) = v { return g } }
        return nil
    }
    static func groups(_ pairs: [(String, Node)], _ key: String) -> [[(String, Node)]] {
        pairs.compactMap { k, v in k.caseInsensitiveCompare(key) == .orderedSame ? { if case .group(let g) = v { return g }; return nil }() : nil }
    }
    static func text(_ pairs: [(String, Node)], _ key: String) -> String? {
        for (k, v) in pairs where k.caseInsensitiveCompare(key) == .orderedSame { if case .text(let t) = v { return t } }
        return nil
    }
    static func texts(_ pairs: [(String, Node)]) -> [String: String] {
        var d: [String: String] = [:]
        for (k, v) in pairs { if case .text(let t) = v { d[k.lowercased()] = t } }
        return d
    }

    // MARK: Layout

    struct Activator { var kind: String; var bindings: [String]; var settings: [String: String] }
    struct Group { var id: String; var mode: String; var name: String; var inputs: [(String, [Activator])]; var settings: [String: String] }
    struct Preset { var id: Int; var name: String; var sources: [(group: String, source: String, modeShift: Bool)] }

    public static func profile(fromVDF textValue: String, fallbackName: String) throws -> Result {
        let root = try parse(textValue)
        guard let m = group(root, "controller_mappings") else { throw NokError("That isn't a Steam Input layout (no controller_mappings).") }
        var notes: [String] = []
        func note(_ s: String) { if !notes.contains(s) { notes.append(s) } }

        var groupsByID: [String: Group] = [:]
        for g in groups(m, "group") {
            let id = text(g, "id") ?? ""
            var inputs: [(String, [Activator])] = []
            for (name, node) in group(g, "inputs") ?? [] {
                guard case .group(let inp) = node else { continue }
                var acts: [Activator] = []
                for (kind, an) in group(inp, "activators") ?? [] {
                    guard case .group(let a) = an else { continue }
                    let b = (group(a, "bindings") ?? []).compactMap { k, v -> String? in
                        if k.lowercased() == "binding", case .text(let t) = v { return t }; return nil
                    }
                    acts.append(Activator(kind: kind.lowercased(), bindings: b, settings: texts(group(a, "settings") ?? [])))
                }
                inputs.append((name.lowercased(), acts))
            }
            groupsByID[id] = Group(id: id, mode: (text(g, "mode") ?? "").lowercased(), name: text(g, "name") ?? "", inputs: inputs,
                                   settings: texts(group(g, "settings") ?? []))
        }
        var presets: [Preset] = []
        for p in groups(m, "preset") {
            var src: [(String, String, Bool)] = []
            for (gid, node) in group(p, "group_source_bindings") ?? [] {
                guard case .text(let v) = node else { continue }
                let parts = v.split(separator: " ").map(String.init)
                guard parts.count >= 2, parts[1] == "active" else { continue }
                src.append((gid, parts[0], parts.contains("modeshift")))
            }
            presets.append(Preset(id: Int(text(p, "id") ?? "") ?? presets.count, name: text(p, "name") ?? "", sources: src))
        }
        let actionSets = (group(m, "actions") ?? []).map { k, v -> (String, String) in
            if case .group(let g) = v { return (k, text(g, "title") ?? k) }; return (k, k)
        }
        let actionLayers = Dictionary((group(m, "action_layers") ?? []).map { k, v -> (String, String) in
            if case .group(let g) = v { return (k, text(g, "title") ?? k) }; return (k, k)
        }, uniquingKeysWith: { a, _ in a })

        // The profile.
        var title = text(m, "title") ?? ""
        if title.isEmpty || title.hasPrefix("#") { title = fallbackName }
        var p = PadProfiles.Profile(name: title)
        let type = (text(m, "controller_type") ?? "").lowercased()
        let family: Controllers.Family?
        if type.contains("steamcontroller") || type.contains("gordon") { family = .valve; p.controllerSource = .steamUSB; p.controllerLabels = "valve" }
        else if type.contains("triton") { family = .steam2026; p.controllerSource = .steamUSB; p.controllerLabels = "steam2026" }
        else if type.contains("ps4") || type.contains("ps5") || type.contains("ps3") { family = .playstation; p.controllerLabels = "playstation" }
        else if type.contains("switch") { family = .nintendo; p.controllerLabels = "nintendo" }
        else { family = nil; if type.contains("xbox") { p.controllerLabels = "xbox" } }

        // Base: the first action set's preset; layers: presets that are action layers.
        let basePreset = presets.first { p in actionSets.first.map { $0.0 == p.name } ?? false } ?? presets.first { $0.id == 0 } ?? presets.first
        if actionSets.count > 1 { note("Only the first action set (\(actionSets[0].1)) is imported; Nokcandu profiles have one, with layers. Other sets: \(actionSets.dropFirst().map(\.1).joined(separator: ", ")).") }
        var layerOfPreset: [Int: Int] = [:]
        func addLayer(_ name: String) -> Int {
            var n = name.isEmpty ? "Layer" : name, i = 2
            while p.layers.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { n = "\(name) \(i)"; i += 1 }
            p.layers.append(PadProfiles.Layer(id: UUID().uuidString, name: n))
            return p.layers.count - 1
        }
        for pr in presets where pr.name != basePreset?.name {
            if let t = actionLayers[pr.name] { layerOfPreset[pr.id] = addLayer(t) }
        }
        // Layer actions count sets and layers from 1 in the order they're in the file (1 is the main set).
        func layerName(_ n: Int) -> String? {
            guard n >= 1, n <= presets.count else { return nil }
            return layerOfPreset[presets[n - 1].id].map { p.layers[$0].name }
        }
        var modeShiftLayers: [String: Int] = [:]          // "source|group" → layer
        var pendingShifts: [(source: String, group: String, layer: Int)] = []

        // MARK: Bindings

        let keys: [String: Int] = SteamInputImport.keyCodes
        func outputs(_ binding: String) -> [PadProfiles.Output] {
            let main = binding.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? binding
            let w = main.split(separator: " ").map(String.init)
            guard let kind = w.first?.lowercased() else { return [] }
            let arg = w.count > 1 ? w[1].uppercased() : ""
            switch kind {
            case "key_press":
                if let k = keys[arg] { return [.key(k)] }
                note("Key \(arg) has no Mac equivalent here; left out."); return []
            case "mouse_button":
                let b: PadProfiles.MouseButton? = ["LEFT": .left, "RIGHT": .right, "MIDDLE": .middle, "BACK": .back, "X1": .back, "FORWARD": .forward, "X2": .forward][arg]
                return b.map { [.mouse($0)] } ?? []
            case "mouse_wheel":
                switch arg { case "SCROLL_UP": return [.wheel(up: true)]; case "SCROLL_DOWN": return [.wheel(up: false)]
                case "SCROLL_LEFT": return [.hwheel(right: false)]; case "SCROLL_RIGHT": return [.hwheel(right: true)]; default: return [] }
            case "xinput_button", "gamepad_button":
                let map: [String: PadProfiles.Output] = ["A": .pad(.a), "B": .pad(.b), "X": .pad(.x), "Y": .pad(.y),
                    "SHOULDER_LEFT": .pad(.lb), "SHOULDER_RIGHT": .pad(.rb), "TRIGGER_LEFT": .trigger(right: false), "TRIGGER_RIGHT": .trigger(right: true),
                    "JOYSTICK_LEFT": .pad(.ls), "JOYSTICK_RIGHT": .pad(.rs), "START": .pad(.start), "SELECT": .pad(.back), "BACK": .pad(.back),
                    "GUIDE": .pad(.guide), "HOME": .pad(.guide), "DPAD_UP": .pad(.up), "DPAD_DOWN": .pad(.down), "DPAD_LEFT": .pad(.left), "DPAD_RIGHT": .pad(.right)]
                return map[arg].map { [$0] } ?? []
            case "controller_action":
                let n = w.count > 2 ? Int(w[2]) : nil
                switch arg {
                case "HOLD_LAYER", "ADD_LAYER":
                    if let n, let name = layerName(n) { return [arg == "HOLD_LAYER" ? .layerHold(name) : .layerToggle(name)] }
                    note("A button refers to layer \(n.map(String.init) ?? "?"), which isn't in this layout; left out."); return []
                case "SHOW_KEYBOARD": return [.keyboard]
                default: break
                }
                note("Steam action “\(w.dropFirst().joined(separator: " "))” isn't available in Nokcandu; left out."); return []
            case "mode_shift":
                // mode_shift <source> <group>: a layer held while this is, with that group on that source.
                guard w.count > 2 else { return [] }
                let key = w[1].lowercased() + "|" + w[2]
                let li = modeShiftLayers[key] ?? {
                    let l = addLayer("Mode shift: " + sourceTitle(w[1].lowercased()))
                    modeShiftLayers[key] = l; pendingShifts.append((w[1].lowercased(), w[2], l)); return l
                }()
                return [.layerHold(p.layers[li].name)]
            case "game_action":
                note("Steam Input game actions (games made for Steam Input) can't be imported; their buttons are left as they are."); return []
            default:
                note("“\(kind)” bindings aren't supported; left out."); return []
            }
        }
        func binding(_ acts: [Activator]) -> PadProfiles.Binding? {
            func outs(_ kind: String) -> [PadProfiles.Output] { acts.filter { $0.kind == kind }.flatMap { $0.bindings.flatMap(outputs) } }
            let full = outs("full_press"), long = outs("long_press"), dbl = outs("double_press"), rel = outs("release"), start = outs("start_press")
            for a in acts where !["full_press", "long_press", "double_press", "release", "start_press", "soft_press"].contains(a.kind) {
                note("\(a.kind.replacingOccurrences(of: "_", with: " ").capitalized) activators aren't imported.")
            }
            var b = PadProfiles.Binding()
            if !long.isEmpty || !dbl.isEmpty {
                b.tap = full + start; b.hold = long; b.double = dbl
                if !start.isEmpty { b.instantTap = true }
                if let t = acts.first(where: { $0.kind == "long_press" })?.settings["long_press_time"].flatMap(Double.init) { b.holdTime = t / 1000 }
                if let t = acts.first(where: { $0.kind == "double_press" })?.settings["double_tap_time"].flatMap(Double.init) { b.doubleTime = t / 1000 }
            } else {
                b.press = start + full
                if acts.contains(where: { $0.kind == "full_press" && $0.settings["toggle"] == "1" }) {
                    let t = b.press.compactMap(\.toggledOutput)
                    if !t.isEmpty { b.press = t; b.togglePress = true }
                }
            }
            if !rel.isEmpty { b.release = rel }
            return b.isEmpty ? nil : b
        }

        // MARK: Groups onto the controller

        func put(_ li: Int, _ input: PadProfiles.Input, _ acts: [Activator]) {
            if let b = binding(acts) { p.layers[li][input] = b }
        }
        func setStick(_ li: Int, _ side: Int, _ s: PadProfiles.Stick) {
            if li == 0 { if side == 0 { p.leftStick = s } else { p.rightStick = s } }
            else if side == 0 { p.layers[li].leftStick = s } else { p.layers[li].rightStick = s }
        }
        func setPad(_ li: Int, _ side: Int, _ s: PadSteamTrackpadSettings) {
            if li == 0 { if side == 0 { p.steamLeftTrackpad = s } else { p.steamRightTrackpad = s } }
            else if side == 0 { p.layers[li].steamLeftTrackpad = s } else { p.layers[li].steamRightTrackpad = s }
        }
        func setGyro(_ li: Int, _ g: PadProfiles.Gyro) { if li == 0 { p.gyro = g } else { p.layers[li].gyro = g } }
        func acts(_ g: Group, _ name: String) -> [Activator] { g.inputs.first { $0.0 == name }?.1 ?? [] }

        func apply(_ g: Group, source: String, layer li: Int) {
            switch source {
            case "button_diamond":
                for (n, i) in [("button_a", PadProfiles.Input.a), ("button_b", .b), ("button_x", .x), ("button_y", .y)] { put(li, i, acts(g, n)) }
            case "switch":
                let map: [String: PadProfiles.Input] = ["button_escape": .start, "button_menu": .back, "left_bumper": .lb, "right_bumper": .rb,
                    "button_back_left": .paddle2, "button_back_right": .paddle1, "button_back_left_upper": .paddle4, "button_back_right_upper": .paddle3,
                    "button_capture": .misc, "button_guide": .guide]
                for (n, a) in g.inputs { if let i = map[n] { put(li, i, a) } else if !a.isEmpty { note("The \(n.replacingOccurrences(of: "_", with: " ")) isn't on these controllers here; left out.") } }
            case "dpad":
                for (n, i) in [("dpad_north", PadProfiles.Input.up), ("dpad_south", .down), ("dpad_west", .left), ("dpad_east", .right)] { put(li, i, acts(g, n)) }
            case "left_trigger", "right_trigger":
                let r = source == "right_trigger"
                put(li, r ? .rtfull : .ltfull, acts(g, "click"))
                put(li, r ? .rt : .lt, acts(g, "edge"))
            case "joystick", "left_joystick", "right_joystick":
                let side = source == "right_joystick" ? 1 : 0
                var s = PadProfiles.Stick()
                let d = PadProfiles.Input.stickDirections(side)
                switch g.mode {
                case "joystick_move": s.mode = side == 0 ? .stick : .otherStick
                case "joystick_camera": s.mode = side == 1 ? .stick : .otherStick
                case "joystick_mouse", "mouse_joystick", "absolute_mouse": s.mode = .mouse
                case "flickstick": s.mode = .flick
                case "scrollwheel", "2dscroll": s.mode = .scroll
                case "dpad":
                    s.mode = .directions
                    for (n, i) in zip(["dpad_north", "dpad_south", "dpad_west", "dpad_east"], d) { put(li, i, acts(g, n)) }
                case "four_buttons":
                    s.mode = .directions
                    for (n, i) in zip(["button_y", "button_a", "button_x", "button_b"], d) { put(li, i, acts(g, n)) }
                default: note("Joystick mode “\(g.mode)” isn't imported; the stick is left as a stick.")
                }
                setStick(li, side, s)
                put(li, side == 0 ? .ls : .rs, acts(g, "click"))
                put(li, .stickRing(side), acts(g, "edge"))
            case "left_trackpad", "right_trackpad":
                let side = source == "right_trackpad" ? 1 : 0
                var s = PadSteamTrackpadSettings(mode: .existing)
                switch g.mode {
                case "absolute_mouse": s.mode = .mouse
                case "mouse_joystick": s.mode = .velocityStick
                case "joystick_move", "joystick_camera": s.mode = .stick
                case "mouse_region": s.mode = .absolute
                case "scrollwheel": s.mode = .dial
                case "dpad":
                    s.mode = .directions
                    for (n, i) in zip(["dpad_north", "dpad_south", "dpad_west", "dpad_east"], PadProfiles.Input.padDirections(side)) { put(li, i, acts(g, n)) }
                case "four_buttons":
                    s.mode = .buttons; s.zoneLayout = .ring4
                    for (k, n) in ["button_y", "button_b", "button_a", "button_x"].enumerated() { put(li, .padZoneTap(side, k), acts(g, n)) }
                case "radial_menu", "touch_menu":
                    let items = g.inputs.filter { $0.0.hasPrefix("touch_menu_button_") }
                        .compactMap { n, a in Int(n.dropFirst("touch_menu_button_".count)).map { ($0, a) } }.sorted { $0.0 < $1.0 }
                    // Slots up to the highest item number (empty ones count too), or the menu's own count.
                    let count = max(items.count, (items.last?.0 ?? -1) + 1, Int(g.settings["touchmenu_button_count"] ?? "") ?? 0)
                    s.mode = .buttons; s.zoneLayout = count <= 4 ? .ring4 : count <= 6 ? .ring6 : .ring8
                    for (n, a) in items where n < PadProfiles.Input.maxPadZones { put(li, .padZoneTap(side, n), a) }
                    if count > PadProfiles.Input.maxPadZones { note("“\(g.name.isEmpty ? g.mode : g.name)” has \(count) items; the first eight are kept.") }
                    note("Steam's radial and touch menus pick on release or click; here the trackpad's buttons press while touched (see Buttons on that trackpad).")
                case "single_button": s.mode = .existing
                default: note("Trackpad mode “\(g.mode)” isn't imported; that trackpad keeps its usual behavior.")
                }
                setPad(li, side, s)
                let click: PadProfiles.Input = side == 0 ? .touchpad : (family == .steam2026 ? .rpclick : .rs)
                put(li, click, acts(g, "click"))
                if !acts(g, "touch").isEmpty { note("Trackpad touch bindings aren't imported.") }
            case "gyro":
                var gy = PadProfiles.Gyro()
                switch g.mode {
                case "gyro_to_mouse", "mouse_joystick", "absolute_mouse": gy.output = .mouse
                case "gyro_to_joystick_camera", "joystick_camera": gy.output = .rightStick
                case "gyro_to_joystick", "joystick_move": gy.output = .leftStick
                default: note("Gyro mode “\(g.mode)” isn't imported.")
                }
                if g.settings["gyro_button"] != nil || g.settings["gyro_ratchet_button_mask"] != nil {
                    note("The gyro's activation and ratchet buttons aren't imported; set them with Gyro on/off actions.")
                }
                setGyro(li, gy)
            case "center_trackpad":
                note("The DualShock/DualSense touchpad isn't imported; set it up under Touchpad.")
            default:
                if !g.inputs.isEmpty { note("Steam's “\(source)” isn't imported.") }
            }
        }

        // Base, then layers, then mode shifts (which can add more layers as they're found).
        if let b = basePreset {
            for s in b.sources where !s.modeShift { if let g = groupsByID[s.group] { apply(g, source: s.source, layer: 0) } }
        }
        for pr in presets where pr.name != basePreset?.name {
            guard let li = layerOfPreset[pr.id] else { continue }
            for s in pr.sources where !s.modeShift { if let g = groupsByID[s.group] { apply(g, source: s.source, layer: li) } }
        }
        var done = 0
        while done < pendingShifts.count {
            let s = pendingShifts[done]; done += 1
            if let g = groupsByID[s.group] { apply(g, source: s.source, layer: s.layer) }
        }
        if p.layers.count > 8 { note("This layout has \(p.layers.count) layers; Nokcandu uses up to eight at once.") }
        return Result(profile: p, notes: notes)
    }

    static func sourceTitle(_ s: String) -> String {
        ["joystick": "joystick", "left_joystick": "left stick", "right_joystick": "right stick", "left_trackpad": "left trackpad",
         "right_trackpad": "right trackpad", "button_diamond": "face buttons", "dpad": "D-pad", "gyro": "gyro",
         "left_trigger": "left trigger", "right_trigger": "right trigger", "switch": "buttons"][s] ?? s
    }

    /// Steam's key names to Mac key codes.
    static let keyCodes: [String: Int] = {
        var k: [String: Int] = ["A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14,
            "R": 15, "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "O": 31, "U": 32,
            "I": 34, "P": 35, "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
            "RETURN": 36, "ENTER": 36, "TAB": 48, "SPACE": 49, "BACKSPACE": 51, "ESCAPE": 53, "CAPSLOCK": 57, "CAPS_LOCK": 57,
            "LEFT_SHIFT": 56, "RIGHT_SHIFT": 60, "LEFT_CONTROL": 59, "RIGHT_CONTROL": 62, "LEFT_ALT": 58, "RIGHT_ALT": 61,
            "LEFT_WINDOWS": 55, "RIGHT_WINDOWS": 54, "LEFT_COMMAND": 55, "RIGHT_COMMAND": 54,
            "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
            "F13": 105, "F14": 107, "F15": 113, "INSERT": 114, "DELETE": 117, "HOME": 115, "END": 119, "PAGE_UP": 116, "PAGE_DOWN": 121, "PAGEUP": 116, "PAGEDOWN": 121,
            "LEFT_ARROW": 123, "RIGHT_ARROW": 124, "DOWN_ARROW": 125, "UP_ARROW": 126,
            "PERIOD": 47, "COMMA": 43, "FORWARD_SLASH": 44, "SLASH": 44, "SEMICOLON": 41, "SINGLE_QUOTE": 39, "APOSTROPHE": 39,
            "LEFT_BRACKET": 33, "RIGHT_BRACKET": 30, "BACKSLASH": 42, "DASH": 27, "MINUS": 27, "EQUALS": 24, "BACK_TICK": 50, "TILDE": 50, "GRAVE": 50,
            "KEYPAD_ENTER": 76, "KEYPAD_PLUS": 69, "KEYPAD_DASH": 78, "KEYPAD_MINUS": 78, "KEYPAD_MULTIPLY": 67, "KEYPAD_ASTERISK": 67,
            "KEYPAD_FORWARD_SLASH": 75, "KEYPAD_DIVIDE": 75, "KEYPAD_PERIOD": 65, "KEYPAD_DECIMAL": 65]
        for (n, c) in zip(0...9, [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]) { k["KEYPAD_\(n)"] = c }
        return k
    }()
}
