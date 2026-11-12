import Foundation

/// Opt-in headphone input source, saved in profiles rather than global preferences.
public struct PadHeadMotionSettings: Codable, Hashable, Sendable {
    public enum Activation: String, Codable, CaseIterable, Sendable {
        case always, whileHeld, inLayer
        public var title: String {
            switch self { case .always: "Whenever this profile is active"; case .whileHeld: "While a controller button is held"; case .inLayer: "Only in a selected layer" }
        }
    }
    public enum Output: String, Codable, CaseIterable, Sendable {
        case mouse, leftStick, rightStick
        public var title: String { switch self { case .mouse: "Mouse"; case .leftStick: "Left stick mappings"; case .rightStick: "Right stick mappings" } }
    }
    public var output: Output
    /// Radians from center to full stick deflection.
    public var stickRange: Double
    public var activation: Activation
    public var activationButton: PadProfiles.Input
    public var activationLayer: String
    public var included: Bool
    public var enabled: Bool
    public var sensitivity: Double
    public var smoothing: Double
    public var deadZone: Double
    public var invertX: Bool
    public var invertY: Bool
    public init(included: Bool = true, enabled: Bool = true, sensitivity: Double = 1200, smoothing: Double = 0.5,
                deadZone: Double = 0.001, invertX: Bool = false, invertY: Bool = false,
                activation: Activation = .always, activationButton: PadProfiles.Input = .lb, activationLayer: String = "", output: Output = .mouse, stickRange: Double = 0.25) {
        self.output = output; self.stickRange = stickRange
        self.activation = activation; self.activationButton = activationButton; self.activationLayer = activationLayer
        self.included = included; self.enabled = enabled; self.sensitivity = sensitivity; self.smoothing = smoothing
        self.deadZone = deadZone; self.invertX = invertX; self.invertY = invertY
    }
    private enum CodingKeys: String, CodingKey { case included, enabled, sensitivity, smoothing, deadZone, invertX, invertY, activation, activationButton, activationLayer, output, stickRange }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(included: try c.decodeIfPresent(Bool.self, forKey: .included) ?? true,
                  enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  sensitivity: try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 1200,
                  smoothing: try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.5,
                  deadZone: try c.decodeIfPresent(Double.self, forKey: .deadZone) ?? 0.001,
                  invertX: try c.decodeIfPresent(Bool.self, forKey: .invertX) ?? false,
                  invertY: try c.decodeIfPresent(Bool.self, forKey: .invertY) ?? false,
                  activation: try c.decodeIfPresent(Activation.self, forKey: .activation) ?? .always,
                  activationButton: try c.decodeIfPresent(PadProfiles.Input.self, forKey: .activationButton) ?? .lb,
                  activationLayer: try c.decodeIfPresent(String.self, forKey: .activationLayer) ?? "",
                  output: try c.decodeIfPresent(Output.self, forKey: .output) ?? .mouse,
                  stickRange: try c.decodeIfPresent(Double.self, forKey: .stickRange) ?? 0.25)
    }
    /// Gate only headphone output; controller gyro and the button's mapping stay independent.
    public func permitsMotion(held: Set<PadProfiles.Input>, layer: String?) -> Bool {
        guard included, enabled else { return false }
        switch activation {
        case .always: return true
        case .whileHeld: return PadProfiles.Input.padButtons.contains(activationButton) && held.contains(activationButton)
        case .inLayer:
            guard !activationLayer.isEmpty, let layer else { return false }
            return activationLayer.caseInsensitiveCompare(layer) == .orderedSame
        }
    }
    public var normalized: Self {
        func bound(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : fallback
        }
        return Self(included: included, enabled: enabled, sensitivity: bound(sensitivity, 100...5000, 1200),
                    smoothing: bound(smoothing, 0.05...1, 0.5), deadZone: bound(deadZone, 0...0.01, 0.001),
                    invertX: invertX, invertY: invertY, activation: activation,
                    activationButton: activationButton, activationLayer: activationLayer, output: output,
                    stickRange: bound(stickRange, 0.05...1, 0.25))
    }
}

extension PadProfiles {
    public static func headMotion(_ profile: Profile, all: [Profile]) -> PadHeadMotionSettings? {
        top(profile, all: all, \.headMotion)?.normalized
    }
}
