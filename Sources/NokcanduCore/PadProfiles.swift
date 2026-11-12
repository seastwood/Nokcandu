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
        /// A stick's directions, when the stick works as four buttons (StickMode.directions).
        case lsup, lsdown, lsleft, lsright, rsup, rsdown, rsleft, rsright
        /// The touchpad's zones (top left, top right, bottom left, bottom right): touched, and clicked.
        case tz1, tz2, tz3, tz4, tc1, tc2, tc3, tc4
        /// Tilting the controller.
        case tiltleft, tiltright, tiltfwd, tiltback
        /// A trackpad used as four directions, and its outer edge (original Steam Controller).
        case lpup, lpdown, lpleft, lpright, lpedge, rpup, rpdown, rpleft, rpright, rpedge
        public var id: String { rawValue }
        /// Not a button on the controller: a stick direction, a touchpad zone or a tilt.
        public var isVirtual: Bool { isStickDirection || Self.touchZones.contains(self) || Self.tilts.contains(self) || Self.padZones.contains(self) }
        /// Up, down, left, right of the left (0) or right (1) trackpad, and that pad's edge.
        public static func padDirections(_ side: Int) -> [Input] { side == 0 ? [.lpup, .lpdown, .lpleft, .lpright] : [.rpup, .rpdown, .rpleft, .rpright] }
        public static func padEdge(_ side: Int) -> Input { side == 0 ? .lpedge : .rpedge }
        public static let padZones: [Input] = padDirections(0) + [.lpedge] + padDirections(1) + [.rpedge]
        public static let touchZones: [Input] = [.tz1, .tz2, .tz3, .tz4, .tc1, .tc2, .tc3, .tc4]
        public static let tilts: [Input] = [.tiltleft, .tiltright, .tiltfwd, .tiltback]

        public var isTrigger: Bool { [.lt, .rt, .ltfull, .rtfull].contains(self) }
        public var isStickDirection: Bool { Self.stickDirections(0).contains(self) || Self.stickDirections(1).contains(self) }
        /// Up, down, left, right of the left (0) or right (1) stick.
        public static func stickDirections(_ s: Int) -> [Input] { s == 0 ? [.lsup, .lsdown, .lsleft, .lsright] : [.rsup, .rsdown, .rsleft, .rsright] }
        /// Inputs that are real controller buttons (can be sent to the game as a button).
        public static var padButtons: [Input] { allCases.filter { !$0.isTrigger && !$0.isVirtual } }

        /// The name printed on this controller's button. Nintendo controllers report their buttons by the letter
        /// printed on them (A is the right-hand button), so the letters stay and only the picture moves them.
        public func title(_ family: Controllers.Family? = nil) -> String {
            switch (self, family) {
            case (.a, .playstation): "Cross"; case (.b, .playstation): "Circle"; case (.x, .playstation): "Square"; case (.y, .playstation): "Triangle"
            case (.lb, .playstation): "L1"; case (.rb, .playstation): "R1"; case (.lt, .playstation): "L2"; case (.rt, .playstation): "R2"
            case (.ltfull, .playstation): "L2 (full pull)"; case (.rtfull, .playstation): "R2 (full pull)"
            case (.ls, .playstation): "L3"; case (.rs, .playstation): "R3"
            case (.back, .playstation): "Create"; case (.start, .playstation): "Options"; case (.guide, .playstation): "PS"
            case (.touchpad, .valve): "Left trackpad click"
            case (.rs, .valve): "Right trackpad click"
            case (.guide, .valve): "Steam"
            case (.back, .valve): "Back"; case (.start, .valve): "Start"
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
            case (.lsup, _): "Left stick up"; case (.lsdown, _): "Left stick down"; case (.lsleft, _): "Left stick left"; case (.lsright, _): "Left stick right"
            case (.rsup, _): "Right stick up"; case (.rsdown, _): "Right stick down"; case (.rsleft, _): "Right stick left"; case (.rsright, _): "Right stick right"
            case (.tz1, _): "Touch top left"; case (.tz2, _): "Touch top right"; case (.tz3, _): "Touch bottom left"; case (.tz4, _): "Touch bottom right"
            case (.tc1, _): "Click top left"; case (.tc2, _): "Click top right"; case (.tc3, _): "Click bottom left"; case (.tc4, _): "Click bottom right"
            case (.tiltleft, _): "Tilt left"; case (.tiltright, _): "Tilt right"; case (.tiltfwd, _): "Tilt forward"; case (.tiltback, _): "Tilt back"
            case (.lpup, _): "Left pad up"; case (.lpdown, _): "Left pad down"; case (.lpleft, _): "Left pad left"; case (.lpright, _): "Left pad right"; case (.lpedge, _): "Left pad edge"
            case (.rpup, _): "Right pad up"; case (.rpdown, _): "Right pad down"; case (.rpleft, _): "Right pad left"; case (.rpright, _): "Right pad right"; case (.rpedge, _): "Right pad edge"
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
        case keyToggle(Int), mouseToggle(MouseButton), padToggle(Input), triggerToggle(right: Bool)
        case key(Int)                   // Mac key code
        case mouse(MouseButton)
        case wheel(up: Bool)
        case gyroOn, gyroOff, gyroToggle
        case layerHold(String), layerToggle(String)     // layer names
        case macro(String)                              // a macro's id
        case menu(String)                               // a radial menu's id (open while held)
        case keyboard                                   // the on-screen keyboard
        case calibrate                                  // measure the gyro's resting drift now
        case rumble                                     // buzz the controller
        case nothing

        /// Outputs that can remain down between two physical presses.
        public var toggledOutput: Output? {
            switch self {
            case .key(let k): .keyToggle(k)
            case .mouse(let m): .mouseToggle(m)
            case .pad(let i): .padToggle(i)
            case .trigger(let r): .triggerToggle(right: r)
            case .keyToggle, .mouseToggle, .padToggle, .triggerToggle, .nothing: self
            default: nil
            }
        }
        public var heldOutput: Output {
            switch self {
            case .keyToggle(let k): .key(k)
            case .mouseToggle(let m): .mouse(m)
            case .padToggle(let i): .pad(i)
            case .triggerToggle(let r): .trigger(right: r)
            default: self
            }
        }
        public var isHeldToggle: Bool {
            switch self { case .keyToggle, .mouseToggle, .padToggle, .triggerToggle: true; default: false }
        }
        public var token: String {
            switch self {
            case .pad(let i): "pad:\(i.rawValue)"
            case .trigger(let r): "trig:\(r ? "r" : "l")"
            case .padToggle(let i): "padtoggle:\(i.rawValue)"
            case .triggerToggle(let r): "trigtoggle:\(r ? "r" : "l")"
            case .keyToggle(let k): "keytoggle:\(k)"
            case .mouseToggle(let m): "mousetoggle:\(m.rawValue)"
            case .key(let k): "key:\(k)"
            case .mouse(let m): "mouse:\(m.rawValue)"
            case .wheel(let up): "wheel:\(up ? "up" : "down")"
            case .gyroOn: "gyro:on"; case .gyroOff: "gyro:off"; case .gyroToggle: "gyro:toggle"
            case .layerHold(let n): "layerhold:\(n)"; case .layerToggle(let n): "layertoggle:\(n)"
            case .macro(let id): "macro:\(id)"; case .menu(let id): "menu:\(id)"; case .keyboard: "keyboard"; case .calibrate: "calibrate"; case .rumble: "rumble"
            case .nothing: "none"
            }
        }
        public init?(token: String) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let v = parts.count > 1 ? parts[1] : ""
            switch parts.first ?? "" {
            case "pad": guard let i = Input(rawValue: v), !i.isTrigger, !i.isVirtual else { return nil }; self = .pad(i)
            case "macro": guard !v.isEmpty else { return nil }; self = .macro(v)
            case "menu": guard !v.isEmpty else { return nil }; self = .menu(v)
            case "keyboard": self = .keyboard
            case "calibrate": self = .calibrate
            case "rumble": self = .rumble
            case "trig": self = .trigger(right: v == "r")
            case "padtoggle": guard let i = Input(rawValue: v), Input.padButtons.contains(i) else { return nil }; self = .padToggle(i)
            case "trigtoggle": guard v == "l" || v == "r" else { return nil }; self = .triggerToggle(right: v == "r")
            case "keytoggle": guard let k = Int(v), (0..<128).contains(k) else { return nil }; self = .keyToggle(k)
            case "mousetoggle": guard let m = MouseButton(rawValue: v) else { return nil }; self = .mouseToggle(m)
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
            case .padToggle(let i): "Toggle " + i.title(family)
            case .triggerToggle(let r): "Toggle " + Input(rawValue: r ? "rt" : "lt")!.title(family)
            case .keyToggle(let k): "Toggle " + PadProfiles.keyTitle(k)
            case .mouseToggle(let m): "Toggle " + m.title
            case .key(let k): PadProfiles.keyTitle(k)
            case .mouse(let m): m.title
            case .wheel(let up): up ? "Scroll up" : "Scroll down"
            case .gyroOn: "Gyro on while held"; case .gyroOff: "Gyro off while held"; case .gyroToggle: "Gyro on/off"
            case .layerHold(let n): "\(n) while held"; case .layerToggle(let n): "\(n) on/off"
            case .macro: "Macro"; case .menu: "Radial menu"; case .keyboard: "On-screen keyboard"; case .calibrate: "Calibrate the gyro"; case .rumble: "Rumble"
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
        /// Explicit editor behavior; nil preserves existing output-specific semantics.
        public var togglePress: Bool?
        public var togglesOnPress: Bool { togglePress == true || (press.contains(where: \.isHeldToggle) && press.allSatisfy { $0.isHeldToggle || $0 == .nothing }) }
        public var pressOutputs: [Output] {
            guard togglePress == true else { return press }
            let outputs = press.compactMap(\.toggledOutput)
            return outputs.isEmpty ? [.nothing] : outputs
        }
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
        /// A layer's own stick and gyro settings while it's on (nil: as underneath).
        public var leftStick: Stick?
        public var rightStick: Stick?
        public var gyro: Gyro?
        /// A layer's own trackpad settings (original Steam Controller) while it's on (nil: as the base layer).
        public var steamLeftTrackpad: PadSteamTrackpadSettings?
        public var steamRightTrackpad: PadSteamTrackpadSettings?
        /// The controller's light while this layer is on (DualSense, DualShock 4), "#RRGGBB".
        public var color: String?
        public init(id: String = UUID().uuidString, name: String, bindings: [String: Binding] = [:]) { self.id = id; self.name = name; self.bindings = bindings }
        public subscript(_ i: Input) -> Binding? {
            get { bindings[i.rawValue] }
            set { bindings[i.rawValue] = newValue?.isEmpty == false ? newValue : nil }
        }
        /// A device's button, hat direction or axis (Device.key).
        public subscript(key k: String) -> Binding? {
            get { bindings[k] }
            set { bindings[k] = newValue?.isEmpty == false ? newValue : nil }
        }
    }

    // MARK: Extra devices

    /// What a device's axis does besides counting as a button when pushed far enough.
    public enum AxisMode: String, CaseIterable, Codable, Hashable, Sendable {
        case off, stick, mouse
        public var title: String { switch self { case .off: "Nothing (buttons only)"; case .stick: "A controller stick or trigger"; case .mouse: "The mouse" } }
    }
    public enum AxisTarget: String, CaseIterable, Codable, Hashable, Sendable {
        case lx, ly, rx, ry, lt, rt
        public func title(_ family: Controllers.Family? = nil) -> String {
            switch self {
            case .lx: "Left stick, left and right"; case .ly: "Left stick, up and down"
            case .rx: "Right stick, left and right"; case .ry: "Right stick, up and down"
            case .lt: Input.lt.title(family); case .rt: Input.rt.title(family)
            }
        }
        var engine: String { rawValue }
    }
    public struct DeviceAxis: Codable, Hashable, Sendable {
        public var mode: AxisMode = .off
        public var target: AxisTarget?
        /// Mouse: moves it up and down (else left and right).
        public var vertical: Bool?
        public var invert: Bool?
        /// Rests at one end (a pedal, a throttle without a centre detent): 0 at rest, 1 all the way.
        public var restsAtEnd: Bool?
        public var deadzone: Double?
        /// Mouse: counts per second at full push, and how sharply speed rises.
        public var speed: Double?
        public var curve: Double?
        /// How far it's pushed to count as a button press (0…1).
        public var pressAt: Double?
        public init(mode: AxisMode = .off) { self.mode = mode }
        public var isDefault: Bool { self == DeviceAxis() }
    }
    /// A joystick, throttle, pedals, wheel, button box or another controller, combined with the controller in one
    /// profile. Recognised by its maker and model codes (and which one, with several identical ones).
    public struct Device: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        /// What you call it ("Left stick", "Pedals").
        public var name: String
        /// What the device calls itself.
        public var productName: String
        public var vendorID: Int
        public var productID: Int
        /// With several identical devices, which one (0 the first).
        public var nth: Int?
        /// A controller with the usual layout (buttons named like the controller's).
        public var gamepad: Bool?
        /// A controller that becomes part of the main one: what it doesn't set acts as the main controller's own
        /// buttons and sticks (two halves held in each hand, or two controllers for one player).
        public var joined: Bool?
        /// Axis number → what it does.
        public var axes: [String: DeviceAxis]?
        /// What it has, to show it while it's unplugged.
        public var buttonCount: Int?
        public var axisNames: [String]?
        public var hasHat: Bool?
        public init(id: String = UUID().uuidString, name: String, productName: String, vendorID: Int, productID: Int, nth: Int? = nil,
                    gamepad: Bool? = nil, buttonCount: Int? = nil, axisNames: [String]? = nil, hasHat: Bool? = nil) {
            self.id = id; self.name = name; self.productName = productName; self.vendorID = vendorID; self.productID = productID
            self.nth = nth; self.gamepad = gamepad; self.buttonCount = buttonCount; self.axisNames = axisNames; self.hasHat = hasHat
        }
        public var isGamepad: Bool { gamepad == true }
        public func axis(_ n: Int) -> DeviceAxis { axes?[String(n)] ?? DeviceAxis() }
        public mutating func setAxis(_ n: Int, _ a: DeviceAxis) {
            var m = axes ?? [:]; m[String(n)] = a.isDefault ? nil : a; axes = m.isEmpty ? nil : m
        }
        /// Where a device's input is kept in a layer's bindings: "b0"… a button, "hu"/"hr"/"hd"/"hl" the hat,
        /// "a2p"/"a2n" axis 3 pushed past its press point one way or the other.
        public func key(_ k: String) -> String { "dev.\(id).\(k)" }
        public static func parse(_ key: String) -> (device: String, input: String)? {
            let p = key.split(separator: ".", maxSplits: 2).map(String.init)
            return p.count == 3 && p[0] == "dev" ? (p[1], p[2]) : nil
        }
        public static let hatKeys = ["hu", "hr", "hd", "hl"]
        public static let maxButtons = 32, maxAxes = 8

        public var buttons: Int { isGamepad ? 21 : min(buttonCount ?? 12, Self.maxButtons) }
        public var axisCount: Int { isGamepad ? 6 : min(axisNames?.count ?? 4, Self.maxAxes) }
        public var hat: Bool { !isGamepad && (hasHat ?? false) }

        public func axisTitle(_ n: Int, family: Controllers.Family? = nil) -> String {
            if isGamepad { return ["Left stick, left and right", "Left stick, up and down", "Right stick, left and right", "Right stick, up and down", Input.lt.title(family), Input.rt.title(family)][min(n, 5)] }
            let names = axisNames ?? []
            return names.indices.contains(n) ? names[n] : "Axis \(n + 1)"
        }
        /// "Button 3", "Hat up", "Throttle, pushed up"… for a key from `key(_:)`.
        public func inputTitle(_ k: String, family: Controllers.Family? = nil) -> String {
            if k.hasPrefix("b"), let n = Int(k.dropFirst()) {
                return isGamepad && n < Input.allCases.count ? Input.allCases[n].title(family) : "Button \(n + 1)"
            }
            if k.hasPrefix("h"), let i = Self.hatKeys.firstIndex(of: k) { return ["Hat up", "Hat right", "Hat down", "Hat left"][i] }
            if k.hasPrefix("a"), let n = Int(k.dropFirst().dropLast()) {
                let plus = k.hasSuffix("p")
                if isGamepad {
                    switch n {
                    case 0: return plus ? "Left stick pushed right" : "Left stick pushed left"
                    case 1: return plus ? "Left stick pushed down" : "Left stick pushed up"
                    case 2: return plus ? "Right stick pushed right" : "Right stick pushed left"
                    case 3: return plus ? "Right stick pushed down" : "Right stick pushed up"
                    default: return axisTitle(n, family: family) + " pulled"
                    }
                }
                let name = axisTitle(n), a = axis(n)
                if a.restsAtEnd == true { return name + " pressed" }
                switch name {
                case "X": return plus ? "Pushed right (X)" : "Pushed left (X)"
                case "Y": return plus ? "Pulled back (Y)" : "Pushed forward (Y)"
                case "Twist", "Rz": return plus ? "Twisted right" : "Twisted left"
                default: return name + (plus ? " +" : " −")
                }
            }
            return k
        }
    }

    public enum StickMode: String, CaseIterable, Codable, Hashable, Sendable {
        case stick, otherStick, mouse, flick, keys, directions, scroll, off
        public var title: String {
            switch self {
            case .stick: "Stick"; case .otherStick: "The other stick"; case .mouse: "Mouse"
            case .flick: "Flick stick"; case .keys: "Keys"; case .directions: "Four directions, each set on its own"
            case .scroll: "Scrolling"; case .off: "Nothing"
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
        /// Left/right and up/down speed, 1 = as set (stored only when changed, so older profiles still read).
        public var xScale: Double?
        public var yScale: Double?
        /// Mouse: extra speed while held at the edge (0.5 = up to 1.5×), and how long it takes to get there.
        public var edgeBoost: Double?
        public var edgeBoostTime: Double?
        /// Scrolling: lines per second at full push.
        public var scrollSpeed: Double?
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
        public var xScale: Double?
        public var yScale: Double?
        /// How much turning (yaw) and tilting (roll) move left and right (1 = fully). Unset: from `turn`.
        public var yawAmount: Double?
        public var rollAmount: Double?
        /// A One Euro filter: steady when turning slowly, no lag when turning fast. Its slow-turn cut-off (Hz; lower is
        /// steadier) and how quickly it opens up with speed.
        public var filter: Bool?
        public var filterMinCutoff: Double?
        public var filterBeta: Double?
        public var yaw: Double { yawAmount ?? (turn == .roll ? 0 : 1) }
        public var roll: Double { rollAmount ?? (turn == .yaw ? 0 : 1) }
        public init(output: GyroOutput = .off) { self.output = output }
    }
    public enum TouchMode: String, CaseIterable, Codable, Hashable, Sendable {
        case click, mouse, scroll, zones
        public var title: String {
            switch self { case .click: "Just its click"; case .mouse: "Mouse (two fingers scroll)"; case .scroll: "Scrolling"; case .zones: "Four zones (touch and click)" }
        }
    }
    public struct Touchpad: Codable, Hashable, Sendable {
        public var mode: TouchMode = .click
        /// Mouse movement across the whole pad, and lines scrolled from top to bottom.
        public var speed: Double?
        public var scrollSpeed: Double?
        public init(mode: TouchMode = .click) { self.mode = mode }
    }
    public struct Tilt: Codable, Hashable, Sendable {
        /// How far it's tilted to count (degrees).
        public var angle: Double?
        public var invertX: Bool?
        public var invertY: Bool?
        public init() {}
    }
    /// A series of things done one after another by one press.
    public struct Macro: Codable, Hashable, Identifiable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case press, down, up, wait, text, chord
            public var title: String { switch self { case .press: "Press"; case .down: "Hold down"; case .up: "Let go"; case .wait: "Wait"; case .text: "Type"; case .chord: "Simultaneous chord" } }
        }
        public struct Step: Codable, Hashable, Sendable {
            public var kind: Kind
            public var output: Output?
            public var ms: Int?
            public var text: String?
            public var outputs: [Output]?
            public init(_ kind: Kind, output: Output? = nil, ms: Int? = nil, text: String? = nil) { self.kind = kind; self.output = output; self.ms = ms; self.text = text }
        }
        public var id: String
        public var name: String
        public var steps: [Step]
        public var eventDelayMS: Int?
        public init(id: String = UUID().uuidString, name: String, steps: [Step] = [], eventDelayMS: Int? = 50) {
            self.id = id; self.name = name; self.steps = steps; self.eventDelayMS = eventDelayMS
        }
    }
    /// Buttons pressed one after another (up, up, down…) doing something.
    public struct Sequence: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var inputs: [Input]
        /// Most time between two presses (seconds).
        public var stepTime: Double?
        public var outputs: [Output]
        public init(id: String = UUID().uuidString, name: String, inputs: [Input] = [], outputs: [Output] = []) { self.id = id; self.name = name; self.inputs = inputs; self.outputs = outputs }
    }
    /// A ring of up to eight choices: hold its button, point a stick, let go.
    public struct RadialMenu: Codable, Hashable, Identifiable, Sendable {
        public struct Slice: Codable, Hashable, Sendable {
            public var title: String
            public var outputs: [Output]
            public init(title: String, outputs: [Output] = []) { self.title = title; self.outputs = outputs }
            public func displayTitle(_ family: Controllers.Family? = nil) -> String {
                if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
                let actions = outputs.filter { $0 != .nothing }.map { $0.title(family) }
                return actions.isEmpty ? "Choose an action" : actions.joined(separator: " + ")
            }
        }
        public var id: String
        public var name: String
        /// 0 the left stick, 1 the right, 2 relative mouse/gyro direction.
        public var stick: Int
        public var slices: [Slice]
        public init(id: String = UUID().uuidString, name: String, stick: Int = 1, slices: [Slice] = []) { self.id = id; self.name = name; self.stick = stick; self.slices = slices }
    }

    public struct Triggers: Codable, Hashable, Sendable {
        /// How far a trigger is pulled to count as pressed, and as fully pulled (0…1).
        public var soft = 0.3, full = 0.95
        public init() {}
    }

    public enum ControllerSource: String, Codable, CaseIterable, Sendable { case automatic, steamUSB }

    /// Display metadata belongs to this profile, not to whichever device is connected.
    /// Do not inherit it from a base mapping profile or replay a shared legacy UI choice.
    public static func controllerLabelFamily(_ profile: Profile, all: [Profile], connected: Controllers.Family?) -> Controllers.Family? {
        if let saved = profile.controllerLabels {
            if saved == "xbox" { return nil }
            if let family = Controllers.Family(rawValue:saved) { return family }
        }
        return top(profile,all:all,\.controllerSource) == .steamUSB ? .valve : connected
    }

    public enum RoutingMode: String, Codable, CaseIterable, Sendable {
        case legacy, native, hybrid, remapping, selective, hybridAll, remappingAll
        /// In the order shown, simplest first.
        public static let shown: [RoutingMode] = [.legacy, .remappingAll, .hybridAll, .native, .remapping, .hybrid, .selective]
        public var title: String {
            switch self {
            case .legacy: "Standard"
            case .remappingAll: "Only what this profile maps"
            case .hybridAll: "Mappings and the controller itself"
            case .native: "The controller itself, no mappings"
            case .remapping: "Buttons: only what's mapped"
            case .hybrid: "Buttons: mapped and the button itself"
            case .selective: "Choose for each control"
            }
        }
    }
    public enum ButtonRoute: String, Codable, CaseIterable, Sendable {
        case native, mapped, both, disabled
        public var title: String {
            switch self { case .native: "The control itself"; case .mapped: "Its mapping"; case .both: "Both"; case .disabled: "Off" }
        }
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
        /// Devices combined with the controller in this profile (up to four).
        public var devices: [Device]?
        /// Compatible headphone motion is a separate singleton source, not a fabricated HID slot.
        public var headMotion: PadHeadMotionSettings?
        /// Explicit original wired-controller source; absent retains existing GameController behavior.
        public var controllerSource: ControllerSource?
        /// UI names/diagram style for this profile only; nil follows its source/connected device.
        public var controllerLabels: String?
        /// Original Steam Controller right pad: nil preserves the existing stick mapping.
        public var steamRightTrackpad: PadSteamTrackpadSettings?
        public var steamLeftTrackpad: PadSteamTrackpadSettings?
        public var touchpad: Touchpad?
        public var tilt: Tilt?
        public var macros: [Macro]?
        public var sequences: [Sequence]?
        public var menus: [RadialMenu]?
        /// A short rumble when the layer changes.
        public var routingMode: RoutingMode?
        public var buttonRoutes: [String: ButtonRoute]?
        public var controlRoutes: [String: ButtonRoute]?
        public var rumbleOnLayer: Bool?
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

    /// What layers set besides buttons, across the stack, by layer name (lowercased).
    public static func layerSettings(_ p: Profile, all: [Profile]) -> [String: (left: Stick?, right: Stick?, gyro: Gyro?, color: String?)] {
        var out: [String: (left: Stick?, right: Stick?, gyro: Gyro?, color: String?)] = [:]
        for q in stack(p, all: all) {
            for (i, layer) in q.layers.enumerated() {
                let name = i == 0 ? "base" : layer.name.lowercased()
                var cur = out[name] ?? (nil, nil, nil, nil)
                if i > 0, let s = layer.leftStick { cur.left = s }
                if i > 0, let s = layer.rightStick { cur.right = s }
                if i > 0, let g = layer.gyro { cur.gyro = g }
                if let c = layer.color { cur.color = c }
                out[name] = cur
            }
        }
        return out
    }
    /// The top setting of the stack that has one.
    public static func top<T>(_ p: Profile, all: [Profile], _ k: KeyPath<Profile, T?>) -> T? {
        stack(p, all: all).reversed().lazy.compactMap { $0[keyPath: k] }.first
    }
    /// Macros, sequences or menus across the stack (by id; the profile on top wins).
    public static func collected<T: Identifiable>(_ p: Profile, all: [Profile], _ k: KeyPath<Profile, [T]?>) -> [T] where T.ID == String {
        var out: [T] = []
        for q in stack(p, all: all) { for x in q[keyPath: k] ?? [] { out.removeAll { $0.id == x.id }; out.append(x) } }
        return out
    }

    /// The devices a profile combines (the top one of its stack that sets any).
    public static func devices(_ p: Profile, all: [Profile]) -> [Device] {
        stack(p, all: all).last { $0.devices != nil }?.devices ?? []
    }
    /// Device bindings across the stack, by layer name (lowercased; the first layer is "base").
    public static func deviceBindings(_ p: Profile, all: [Profile]) -> [String: [String: Binding]] {
        var out: [String: [String: Binding]] = [:]
        for q in stack(p, all: all) {
            for (i, layer) in q.layers.enumerated() {
                let name = i == 0 ? "base" : layer.name.lowercased()
                for (k, b) in layer.bindings where k.hasPrefix("dev.") { out[name, default: [:]][k] = b }
            }
        }
        return out
    }

    public static func compile(_ p: Profile, all: [Profile]) -> String {
        let routing = top(p, all: all, \.routingMode) ?? .legacy
        if routing == .native { return "nokpad 1\n" }
        let m = merged(p, all: all)
        let layerIndex = Dictionary(m.layers.enumerated().map { ($0.element.name.lowercased(), $0.offset) }, uniquingKeysWith: { a, _ in a })
        let macros = Array(collected(p, all: all, \.macros).prefix(16)), menus = Array(collected(p, all: all, \.menus).prefix(8))
        let macroIndex = Dictionary(macros.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let menuIndex = Dictionary(menus.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        func token(_ x: Output) -> String? {
            switch x {
            case .layerHold(let n): return layerIndex[n.lowercased()].map { "layer:hold:\($0)" }
            case .layerToggle(let n): return layerIndex[n.lowercased()].map { "layer:toggle:\($0)" }
            case .macro(let id): return macroIndex[id].map { "macro:\($0)" }
            case .menu(let id): return menuIndex[id].map { "menu:\($0)" }
            default: return x.token
            }
        }
        func outs(_ o: [Output]) -> String? {
            let t = o.compactMap(token)
            return t.isEmpty ? nil : t.joined(separator: ",")
        }
        func n(_ d: Double) -> String { String(format: "%g", d) }
        var lines = ["nokpad 1"]
        func gyroLine(_ g: Gyro, layer: Int) -> String {
            let gout: String = { switch g.output { case .off: "off"; case .mouse: "mouse"; case .leftStick: "lstick"; case .rightStick: "rstick" } }()
            return "gyro out=\(gout) on=\(g.startsOn ? 1 : 0) min=\(n(g.sensitivity)) max=\(n(g.fastSensitivity ?? g.sensitivity)) lo=\(n(g.slowSpeed)) hi=\(n(g.fastSpeed)) smooth=\(n(g.smoothing)) tight=\(n(g.tightening)) invx=\(g.invertX ? 1 : 0) invy=\(g.invertY ? 1 : 0) yaw=\(g.turn.rawValue) stickfull=\(n(g.stickFullSpeed)) stickmin=\(n(g.stickMinimum)) cal=\(g.autoCalibrate ? "auto" : "off") xs=\(n(g.xScale ?? 1)) ys=\(n(g.yScale ?? 1)) yw=\(n(g.yaw)) rw=\(n(g.roll)) euro=\(g.filter == true ? 1 : 0) mincut=\(n(g.filterMinCutoff ?? 5)) beta=\(n(g.filterBeta ?? 0.05))" + (layer > 0 ? " layer=\(layer)" : "")
        }
        func stickLine(_ i: Int, _ s: Stick, layer: Int) -> String {
            let mode: String, to: Int
            switch s.mode {
            case .stick: mode = "pad"; to = i
            case .otherStick: mode = "pad"; to = 1 - i
            case .mouse: mode = "mouse"; to = i
            case .flick: mode = "flick"; to = i
            case .keys: mode = "keys"; to = i
            case .directions: mode = "dirs"; to = i
            case .scroll: mode = "scroll"; to = i
            case .off: mode = "none"; to = i
            }
            let k = s.keys.count == 4 ? s.keys : [13, 1, 0, 2]
            let sens = s.mode == .scroll ? (s.scrollSpeed ?? 20) : s.speed
            return "stick \(i) mode=\(mode) to=\(to) dz=\(n(s.deadzone)) outer=\(n(s.outer)) sens=\(n(sens)) power=\(n(s.curve)) flick360=\(n(s.countsPerTurn)) flicktime=\(n(s.flickTime)) keys=\(k.map(String.init).joined(separator: ",")) invy=\(s.invertY ? 1 : 0) xs=\(n(s.xScale ?? 1)) ys=\(n(s.yScale ?? 1)) ramp=\(n(s.edgeBoost ?? 0)) ramptime=\(n(s.edgeBoostTime ?? 0.4))" + (layer > 0 ? " layer=\(layer)" : "")
        }
        lines.append(gyroLine(m.gyro, layer: 0))
        for (i, s) in [m.left, m.right].enumerated() { lines.append(stickLine(i, s, layer: 0)) }
        let ls = layerSettings(p, all: all)
        for (l, layer) in m.layers.enumerated().prefix(8) where l > 0 {
            guard let set = ls[layer.name.lowercased()] else { continue }
            if let s = set.left { lines.append(stickLine(0, s, layer: l)) }
            if let s = set.right { lines.append(stickLine(1, s, layer: l)) }
            if let g = set.gyro { lines.append(gyroLine(g, layer: l)) }
        }
        if let t = top(p, all: all, \.touchpad), t.mode != .click {
            lines.append("touch mode=\(t.mode == .zones ? "zones" : t.mode.rawValue) sens=\(n(t.speed ?? 1500)) scroll=\(n(t.scrollSpeed ?? 12))")
        }
        if let t = top(p, all: all, \.tilt) {
            lines.append("tilt angle=\(n(t.angle ?? 30)) invx=\(t.invertX == true ? 1 : 0) invy=\(t.invertY == true ? 1 : 0)")
        }
        for (i, mac) in macros.enumerated() {
            var parts = ["macro \(i)"]
            for (stepIndex, st) in mac.steps.enumerated() {
                var stepParts: [String] = []
                if stepIndex > 0, st.kind != .wait, mac.steps[stepIndex - 1].kind != .wait, let delay = mac.eventDelayMS, delay > 0 { stepParts.append("wait:\(min(60000, delay))") }
                switch st.kind {
                case .chord:
                    let chord = (st.outputs ?? []).filter(\.macroFree).prefix(6).compactMap(token)
                    stepParts += chord.map { "down:\($0)" }
                    stepParts.append("wait:30")
                    stepParts += chord.reversed().map { "up:\($0)" }
                case .press: if let o = st.output, o.macroFree, let t = token(o) { stepParts += ["down:\(t)", "wait:30", "up:\(t)"] }
                case .down: if let o = st.output, o.macroFree, let t = token(o) { stepParts.append("down:\(t)") }
                case .up: if let o = st.output, o.macroFree, let t = token(o) { stepParts.append("up:\(t)") }
                case .wait: stepParts.append("wait:\(max(0, min(60000, st.ms ?? 100)))")
                case .text: if let t = st.text, !t.isEmpty { stepParts.append("text:" + t.utf8.map { String(format: "%02x", $0) }.joined()) }
                }
                guard parts.count + stepParts.count <= 49 else { break }
                parts += stepParts
            }
            lines.append(parts.joined(separator: " "))
        }
        for (i, q) in collected(p, all: all, \.sequences).prefix(16).enumerated() where q.inputs.count >= 2 {
            if let o = outs(q.outputs) { lines.append("seq \(i) in=\(q.inputs.prefix(8).map(\.rawValue).joined(separator: ",")) step=\(n(q.stepTime ?? 0.4)) out=\(o)") }
        }
        for (i, mn) in menus.enumerated() {
            var parts = ["menu \(i) stick=\(mn.stick == 0 ? 0 : mn.stick == 2 ? 2 : 1)"]
            for (j, sl) in mn.slices.prefix(8).enumerated() { parts.append("s\(j)=\(outs(sl.outputs) ?? "none")") }
            lines.append(parts.joined(separator: " "))
        }
        for t in 0..<2 { lines.append("trigger \(t) soft=\(n(m.triggers.soft)) full=\(n(m.triggers.full))") }
        let devs = Array(devices(p, all: all).prefix(4))
        var slotOf: [String: Int] = [:]
        for (i, d) in devs.enumerated() {
            let slot = i + 1
            slotOf[d.id] = slot
            lines.append("device \(slot) vendor=\(d.vendorID) product=\(d.productID) nth=\(d.nth ?? 0) kind=\(d.isGamepad ? "gamepad" : "joystick") join=\(d.isGamepad && d.joined == true ? 1 : 0)")
            for (k, a) in (d.axes ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let ax = Int(k), ax >= 0, ax < Device.maxAxes else { continue }
                let mode: String, to: String
                switch a.mode {
                case .off: mode = "off"; to = "lx"
                case .stick: mode = "pad"; to = (a.target ?? .lx).engine
                case .mouse: mode = "mouse"; to = a.vertical == true ? "y" : "x"
                }
                lines.append("axis \(slot) \(ax) mode=\(mode) to=\(to) inv=\(a.invert == true ? 1 : 0) half=\(a.restsAtEnd == true ? 1 : 0) dz=\(n(a.deadzone ?? 0.05)) sens=\(n(a.speed ?? 1500)) power=\(n(a.curve ?? 1.5)) press=\(n(a.pressAt ?? 0.5))")
            }
        }
        let devBinds = deviceBindings(p, all: all)
        for (l, layer) in m.layers.enumerated().prefix(8) {
            var entries: [(String, Binding)] = Input.allCases.compactMap { i in layer.bindings[i].map { (i.rawValue, $0) } }
            for (k, b) in (devBinds[l == 0 ? "base" : layer.name.lowercased()] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let parsed = Device.parse(k), let slot = slotOf[parsed.device] else { continue }
                entries.append(("d\(slot)\(parsed.input)", b))
            }
            for (name, b) in entries {
                guard !b.isEmpty else { continue }
                var parts = ["bind \(l) \(name)"]
                if let s = outs(b.pressOutputs) { parts.append("press=\(s)") }
                if let s = outs(b.tap) { parts.append("tap=\(s)") }
                if let s = outs(b.hold) { parts.append("hold=\(s)") }
                if let s = outs(b.double) { parts.append("double=\(s)") }
                if let t = b.turbo, t > 0, !b.togglesOnPress { parts.append("turbo=\(t)") }
                if let w = b.together, let s = outs(b.togetherOutputs) { parts.append("sim=\(w.rawValue)"); parts.append("simout=\(s)") }
                if let h = b.holdTime { parts.append("holdtime=\(n(h))") }
                if let d = b.doubleTime { parts.append("doubletime=\(n(d))") }
                // A binding whose outputs all vanished (a removed layer) leaves the button as itself.
                if parts.count > 1 { lines.append(parts.joined(separator: " ")) }
            }
        }
        if routing == .hybrid || routing == .hybridAll {
            for i in Input.padButtons { lines.append("route \(i.rawValue) both") }
        } else if routing == .remapping || routing == .remappingAll {
            for i in Input.padButtons { lines.append("route \(i.rawValue) mapped") }
        } else if routing == .selective {
            var routes: [String: ButtonRoute] = [:]
            for q in stack(p, all: all) { routes.merge(q.buttonRoutes ?? [:]) { _, new in new } }
            for i in Input.padButtons {
                lines.append("route \(i.rawValue) \((routes[i.rawValue] ?? .mapped).rawValue)")
            }
        }
        if routing == .selective {
            var routes: [String: ButtonRoute] = [:]
            for q in stack(p, all: all) { routes.merge(q.controlRoutes ?? [:]) { _, new in new } }
            for key in ["lstick", "rstick", "lt", "rt", "gyro", "touch", "tilt"] {
                if let route = routes[key] { lines.append("route \(key) \(route.rawValue)") }
            }
        }
        if routing == .hybridAll || routing == .remappingAll {
            let route = routing == .hybridAll ? "both" : "mapped"
            for key in ["lstick", "rstick", "lt", "rt", "gyro", "touch", "tilt"] { lines.append("route \(key) \(route)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Sharing

    /// A profile (and the ones it builds on) as text to send someone: settings only, like everything in a profile.
    public static func exportText(_ p: Profile, all: [Profile]) -> String {
        struct Pack: Encodable { let nokcanduControllerProfiles = 1; let profiles: [Profile] }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? enc.encode(Pack(profiles: stack(p, all: all)))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    /// Profiles from shared text (or a single profile's JSON), with new ids so nothing is overwritten, names made
    /// unique, and what they build on pointing at the imported copies. The last one is the shared profile itself.
    public static func importText(_ text: String, existing: [Profile]) throws -> [Profile] {
        struct Pack: Decodable { let nokcanduControllerProfiles: Int?; let profiles: [Profile] }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = body.range(of: #"```(?:json)?\s*\n[\s\S]*?```"#, options: .regularExpression) {
            body = String(body[r]).replacingOccurrences(of: #"^```(?:json)?\s*\n"#, with: "", options: .regularExpression).replacingOccurrences(of: "```", with: "")
        }
        let data = Data(body.utf8)
        let list: [Profile]
        if let pack = try? JSONDecoder().decode(Pack.self, from: data) { list = pack.profiles }
        else if let one = try? JSONDecoder().decode(Profile.self, from: data) { list = [one] }
        else { throw NokError("That isn't a Nokcandu controller profile.") }
        guard !list.isEmpty else { throw NokError("That isn't a Nokcandu controller profile.") }
        var ids: [String: String] = [:]
        for q in list { ids[q.id] = UUID().uuidString }
        var names = Set(existing.map(\.name))
        return list.map { q in
            var c = q
            c.id = ids[q.id]!
            c.buildsOn = q.buildsOn.compactMap { b in ids[b] ?? (existing.contains { $0.id == b } ? b : nil) }
            var n = q.name, i = 2
            while names.contains(n) { n = "\(q.name) (\(i))"; i += 1 }
            c.name = n; names.insert(n)
            return c
        }
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

    /// The original Steam Controller, ready to play a keyboard-and-mouse game: the right pad aims as a
    /// trackball, the left pad walks with W A S D and sprints at its edge, and the triggers click. Without a
    /// mapped click the controller has none (its built-in one is off while Nokcandu reads it).
    public static func steamStarter() -> Profile {
        var p = Profile(id: "starter-steam-controller", name: "Steam Controller")
        p.controllerSource = .steamUSB
        p.steamRightTrackpad = { var s = PadSteamTrackpadSettings(mode: .trackball); s.sensitivity = 650; return s }()
        p.steamLeftTrackpad = { var s = PadSteamTrackpadSettings(mode: .directions); s.edge = 0.2; return s }()
        let pairs: [(Input, Output)] = [(.rt, .mouse(.left)), (.lt, .mouse(.right)), (.a, .key(49)), (.b, .key(8)), (.x, .key(15)),
                                        (.y, .key(14)), (.lb, .key(12)), (.rb, .key(3)), (.start, .key(53)), (.back, .key(48)),
                                        (.lpup, .key(13)), (.lpdown, .key(1)), (.lpleft, .key(0)), (.lpright, .key(2)), (.lpedge, .key(56)),
                                        (.paddle1, .key(49)), (.paddle2, .key(59))]
        for (i, o) in pairs { p.base[i] = .as(o) }
        return p
    }

    /// For the Mac itself: right stick moves the pointer, triggers click, left stick scrolls by keys.
    public static func desktopStarter() -> Profile {
        var p = Profile(id: "starter-desktop", name: "Pointer and Clicks")
        p.rightStick = { var s = Stick(mode: .mouse); s.speed = 1400; s.curve = 2; return s }()
        p.leftStick = { var s = Stick(mode: .keys); s.keys = [126, 125, 123, 124]; return s }()       // arrow keys
        let pairs: [(Input, Output)] = [(.rt, .mouse(.left)), (.lt, .mouse(.right)), (.a, .key(36)), (.b, .key(53)),
                                        (.rb, .wheel(up: false)), (.lb, .wheel(up: true)), (.x, .key(49)), (.y, .key(48)),
                                        (.up, .key(126)), (.down, .key(125)), (.left, .key(123)), (.right, .key(124))]
        for (i, o) in pairs { p.base[i] = .as(o) }
        p.base[.rb]?.turbo = 60; p.base[.lb]?.turbo = 60
        return p
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
    private static func preserveBeforeV2(_ encoded: Data, file: URL) throws {
        guard let text = String(data: encoded, encoding: .utf8),
              ["keytoggle:", "mousetoggle:", "padtoggle:", "trigtoggle:", "togglePress", "routingMode", "controlRoutes", "eventDelayMS", "\"chord\"", "\"headMotion\""].contains(where: text.contains) else { return }
        let backup = file.appendingPathExtension("pre-controller-v2")
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: backup.path) {
            try Data(contentsOf: file).write(to: backup, options: .withoutOverwriting)
        }
    }
    static func saveProfiles(_ p: [Profile], file: URL = profilesFile) throws {
        try NokPaths.ensure(file.deletingLastPathComponent())
        // A read failure is not an empty library. Preserve damaged/newer data for recovery.
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: file))
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try enc.encode(p.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        try preserveBeforeV2(encoded, file: file)
        try encoded.write(to: file, options: .atomic)
    }
    private static func saveOwn(_ p: Profile, contents: URL) throws {
        let file = ownFile(contents)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: file))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(p)
        try preserveBeforeV2(data, file: file)
        try data.write(to: file, options: .atomic)
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

    /// The own-profile persistence scope supplying this game, including shared-launcher inheritance.
    public static func ownSource(contents: URL, shared: Bool, inheritedHost: URL?) -> URL? {
        switch choice(contents: contents, shared: shared) {
        case .own: return contents
        case .sameAsLauncher:
            guard let host = inheritedHost, host.resolvingSymlinksInPath().standardizedFileURL.path != contents.resolvingSymlinksInPath().standardizedFileURL.path,
                  choice(contents: host) == .own else { return nil }
            return host
        default: return nil
        }
    }

    /// Sets what an environment follows and writes its pad-map.
    public static func set(_ c: Choice, contents: URL, own p: Profile? = nil, file lf: URL = profilesFile, defaultFile df: URL = defaultFile) throws {
        try NokPaths.ensure(folder(contents))
        switch c {
        case .followDefault: try Data("default\n".utf8).write(to: choiceFile(contents), options: .atomic)
        case .normal: try Data("none\n".utf8).write(to: choiceFile(contents), options: .atomic)
        case .own:
            try saveOwn(p ?? own(contents: contents) ?? Profile(name: "This game"), contents: contents)
            try Data("own\n".utf8).write(to: choiceFile(contents), options: .atomic)
        case .profile(let id): try Data((id + "\n").utf8).write(to: choiceFile(contents), options: .atomic)
        case .sameAsLauncher: try? FileManager.default.removeItem(at: choiceFile(contents))
        }
        _ = try writeChecked(contents: contents, shared: c == .sameAsLauncher, file: lf, defaultFile: df)
    }

    @discardableResult
    static func write(contents: URL, shared: Bool, all: [Profile]? = nil, file lf: URL = profilesFile, defaultFile df: URL = defaultFile) -> Bool {
        (try? writeChecked(contents: contents, shared: shared, all: all, file: lf, defaultFile: df)) ?? false
    }
    @discardableResult
    static func writeChecked(contents: URL, shared: Bool, all: [Profile]? = nil, file lf: URL = profilesFile, defaultFile df: URL = defaultFile) throws -> Bool {
        let list = all ?? profiles(file: lf)
        let f = mapFile(contents), fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: f.path)) != nil {
            throw NokError("The controller map is linked. It was preserved; restore a regular managed map before updating it.")
        }
        if fm.fileExists(atPath: f.path), try fm.attributesOfItem(atPath: f.path)[.type] as? FileAttributeType != .typeRegular {
            throw NokError("The controller map path is not a regular file. It was preserved.")
        }
        guard let p = effective(contents: contents, shared: shared, all: list, defaultFile: df, file: lf) else {
            if fm.fileExists(atPath: f.path) { try fm.removeItem(at: f); return true }
            return false
        }
        let text = compile(p, all: list)
        if (try? String(contentsOf: f, encoding: .utf8)) == text { return false }
        try NokPaths.ensure(folder(contents))
        try Data(text.utf8).write(to: f, options: .atomic)
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
    static func refreshChecked(environments: [URL], shared: [URL], file: URL, defaultFile: URL) throws -> Int {
        let list = profiles(file: file), sharedSet = Set(shared)
        var changed = 0, failed = 0
        for c in Set(environments).union(sharedSet) {
            do { if try writeChecked(contents: c, shared: sharedSet.contains(c), all: list, file: file, defaultFile: defaultFile) { changed += 1 } }
            catch { failed += 1 }
        }
        guard failed == 0 else { throw NokError("Profile settings were saved, but \(failed) game controller map(s) could not be updated. Check the game folders and retry; linked or non-file maps are preserved.") }
        return changed
    }

    @discardableResult
    public static func store(_ p: Profile, environments: [URL], shared: [URL] = [], file: URL = profilesFile, defaultFile df: URL = defaultFile) throws -> Int {
        var all = profiles(file: file)
        if let i = all.firstIndex(where: { $0.id == p.id }) { all[i] = p } else { all.append(p) }
        try saveProfiles(all, file: file)
        return try refreshChecked(environments: environments, shared: shared, file: file, defaultFile: df)
    }

    public static func setDefault(_ p: Profile?, environments: [URL], shared: [URL] = [], file df: URL = defaultFile, profilesFile lf: URL = profilesFile) throws {
        if let p { try NokPaths.ensure(df.deletingLastPathComponent()); try Data((p.id + "\n").utf8).write(to: df, options: .atomic) }
        else { try? FileManager.default.removeItem(at: df) }
        _ = try refreshChecked(environments: environments, shared: shared, file: lf, defaultFile: df)
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
        else { _ = try refreshChecked(environments: environments, shared: shared, file: file, defaultFile: df) }
    }

    /// Profiles also applied inside Wine's controller driver (what the game sees as the controller), unless
    /// "pad-driver-off" is present in the environment.
    public static func driverInUse(contents: URL) -> Bool {
        !FileManager.default.fileExists(atPath: folder(contents).appendingPathComponent("pad-driver-off").path) && inUse(contents: contents)
    }

    /// Whether an environment has a profile in use.
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
        guard driverInUse(contents: contents), FileManager.default.fileExists(atPath: helper.path),
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

extension PadProfiles.Output {
    /// Can be a step of a macro (a macro can't start a macro, open a menu or the keyboard).
    public var macroFree: Bool {
        switch self { case .macro, .menu, .keyboard: false; default: true }
    }
}
