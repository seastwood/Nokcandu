import Foundation

/// Controller profiles: what each button, trigger, stick and the gyro do in a game. Shared like key layouts (a
/// default that new games follow, or one per game), and stackable: a profile can build on others, and anything it
/// doesn't set comes from them. Inside a profile, layers change what buttons do while a button is held or after
/// one is pressed. The helper in Wine's controller driver applies the profile (padengine.c); this file stores
/// profiles and writes each Windows environment's "pad-map", the compiled profile the helper reads.
public enum PadProfiles {

    // MARK: Inputs

    public enum Input: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
        case a, b, x, y, back, guide, start, ls, rs, lb, rb, up, down, left, right, misc
        case paddle1, paddle2, paddle3, paddle4, touchpad, lt, rt, ltfull, rtfull
        public var id: String { rawValue }

        public var isTrigger: Bool { [.lt, .rt, .ltfull, .rtfull].contains(self) }
        /// Inputs that are real controller buttons (can be sent to the game as a button).
        public static var padButtons: [Input] { allCases.filter { !$0.isTrigger } }

        /// The name printed on this controller's button.
        public func title(_ family: Controllers.Family? = nil) -> String {
            switch (self, family) {
            case (.a, .playstation): "Cross"; case (.b, .playstation): "Circle"; case (.x, .playstation): "Square"; case (.y, .playstation): "Triangle"
            case (.a, .nintendo): "B"; case (.b, .nintendo): "A"; case (.x, .nintendo): "Y"; case (.y, .nintendo): "X"
            case (.lb, .playstation): "L1"; case (.rb, .playstation): "R1"; case (.lt, .playstation): "L2"; case (.rt, .playstation): "R2"
            case (.ltfull, .playstation): "L2 (full pull)"; case (.rtfull, .playstation): "R2 (full pull)"
            case (.ls, .playstation): "L3"; case (.rs, .playstation): "R3"
            case (.back, .playstation): "Create"; case (.start, .playstation): "Options"; case (.guide, .playstation): "PS"
            case (.misc, .playstation): "Mute"; case (.touchpad, _): "Touchpad click"
            case (.lb, .nintendo): "L"; case (.rb, .nintendo): "R"; case (.lt, .nintendo): "ZL"; case (.rt, .nintendo): "ZR"
            case (.ltfull, .nintendo): "ZL (full pull)"; case (.rtfull, .nintendo): "ZR (full pull)"
            case (.back, .nintendo): "−"; case (.start, .nintendo): "+"; case (.guide, .nintendo): "Home"; case (.misc, .nintendo): "Capture"
            case (.ls, .nintendo): "Left stick click"; case (.rs, .nintendo): "Right stick click"
            case (.a, _): "A"; case (.b, _): "B"; case (.x, _): "X"; case (.y, _): "Y"
            case (.lb, _): "LB"; case (.rb, _): "RB"; case (.lt, _): "LT"; case (.rt, _): "RT"
            case (.ltfull, _): "LT (full pull)"; case (.rtfull, _): "RT (full pull)"
            case (.ls, _): "Left stick click"; case (.rs, _): "Right stick click"
            case (.back, _): "View"; case (.start, _): "Menu"; case (.guide, _): "Guide"; case (.misc, _): "Share"
            case (.up, _): "D-pad up"; case (.down, _): "D-pad down"; case (.left, _): "D-pad left"; case (.right, _): "D-pad right"
            case (.paddle1, .valve): "Right back grip"; case (.paddle2, .valve): "Left back grip"
            case (.paddle3, .valve): "Right inner grip"; case (.paddle4, .valve): "Left inner grip"
            case (.paddle1, _): "Paddle P1"; case (.paddle2, _): "Paddle P2"; case (.paddle3, _): "Paddle P3"; case (.paddle4, _): "Paddle P4"
            }
        }
    }

    public enum MouseButton: String, CaseIterable, Codable, Hashable, Sendable {
        case left, right, middle, back, forward
        public var title: String { switch self { case .left: "Left click"; case .right: "Right click"; case .middle: "Middle click"; case .back: "Mouse back"; case .forward: "Mouse forward" } }
    }

    /// Something a button does. Several together are a combination (Shift+R).
    public enum Output: Hashable, Codable, Sendable {
        case pad(Input)                 // a controller button (not a trigger)
        case trigger(right: Bool)       // a trigger pulled all the way
        case key(Int)                   // Mac key code
        case mouse(MouseButton)
        case wheel(up: Bool)
        case gyroOn, gyroOff, gyroToggle
        case layerHold(String), layerToggle(String)     // layer names
        case nothing

        public var token: String {
            switch self {
            case .pad(let i): "pad:\(i.rawValue)"
            case .trigger(let r): "trig:\(r ? "r" : "l")"
            case .key(let k): "key:\(k)"
            case .mouse(let m): "mouse:\(m.rawValue)"
            case .wheel(let up): "wheel:\(up ? "up" : "down")"
            case .gyroOn: "gyro:on"; case .gyroOff: "gyro:off"; case .gyroToggle: "gyro:toggle"
            case .layerHold(let n): "layerhold:\(n)"; case .layerToggle(let n): "layertoggle:\(n)"
            case .nothing: "none"
            }
        }
        public init?(token: String) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let v = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "pad": guard let i = Input(rawValue: v), !i.isTrigger else { return nil }; self = .pad(i)
            case "trig": self = .trigger(right: v == "r")
            case "key": guard let k = Int(v) else { return nil }; self = .key(k)
            case "mouse": guard let m = MouseButton(rawValue: v) else { return nil }; self = .mouse(m)
            case "wheel": self = .wheel(up: v != "down")
            case "gyro": self = v == "on" ? .gyroOn : v == "off" ? .gyroOff : .gyroToggle
            case "layerhold": self = .layerHold(v)
            case "layertoggle": self = .layerToggle(v)
            case "none": self = .nothing
            default: return nil
            }
        }
        public init(from decoder: Decoder) throws {
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let o = Output(token: s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown output \(s)")) }
            self = o
        }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(token) }

        public func title(_ family: Controllers.Family? = nil) -> String {
            switch self {
            case .pad(let i): i.title(family)
            case .trigger(let r): Input(rawValue: r ? "rt" : "lt")!.title(family)
            case .key(let k): PadProfiles.keyTitle(k)
            case .mouse(let m): m.title
            case .wheel(let up): up ? "Scroll up" : "Scroll down"
            case .gyroOn: "Gyro on while held"; case .gyroOff: "Gyro off while held"; case .gyroToggle: "Gyro on/off"
            case .layerHold(let n): "\(n) while held"; case .layerToggle(let n): "\(n) on/off"
            case .nothing: "Nothing"
            }
        }
    }

    public static let keys: [KeyRemap.Key] = KeyRemap.keys + [
        ("-", 27), ("=", 24), ("[", 33), ("]", 30), (";", 41), ("'", 39), (",", 43), (".", 47), ("/", 44), ("\\", 42),
        ("Keypad 0", 82), ("Keypad 1", 83), ("Keypad 2", 84), ("Keypad 3", 85), ("Keypad 4", 86), ("Keypad 5", 87),
        ("Keypad 6", 88), ("Keypad 7", 89), ("Keypad 8", 91), ("Keypad 9", 92), ("Keypad Enter", 76),
    ].map { KeyRemap.Key(code: $0.1, title: $0.0, karabiner: "") }
    public static func keyTitle(_ code: Int) -> String { keys.first { $0.code == code }?.title ?? "Key \(code)" }

    /// What a button does: right away, or different things for a tap, a hold and a double tap; or something else
    /// when pressed together with another button.
    public struct Binding: Codable, Hashable, Sendable {
        public var press: [Output] = []
        public var tap: [Output] = []
        public var hold: [Output] = []
        public var double: [Output] = []
        /// Repeats while held (milliseconds between presses).
        public var turbo: Int?
        public var together: Input?
        public var togetherOutputs: [Output] = []
        public var holdTime: Double?
        public var doubleTime: Double?
        public init(press: [Output] = [], tap: [Output] = [], hold: [Output] = [], double: [Output] = [], turbo: Int? = nil,
                    together: Input? = nil, togetherOutputs: [Output] = []) {
            self.press = press; self.tap = tap; self.hold = hold; self.double = double; self.turbo = turbo
            self.together = together; self.togetherOutputs = togetherOutputs
        }
        public var isEmpty: Bool { press.isEmpty && tap.isEmpty && hold.isEmpty && double.isEmpty && togetherOutputs.isEmpty }
        public static func `as`(_ o: Output) -> Binding { Binding(press: [o]) }
    }

    public struct Layer: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var bindings: [String: Binding]          // Input raw value → binding
        public init(id: String = UUID().uuidString, name: String, bindings: [String: Binding] = [:]) { self.id = id; self.name = name; self.bindings = bindings }
        public subscript(_ i: Input) -> Binding? {
            get { bindings[i.rawValue] }
            set { bindings[i.rawValue] = newValue?.isEmpty == false ? newValue : nil }
        }
    }

    public enum StickMode: String, CaseIterable, Codable, Hashable, Sendable {
        case stick, otherStick, mouse, flick, keys, off
        public var title: String {
            switch self {
            case .stick: "Stick"; case .otherStick: "The other stick"; case .mouse: "Mouse"
            case .flick: "Flick stick"; case .keys: "Keys"; case .off: "Nothing"
            }
        }
    }
    public struct Stick: Codable, Hashable, Sendable {
        public var mode: StickMode = .stick
        public var deadzone = 0.12
        public var outer = 0.95
        /// Mouse: counts per second at full tilt, and how sharply speed rises (1 straight, 2 gentle start).
        public var speed = 1500.0
        public var curve = 1.5
        /// Flick stick: mouse counts for one full turn in the game, and how long a flick takes.
        public var countsPerTurn = 4000.0
        public var flickTime = 0.1
        /// Keys: up, down, left, right (Mac key codes; W S A D).
        public var keys = [13, 1, 0, 2]
        public var invertY = false
        public init(mode: StickMode = .stick) { self.mode = mode }
    }

    public enum GyroOutput: String, CaseIterable, Codable, Hashable, Sendable {
        case off, mouse, leftStick, rightStick
        public var title: String { switch self { case .off: "Off"; case .mouse: "Mouse"; case .leftStick: "Left stick"; case .rightStick: "Right stick" } }
    }
    public enum GyroTurn: String, CaseIterable, Codable, Hashable, Sendable {
        case yaw, roll, both
        public var title: String { switch self { case .yaw: "Turning the controller"; case .roll: "Tilting it sideways"; case .both: "Either" } }
    }
    public struct Gyro: Codable, Hashable, Sendable {
        public var output: GyroOutput = .off
        /// On until a "gyro off" button is held (true), or off until a "gyro on" button is held (false).
        public var startsOn = true
        /// Mouse counts per degree turned; with acceleration, slow turns use `sensitivity` and fast ones `fastSensitivity`.
        public var sensitivity = 8.0
        public var fastSensitivity: Double?
        public var slowSpeed = 0.0, fastSpeed = 75.0          // degrees per second
        /// Below this speed (°/s) movement is averaged out (steadier aim); 0 off.
        public var smoothing = 0.0
        /// Below this speed (°/s) movement is scaled down (hand shake); 0 off.
        public var tightening = 0.0
        public var invertX = false, invertY = false
        public var turn: GyroTurn = .yaw
        /// Gyro as a stick: the turning speed (°/s) that pushes it all the way, and the least push (games' own dead zones).
        public var stickFullSpeed = 300.0
        public var stickMinimum = 0.1
        public var autoCalibrate = true
        public init(output: GyroOutput = .off) { self.output = output }
    }
    public struct Triggers: Codable, Hashable, Sendable {
        /// How far a trigger is pulled to count as pressed, and as fully pulled (0…1).
        public var soft = 0.3, full = 0.95
        public init() {}
    }

    public struct Profile: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// Profiles this one builds on, bottom first. What this one doesn't set comes from them.
        public var buildsOn: [String] = []
        /// layers[0] is the base layer.
        public var layers: [Layer]
        public var leftStick: Stick?
        public var rightStick: Stick?
        public var gyro: Gyro?
        public var triggers: Triggers?
        public init(id: String = UUID().uuidString, name: String, buildsOn: [String] = [], layers: [Layer] = [Layer(id: "base", name: "Base")],
                    leftStick: Stick? = nil, rightStick: Stick? = nil, gyro: Gyro? = nil, triggers: Triggers? = nil) {
            self.id = id; self.name = name; self.buildsOn = buildsOn; self.layers = layers.isEmpty ? [Layer(id: "base", name: "Base")] : layers
            self.leftStick = leftStick; self.rightStick = rightStick; self.gyro = gyro; self.triggers = triggers
        }
        public var base: Layer {
            get { layers[0] }
            set { layers[0] = newValue }
        }
    }

    // MARK: Compiling (profile + what it builds on → the helper's text)

    /// The profile and everything under it, bottom first (each once; loops are cut).
    public static func stack(_ p: Profile, all: [Profile]) -> [Profile] {
        var out: [Profile] = [], seen = Set<String>()
        func visit(_ q: Profile) {
            guard seen.insert(q.id).inserted else { return }
            for id in q.buildsOn { if let under = all.first(where: { $0.id == id }) { visit(under) } }
            out.append(q)
        }
        visit(p)
        return out
    }

    /// Layers merged across the stack by name (every profile's first layer is the base).
    public static func merged(_ p: Profile, all: [Profile]) -> (layers: [(name: String, bindings: [Input: Binding])], left: Stick, right: Stick, gyro: Gyro, triggers: Triggers) {
        var names: [String] = ["Base"], maps: [[Input: Binding]] = [[:]]
        var left = Stick(), right = Stick(), gyro = Gyro(), triggers = Triggers()
        for q in stack(p, all: all) {
            for (i, layer) in q.layers.enumerated() {
                let key = i == 0 ? "Base" : layer.name
                var idx = names.firstIndex { $0.caseInsensitiveCompare(key) == .orderedSame }
                if idx == nil { names.append(layer.name); maps.append([:]); idx = names.count - 1 }
                for (raw, b) in layer.bindings { if let input = Input(rawValue: raw) { maps[idx!][input] = b } }
            }
            if let s = q.leftStick { left = s }
            if let s = q.rightStick { right = s }
            if let g = q.gyro { gyro = g }
            if let t = q.triggers { triggers = t }
        }
        return (Array(zip(names, maps)).map { (name: $0.0, bindings: $0.1) }, left, right, gyro, triggers)
    }

    public static func compile(_ p: Profile, all: [Profile]) -> String {
        let m = merged(p, all: all)
        let layerIndex = Dictionary(m.layers.enumerated().map { ($0.element.name.lowercased(), $0.offset) }, uniquingKeysWith: { a, _ in a })
        func outs(_ o: [Output]) -> String? {
            let t = o.compactMap { x -> String? in
                switch x {
                case .layerHold(let n): return layerIndex[n.lowercased()].map { "layer:hold:\($0)" }
                case .layerToggle(let n): return layerIndex[n.lowercased()].map { "layer:toggle:\($0)" }
                default: return x.token
                }
            }
            return t.isEmpty ? nil : t.joined(separator: ",")
        }
        func n(_ d: Double) -> String { String(format: "%g", d) }
        var lines = ["nokpad 1"]
        let g = m.gyro
        let gout: String = { switch g.output { case .off: "off"; case .mouse: "mouse"; case .leftStick: "lstick"; case .rightStick: "rstick" } }()
        lines.append("gyro out=\(gout) on=\(g.startsOn ? 1 : 0) min=\(n(g.sensitivity)) max=\(n(g.fastSensitivity ?? g.sensitivity)) lo=\(n(g.slowSpeed)) hi=\(n(g.fastSpeed)) smooth=\(n(g.smoothing)) tight=\(n(g.tightening)) invx=\(g.invertX ? 1 : 0) invy=\(g.invertY ? 1 : 0) yaw=\(g.turn.rawValue) stickfull=\(n(g.stickFullSpeed)) stickmin=\(n(g.stickMinimum)) cal=\(g.autoCalibrate ? "auto" : "off")")
        for (i, s) in [m.left, m.right].enumerated() {
            let mode: String, to: Int
            switch s.mode {
            case .stick: mode = "pad"; to = i
            case .otherStick: mode = "pad"; to = 1 - i
            case .mouse: mode = "mouse"; to = i
            case .flick: mode = "flick"; to = i
            case .keys: mode = "keys"; to = i
            case .off: mode = "none"; to = i
            }
            let k = s.keys.count == 4 ? s.keys : [13, 1, 0, 2]
            lines.append("stick \(i) mode=\(mode) to=\(to) dz=\(n(s.deadzone)) outer=\(n(s.outer)) sens=\(n(s.speed)) power=\(n(s.curve)) flick360=\(n(s.countsPerTurn)) flicktime=\(n(s.flickTime)) keys=\(k.map(String.init).joined(separator: ",")) invy=\(s.invertY ? 1 : 0)")
        }
        for t in 0..<2 { lines.append("trigger \(t) soft=\(n(m.triggers.soft)) full=\(n(m.triggers.full))") }
        for (l, layer) in m.layers.enumerated().prefix(8) {
            for input in Input.allCases {
                guard let b = layer.bindings[input], !b.isEmpty else { continue }
                var parts = ["bind \(l) \(input.rawValue)"]
                if let s = outs(b.press) { parts.append("press=\(s)") }
                if let s = outs(b.tap) { parts.append("tap=\(s)") }
                if let s = outs(b.hold) { parts.append("hold=\(s)") }
                if let s = outs(b.double) { parts.append("double=\(s)") }
                if let t = b.turbo, t > 0 { parts.append("turbo=\(t)") }
                if let w = b.together, let s = outs(b.togetherOutputs) { parts.append("sim=\(w.rawValue)"); parts.append("simout=\(s)") }
                if let h = b.holdTime { parts.append("holdtime=\(n(h))") }
                if let d = b.doubleTime { parts.append("doubletime=\(n(d))") }
                // A binding whose outputs all vanished (a removed layer) leaves the button as itself.
                if parts.count > 1 { lines.append(parts.joined(separator: " ")) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Ready-made profiles to start from

    public static func starters() -> [Profile] {
        var gyroAim = Profile(id: "starter-gyro-aim", name: "Gyro aim")
        gyroAim.gyro = { var g = Gyro(output: .mouse); g.sensitivity = 6; g.fastSensitivity = 12; g.slowSpeed = 5; g.fastSpeed = 75; g.smoothing = 3; g.tightening = 1.5; return g }()
        gyroAim.base[.rs] = .as(.gyroOff)

        var mk = Profile(id: "starter-keyboard-mouse", name: "Keyboard and mouse game")
        mk.leftStick = Stick(mode: .keys)
        mk.rightStick = { var s = Stick(mode: .mouse); s.speed = 1800; return s }()
        let pairs: [(Input, Output)] = [(.rt, .mouse(.left)), (.lt, .mouse(.right)), (.a, .key(49)), (.b, .key(8)), (.x, .key(15)),
                                        (.y, .key(14)), (.lb, .key(12)), (.rb, .key(3)), (.ls, .key(56)), (.rs, .key(59)),
                                        (.start, .key(53)), (.back, .key(48)), (.up, .key(18)), (.right, .key(19)), (.down, .key(20)), (.left, .key(21))]
        for (i, o) in pairs { mk.base[i] = .as(o) }

        var flick = Profile(id: "starter-flick", name: "Flick stick + gyro")
        flick.rightStick = Stick(mode: .flick)
        flick.gyro = { var g = Gyro(output: .mouse); g.sensitivity = 6; g.smoothing = 3; g.tightening = 1.5; return g }()
        return [gyroAim, mk, flick]
    }

    // MARK: Storage

    public static var profilesFile: URL { NokPaths.support.appendingPathComponent("controller-profiles.json") }
    public static var defaultFile: URL { NokPaths.support.appendingPathComponent("controller-profile-default") }
    static func folder(_ contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu", isDirectory: true) }
    public static func mapFile(_ contents: URL) -> URL { folder(contents).appendingPathComponent("pad-map") }
    static func choiceFile(_ contents: URL) -> URL { folder(contents).appendingPathComponent("pad-profile") }
    static func ownFile(_ contents: URL) -> URL { folder(contents).appendingPathComponent("pad-own.json") }

    public static func profiles(file: URL = profilesFile) -> [Profile] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
    }
    static func saveProfiles(_ p: [Profile], file: URL = profilesFile) throws {
        try NokPaths.ensure(file.deletingLastPathComponent())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }).write(to: file, options: .atomic)
    }
    public static func defaultID(file: URL = defaultFile) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public enum Choice: Equatable, Sendable {
        case followDefault, normal, own, profile(String), sameAsLauncher
    }

    public static func choice(contents: URL, shared: Bool = false) -> Choice {
        guard let raw = (try? String(contentsOf: choiceFile(contents), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return shared ? .sameAsLauncher : .followDefault
        }
        switch raw {
        case "launcher": return .sameAsLauncher
        case "default": return .followDefault
        case "none": return .normal
        case "own": return .own
        default: return .profile(raw)
        }
    }

    /// The game's own profile (one that isn't shared), when it has one.
    public static func own(contents: URL) -> Profile? {
        (try? Data(contentsOf: ownFile(contents))).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) }
    }

    /// The profile an environment uses now, with everything resolved (nil: controllers as they are).
    public static func effective(contents: URL, shared: Bool = false, all: [Profile]? = nil, defaultFile df: URL = defaultFile, file lf: URL = profilesFile) -> Profile? {
        let list = all ?? profiles(file: lf)
        switch choice(contents: contents, shared: shared) {
        case .followDefault: return defaultID(file: df).flatMap { id in list.first { $0.id == id } }
        case .normal, .sameAsLauncher: return nil
        case .own: return own(contents: contents)
        case .profile(let id): return list.first { $0.id == id } ?? defaultID(file: df).flatMap { d in list.first { $0.id == d } }
        }
    }

    /// Sets what an environment follows and writes its pad-map.
    public static func set(_ c: Choice, contents: URL, own p: Profile? = nil, file lf: URL = profilesFile, defaultFile df: URL = defaultFile) throws {
        try NokPaths.ensure(folder(contents))
        switch c {
        case .followDefault: try Data("default\n".utf8).write(to: choiceFile(contents), options: .atomic)
        case .normal: try Data("none\n".utf8).write(to: choiceFile(contents), options: .atomic)
        case .own:
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(p ?? own(contents: contents) ?? Profile(name: "This game")).write(to: ownFile(contents), options: .atomic)
            try Data("own\n".utf8).write(to: choiceFile(contents), options: .atomic)
        case .profile(let id): try Data((id + "\n").utf8).write(to: choiceFile(contents), options: .atomic)
        case .sameAsLauncher: try? FileManager.default.removeItem(at: choiceFile(contents))
        }
        write(contents: contents, shared: c == .sameAsLauncher, file: lf, defaultFile: df)
    }

    @discardableResult
    static func write(contents: URL, shared: Bool, all: [Profile]? = nil, file lf: URL = profilesFile, defaultFile df: URL = defaultFile) -> Bool {
        let list = all ?? profiles(file: lf)
        let f = mapFile(contents)
        guard let p = effective(contents: contents, shared: shared, all: list, defaultFile: df, file: lf) else {
            if FileManager.default.fileExists(atPath: f.path) { try? FileManager.default.removeItem(at: f); return true }
            return false
        }
        let text = compile(p, all: list)
        if (try? String(contentsOf: f, encoding: .utf8)) == text { return false }
        try? NokPaths.ensure(folder(contents))
        try? Data(text.utf8).write(to: f, options: .atomic)
        return true
    }

    /// Writes every environment's pad-map again (after a profile or the default changed). Returns how many changed.
    @discardableResult
    public static func refresh(environments: [URL], shared: [URL] = [], file lf: URL = profilesFile, defaultFile df: URL = defaultFile) -> Int {
        let list = profiles(file: lf), sharedSet = Set(shared)
        var n = 0
        for c in Set(environments).union(sharedSet) where write(contents: c, shared: sharedSet.contains(c), all: list, file: lf, defaultFile: df) { n += 1 }
        return n
    }

    @discardableResult
    public static func store(_ p: Profile, environments: [URL], shared: [URL] = [], file: URL = profilesFile, defaultFile df: URL = defaultFile) throws -> Int {
        var all = profiles(file: file)
        if let i = all.firstIndex(where: { $0.id == p.id }) { all[i] = p } else { all.append(p) }
        try saveProfiles(all, file: file)
        return refresh(environments: environments, shared: shared, file: file, defaultFile: df)
    }

    public static func setDefault(_ p: Profile?, environments: [URL], shared: [URL] = [], file df: URL = defaultFile, profilesFile lf: URL = profilesFile) throws {
        if let p { try NokPaths.ensure(df.deletingLastPathComponent()); try Data((p.id + "\n").utf8).write(to: df, options: .atomic) }
        else { try? FileManager.default.removeItem(at: df) }
        refresh(environments: environments, shared: shared, file: lf, defaultFile: df)
    }

    /// Removes a shared profile. Games using it keep a copy as their own; profiles built on it stop building on it.
    public static func delete(_ p: Profile, environments: [URL], shared: [URL] = [], file: URL = profilesFile, defaultFile df: URL = defaultFile) throws {
        var all = profiles(file: file)
        all.removeAll { $0.id == p.id }
        for i in all.indices { all[i].buildsOn.removeAll { $0 == p.id } }
        try saveProfiles(all, file: file)
        for c in Set(environments).union(shared) where choice(contents: c, shared: shared.contains(c)) == .profile(p.id) {
            var copy = p; copy.id = UUID().uuidString; copy.name = p.name
            try set(.own, contents: c, own: copy, file: file, defaultFile: df)
        }
        if defaultID(file: df) == p.id { try setDefault(nil, environments: environments, shared: shared, file: df, profilesFile: file) }
        else { refresh(environments: environments, shared: shared, file: file, defaultFile: df) }
    }

    /// Whether an environment has a profile in use (its controllers then go through Wine's SDL driver).
    public static func inUse(contents: URL) -> Bool {
        FileManager.default.fileExists(atPath: mapFile(contents).path) || FileManager.default.fileExists(atPath: routesFile(contents).path)
    }

    /// Wine's controller driver runs in a background Windows process (winedevice.exe), which only loads Nokcandu's
    /// helper when the Windows environment's own settings name it — launchers start their programs with the
    /// helper, but not Windows' background processes. With a profile in use, add it there (environment closed;
    /// it takes effect from its next start). A different value someone put there is left alone.
    @discardableResult
    public static func ensureDriverHelper(contents: URL) -> Bool {
        let helper = contents.appendingPathComponent("SharedSupport/nokcandu/nokcandu-rawmouse.dylib")
        let user = contents.appendingPathComponent("SharedSupport/prefix/user.reg")
        guard inUse(contents: contents), FileManager.default.fileExists(atPath: helper.path),
              FileManager.default.fileExists(atPath: user.path) else { return false }
        let text = (try? String(contentsOf: user, encoding: .utf8)) ?? ""
        if text.contains(RegistryText.string(helper.path).dropFirst().dropLast()) { return false }
        guard WineTools.ownedProcesses(contents: contents).isEmpty else { return false }
        return (try? RegistryText.set(user, key: "Environment", name: "DYLD_INSERT_LIBRARIES", value: RegistryText.string(helper.path)) { current in
            current == nil || current?.hasSuffix("nokcandu-rawmouse.dylib") == true
        }) == true
    }

    // MARK: Games inside shared launchers

    static func routesFile(_ host: URL) -> URL { folder(host).appendingPathComponent("pad-map.tsv") }

    /// Like key layouts: a launcher's programs that belong to a game with a profile of its own read that game's pad-map.
    @discardableResult
    public static func refreshRoutes(_ games: [InstalledGame]) -> Int {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var changed = 0
        var byHost: [URL: [InstalledGame]] = [:]
        for g in games where KeyRemap.isShared(g) { if let h = KeyRemap.contents(for: g) { byHost[h, default: []].append(g) } }
        for (host, members) in byHost {
            let names = (try? String(contentsOf: folder(host).appendingPathComponent("app-names.tsv"), encoding: .utf8)) ?? ""
            var lines: [String] = []
            for line in names.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, let g = members.first(where: { key($0.name) == key(parts[1]) }),
                      choice(contents: g.contents, shared: true) != .sameAsLauncher else { continue }
                lines.append(parts[0] + "\t" + mapFile(g.contents).path)
            }
            let text = lines.sorted().joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
            let f = routesFile(host)
            if lines.isEmpty {
                if FileManager.default.fileExists(atPath: f.path) { try? FileManager.default.removeItem(at: f); changed += 1 }
            } else if (try? String(contentsOf: f, encoding: .utf8)) != text {
                try? NokPaths.ensure(folder(host)); try? Data(text.utf8).write(to: f, options: .atomic); changed += 1
            }
        }
        return changed
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
