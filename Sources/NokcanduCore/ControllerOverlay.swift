import Foundation
import simd

/// A 3D controller drawn over the screen or in a window of its own (for capture in streaming software), showing the
/// buttons, sticks, triggers and trackpads as they're used and the controller turning with its gyro.
public struct ControllerOverlaySettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Over everything, games and streams included, never taking clicks.
        case onScreen
        /// A window of its own, for window capture in OBS and the like.
        case window
        case off
        public var title: String { switch self { case .onScreen: "Over games and streams"; case .window: "In its own window (for OBS)"; case .off: "Off" } }
    }
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// The controller last used.
        case automatic
        case steam2015 = "steamController2015", steam2026, xbox, switchPro, dualShock4
        public var title: String {
            switch self {
            case .automatic: "The controller in use"
            case .steam2015: "Steam Controller (2015)"
            case .steam2026: "Steam Controller (2026)"
            case .xbox: "Xbox"
            case .switchPro: "Switch Pro Controller"
            case .dualShock4: "DualShock 4 / DualSense"
            }
        }
        /// The drawing for a controller by the name macOS or its driver gives it: Xbox's shape for anything not
        /// recognised (the usual layout).
        public static func forName(_ name: String) -> Model {
            let n = name.lowercased()
            if n.contains("steam") { return n.contains("2026") ? .steam2026 : .steam2015 }
            // Before PlayStation's: a DualShock 4 calls itself "Wireless Controller", and so does Xbox's.
            if n.contains("xbox") || n.contains("xinput") { return .xbox }
            if n.contains("switch") || n.contains("pro controller") || n.contains("nintendo") || n.contains("joy-con") { return .switchPro }
            if n.contains("dualshock") || n.contains("dualsense") || n.contains("playstation") || n.contains("wireless controller") || n.contains("ps4") || n.contains("ps5") { return .dualShock4 }
            return .xbox
        }
    }
    public enum Background: String, Codable, CaseIterable, Sendable {
        case transparent, color
        public var title: String { switch self { case .transparent: "Transparent"; case .color: "Colour (for chroma key)" } }
    }
    public var mode: Mode = .off
    public var model: Model = .automatic
    /// Width in points; the height follows the controller's shape.
    public var size: Double = 320
    public var opacity: Double = 1
    /// Colours as "#RRGGBB".
    public var bodyColor = "#3C4048"
    public var buttonColor = "#7A808C"
    public var highlightColor = "#3FA9FF"
    public var background: Background = .transparent
    public var backgroundColor = "#00B140"
    /// Turning the drawn controller with the gyro, and how much of the real movement it shows (0…1.5).
    public var gyro = true
    public var gyroStrength: Double = 1
    /// How high above the controller it's seen from, in degrees above level (30 in front … 85 from above).
    public var viewAngle: Double = 54
    public static let viewAngles: ClosedRange<Double> = 30...85
    /// Where it sits over the screen: its centre as a fraction of the screen (0…1, from the bottom left).
    public var positionX: Double = 0.85
    public var positionY: Double = 0.15
    /// The screen it's placed on (its name); nil or not connected: the main screen.
    public var screen: String?
    /// Draw nothing while no controller is connected.
    public var hideWithoutController = true
    /// What each button, pad and stick does in the layer that's on, written on the drawing: never, always, while a
    /// button set to "Show mappings on the overlay" is held, or switched on and off by that button.
    public enum Mappings: String, Codable, CaseIterable, Sendable {
        case off, always, whileHeld, toggle
        public var title: String {
            switch self { case .off: "Off"; case .always: "Always"; case .whileHeld: "While its button is held"; case .toggle: "On and off with its button" }
        }
    }
    public var mappings: Mappings = .off
    /// The "Show mappings on the overlay" button also grows the controller big in the middle of the screen while
    /// mappings show (with "Always", while it's held), and shrinks it back to its place after.
    public var zoomWithMappings = true
    /// A small picture of its own for another device a profile uses (headphone motion: where the head points,
    /// its dead zone and the directions it's pressing), placed and shown separately from the controller.
    public struct DevicePanel: Codable, Hashable, Sendable {
        public var shown = false
        /// Its centre as a fraction of the screen (0…1, from the bottom left), and its width in points.
        public var positionX: Double = 0.12
        public var positionY: Double = 0.2
        public var size: Double = 150
        public static let sizes: ClosedRange<Double> = 80...400
        public init() {}
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self), base = DevicePanel()
            shown = (try? c.decode(Bool.self, forKey: .shown)) ?? base.shown
            positionX = (try? c.decode(Double.self, forKey: .positionX)) ?? base.positionX
            positionY = (try? c.decode(Double.self, forKey: .positionY)) ?? base.positionY
            size = (try? c.decode(Double.self, forKey: .size)) ?? base.size
            clamp()
        }
        public mutating func clamp() {
            positionX = min(1, max(0, positionX.isFinite ? positionX : 0.12))
            positionY = min(1, max(0, positionY.isFinite ? positionY : 0.2))
            size = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, size.isFinite ? size : 150))
        }
    }
    public var headMotion = DevicePanel()
    /// Holding Back and Start (View and Menu, Share and Options, − and +) for a second recentres the gyro.
    public static let recenterHold = 1.0

    public static let sizes: ClosedRange<Double> = 120...900
    public init() {}

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let base = ControllerOverlaySettings()
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? base.mode
        // "steam2015" was the only choice at first (November 19), not a choice: the controller in use instead.
        model = (try? c.decode(Model.self, forKey: .model)) ?? base.model
        size = (try? c.decode(Double.self, forKey: .size)) ?? base.size
        opacity = (try? c.decode(Double.self, forKey: .opacity)) ?? base.opacity
        bodyColor = (try? c.decode(String.self, forKey: .bodyColor)) ?? base.bodyColor
        buttonColor = (try? c.decode(String.self, forKey: .buttonColor)) ?? base.buttonColor
        highlightColor = (try? c.decode(String.self, forKey: .highlightColor)) ?? base.highlightColor
        background = (try? c.decode(Background.self, forKey: .background)) ?? base.background
        backgroundColor = (try? c.decode(String.self, forKey: .backgroundColor)) ?? base.backgroundColor
        gyro = (try? c.decode(Bool.self, forKey: .gyro)) ?? base.gyro
        gyroStrength = (try? c.decode(Double.self, forKey: .gyroStrength)) ?? base.gyroStrength
        viewAngle = (try? c.decode(Double.self, forKey: .viewAngle)) ?? base.viewAngle
        // 72 was the default while the drawing showed the real tilt (November 20); it's drawn level now.
        if viewAngle == 72 { viewAngle = base.viewAngle }
        positionX = (try? c.decode(Double.self, forKey: .positionX)) ?? base.positionX
        positionY = (try? c.decode(Double.self, forKey: .positionY)) ?? base.positionY
        screen = try? c.decodeIfPresent(String.self, forKey: .screen)
        hideWithoutController = (try? c.decode(Bool.self, forKey: .hideWithoutController)) ?? base.hideWithoutController
        mappings = (try? c.decode(Mappings.self, forKey: .mappings)) ?? base.mappings
        headMotion = (try? c.decode(DevicePanel.self, forKey: .headMotion)) ?? base.headMotion
        zoomWithMappings = (try? c.decode(Bool.self, forKey: .zoomWithMappings)) ?? base.zoomWithMappings
        // The first colours (November 19) were too dark to read on a dark screen.
        if bodyColor == "#2B2D31" && buttonColor == "#4A4D55" { bodyColor = base.bodyColor; buttonColor = base.buttonColor }
        clamp()
    }

    public mutating func clamp() {
        size = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, size.isFinite ? size : 320))
        opacity = min(1, max(0.1, opacity.isFinite ? opacity : 1))
        gyroStrength = min(1.5, max(0, gyroStrength.isFinite ? gyroStrength : 1))
        viewAngle = min(Self.viewAngles.upperBound, max(Self.viewAngles.lowerBound, viewAngle.isFinite ? viewAngle : 54))
        positionX = min(1, max(0, positionX.isFinite ? positionX : 0.85))
        positionY = min(1, max(0, positionY.isFinite ? positionY : 0.15))
        headMotion.clamp()
    }

    public static let key = "controllerOverlay"
    public static func load(_ defaults: UserDefaults = .standard) -> ControllerOverlaySettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return s
    }
    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// "#RRGGBB" as 0…1 components; nil when it isn't one.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
    public static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// What the overlay draws: one moment of a controller.
public struct ControllerOverlayInput: Equatable, Sendable {
    public var buttons: Set<PadProfiles.Input> = []
    /// Sticks and trackpads: x right, y up, −1…1.
    public var leftStick = SIMD2<Float>.zero, rightStick = SIMD2<Float>.zero
    public var leftPad = SIMD2<Float>.zero, rightPad = SIMD2<Float>.zero
    public var leftTouch = false, rightTouch = false
    /// 0…1.
    public var leftTrigger: Float = 0, rightTrigger: Float = 0
    public init() {}

    /// From held inputs and axes as the remapper has them: SDL's axes (0, 1 left stick, 2, 3 right stick, y down,
    /// ±32767; 4, 5 triggers 0…32767).
    public init(buttons: Set<PadProfiles.Input>, axes: [Int: Int]) {
        func v(_ n: Int) -> Float { Float(max(-32767, min(32767, axes[n] ?? 0))) / 32767 }
        self.buttons = buttons
        leftStick = .init(v(0), -v(1)); rightStick = .init(v(2), -v(3))
        leftTrigger = max(0, v(4)); rightTrigger = max(0, v(5))
    }

    public init(_ s: SteamControllerReport.State) {
        buttons = s.buttons
        leftStick = .init(s.stick.x, s.stick.y)
        rightStick = .init(s.rightStick.x, s.rightStick.y)
        leftPad = .init(s.leftPad.x, s.leftPad.y); rightPad = .init(s.rightPad.x, s.rightPad.y)
        leftTouch = s.leftTouch; rightTouch = s.rightTouch
        leftTrigger = s.leftTrigger; rightTrigger = s.rightTrigger
    }

    /// The same picture to the eye: stick and pad positions and triggers within a hundredth. Reports come in at
    /// hundreds a second; most change nothing that can be seen, and those aren't drawn again.
    public func looksLike(_ o: ControllerOverlayInput) -> Bool {
        func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }
        return buttons == o.buttons && leftTouch == o.leftTouch && rightTouch == o.rightTouch
            && near(leftStick, o.leftStick) && near(rightStick, o.rightStick)
            && (!leftTouch || near(leftPad, o.leftPad)) && (!rightTouch || near(rightPad, o.rightPad))
            && abs(leftTrigger - o.leftTrigger) < 0.01 && abs(rightTrigger - o.rightTrigger) < 0.01
    }
}

/// Which way the controller is facing, from its gyro and accelerometer.
///
/// The controller's axes, as the gyro and accelerometer report them: x to the right, y out of its face, z towards
/// the player (the same as the drawn model's). The gyro is integrated; gravity from the accelerometer slowly pulls
/// the tilt back to the truth (a gyro alone drifts), and with no compass to correct turning, the heading eases back
/// to the front by itself. `orientation` is relative to how the controller was held when it was last recentred.
public struct ControllerOverlayMotion: Sendable {
    /// Controller → world.
    public private(set) var attitude = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var reference = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var bias = SIMD3<Float>.zero
    private var last: Double?
    private var started = false
    /// How quickly gravity corrects the tilt, and how quickly the heading returns to the front (per second).
    public var gravityRate: Float = 2.0
    public var headingReturn: Float = 0.25
    /// The usual hold: how far the front is tipped up (radians) is drawn level. Learned while the controller is held
    /// still (per second, after a moment of stillness), so putting it down or holding it differently settles back to
    /// level by itself; recentring sets it at once.
    public var neutralReturn: Float = 0.6
    private var neutralPitch: Float = 0
    private var stillFor: Float = 0
    public init() {}

    static let up = SIMD3<Float>(0, 1, 0)

    /// `gyro` in radians per second, `acceleration` in g, `time` in seconds.
    public mutating func update(gyro: [Float], acceleration: [Float], at time: Double) {
        guard gyro.count == 3, acceleration.count == 3 else { return }
        let w = SIMD3(gyro[0], gyro[1], gyro[2]), a = SIMD3(acceleration[0], acceleration[1], acceleration[2])
        guard all(w .== w), all(a .== a) else { return }                    // NaN
        let g = simd_length(a)
        if !started {
            // Start from the tilt gravity shows, facing the front, and call that the rest position.
            if g > 0.5 { attitude = Self.rotation(from: a / g, to: Self.up) }
            reference = attitude; neutralPitch = Self.pitch(attitude); started = true; last = time; return
        }
        let dt = Float(min(0.05, max(0, time - (last ?? time)))); last = time
        guard dt > 0 else { return }
        // Bias: while turning slowly, follow the reading slowly (a resting gyro reads a little).
        var rate = w - bias
        if simd_length(rate) < 0.05 { bias += (w - bias) * min(1, dt * 0.5) }
        rate = SIMD3(abs(rate.x) < 0.007 ? 0 : rate.x, abs(rate.y) < 0.007 ? 0 : rate.y, abs(rate.z) < 0.007 ? 0 : rate.z)
        let angle = simd_length(rate) * dt
        if angle > 0 { attitude = simd_normalize(attitude * simd_quatf(angle: angle, axis: rate / simd_length(rate))) }
        // Gravity: where up should be in the controller's own terms, against where the accelerometer says it is,
        // trusted only while the controller isn't being shaken (close to 1 g).
        if g > 0.8 && g < 1.2 {
            let predicted = attitude.inverse.act(Self.up), measured = a / g
            let fix = Self.rotation(from: measured, to: predicted)
            let k = min(1, gravityRate * dt)
            attitude = simd_normalize(attitude * simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), fix, k))
        }
        // The usual hold: learned while still.
        stillFor = simd_length(rate) < 0.12 ? stillFor + dt : 0
        if neutralReturn > 0 && stillFor > 0.75 {
            neutralPitch += (Self.pitch(attitude) - neutralPitch) * min(1, neutralReturn * dt)
        }
        // Heading: turn back towards the rest heading about world up.
        if headingReturn > 0 {
            let yaw = Self.wrapped(Self.angles(attitude).yaw - Self.angles(reference).yaw)
            attitude = simd_normalize(simd_quatf(angle: -yaw * min(1, headingReturn * dt), axis: Self.up) * attitude)
        }
    }

    /// What the drawing applies: the controller's turn from the usual hold, in the controller's own terms. The usual
    /// hold (facing the rest heading, the front tipped up as it's usually held, level side to side) is drawn level;
    /// spinning it about its face turns the drawing about its up, tilting it about its length rolls the drawing about
    /// its length, tipping the front tips the drawing, however steeply it's held. (Measured in the room's terms, a
    /// controller held tipped up 50–60° mixes these: turning about the room's up is mostly rolling about its length.)
    /// `strength` scales it: 0 level and facing front.
    public func orientation(strength: Float = 1) -> simd_quatf {
        let hold = simd_quatf(angle: Self.angles(reference).yaw, axis: Self.up) * simd_quatf(angle: neutralPitch, axis: SIMD3(1, 0, 0))
        let r = simd_normalize(hold.inverse * attitude)
        return simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), r, max(0, strength))
    }

    /// A pose as turn about up, then bank (about the horizontal front-to-back line), then front tipped up:
    /// q = yaw(about y) · bank(about z) · pitch(about x). Taken from the controller's side (x) axis, which stays near
    /// level however steeply it's held.
    static func angles(_ q: simd_quatf) -> (yaw: Float, bank: Float, pitch: Float) {
        let x = q.act(SIMD3<Float>(1, 0, 0))
        let bank = asin(max(-1, min(1, x.y)))
        let yaw = x.x * x.x + x.z * x.z > 1e-8 ? atan2(-x.z, x.x) : 0
        let rest = simd_quatf(angle: -bank, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: -yaw, axis: up) * q
        let f = rest.act(SIMD3<Float>(0, 0, -1))
        return (yaw, bank, atan2(f.y, -f.z))
    }

    /// How far the front is tipped up beyond level, in radians (with the bank taken out).
    static func pitch(_ q: simd_quatf) -> Float { angles(q).pitch }

    static func wrapped(_ a: Float) -> Float { atan2(sin(a), cos(a)) }

    /// The way it faces now becomes the front, and the way it's held level.
    public mutating func recenter() { reference = attitude; neutralPitch = Self.pitch(attitude) }
    public mutating func reset() { self = ControllerOverlayMotion() }

    /// The turn about world up in a world-frame rotation (where it moves the forward direction, −z, to).
    static func heading(_ q: simd_quatf) -> Float {
        let f = q.act(SIMD3<Float>(0, 0, -1))
        guard f.x * f.x + f.z * f.z > 1e-6 else { return 0 }
        return atan2(-f.x, -f.z)
    }

    /// The shortest rotation taking unit vector `a` to unit vector `b`.
    static func rotation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let d = simd_dot(a, b)
        if d > 0.999999 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        if d < -0.999999 {
            let axis = abs(a.x) < 0.9 ? simd_normalize(simd_cross(a, SIMD3(1, 0, 0))) : simd_normalize(simd_cross(a, SIMD3(0, 1, 0)))
            return simd_quatf(angle: .pi, axis: axis)
        }
        return simd_quatf(from: a, to: b)
    }
}
