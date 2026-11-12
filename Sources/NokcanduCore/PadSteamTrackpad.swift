import Foundation

public struct PadSteamTrackpadSettings: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case existing, mouse, trackball, directions
        /// The pad moves the pointer itself (rather than acting as mappings or directions).
        public var movesPointer: Bool { self == .mouse || self == .trackball }
        public var title: String { switch self {
        case .directions: "Four directions"
        case .existing: "Existing mappings"
        case .mouse: "Trackpad mouse"
        case .trackball: "Trackball mouse"
        } }
    }
    public var mode: Mode = .existing
    public var sensitivity: Double = 1500
    public var halfLife: Double = 0.16
    public var invertY: Bool = false
    public var sensitivityX: Double?
    public var sensitivityY: Double?
    public var steadiness: Double?
    public var gyroWhileTouched: Bool?
    public var touchFeedback: Double?
    public var movementFeedback: Double?
    public var hapticRate: Double?
    public var hapticFollowsMovement: Bool?
    public var hapticSpacingMS: Double?
    /// Adaptive smoothing, 0…1 (0: raw). Steadies a resting or slow finger and gets out of the way as it speeds up.
    public var smoothing: Double?
    /// Degrees the pad's axes are turned to match the thumb's sweep (Valve's own drivers use 15° inward).
    public var rotation: Double?
    /// How much of the pad's radius, from the rim inward, counts as its edge (0: no edge). The edge is an
    /// input of its own, held while the finger is there, in every pad behavior.
    public var edge: Double?
    /// Four directions: how far from the centre a direction starts (part of the radius).
    public var deadzone: Double?
    public static let defaultDeadzone = 0.25
    public static let defaultSmoothing = 0.4
    public static func defaultRotation(side: Int) -> Double { side == 0 ? -15 : 15 }
    public init(mode: Mode = .existing) { self.mode = mode }
}

/// Relative pad motion and time-based momentum; no OS input is posted here.
/// Coordinates are normalized 0...1, y down. Touch cancels inertia immediately.
public struct PadSteamTrackpad {
    public struct Motion: Equatable { public var x: Int = 0, y: Int = 0 }
    private var down = false
    private var x = 0.0, y = 0.0, sampleTime: Double?, tickTime: Double?, movedTime: Double?
    private var vx = 0.0, vy = 0.0, restX = 0.0, restY = 0.0
    private var steadyX = 0.0, steadyY = 0.0
    private var edgeEntryTime: Double?
    private var velocityHistory: [(time: Double, x: Double, y: Double)] = []
    private var filterX = 0.0, filterY = 0.0, rateX = 0.0, rateY = 0.0, landed = 0.0
    public init() {}
    public mutating func reset() { self = Self() }
    private mutating func motion(_ x: Double, _ y: Double) -> Motion {
        restX += x; restY += y
        let result = Motion(x: Int(restX), y: Int(restY))
        restX -= Double(result.x); restY -= Double(result.y)
        return result
    }
    private static func steady(_ delta: Double, amount: Double, remainder: inout Double) -> Double {
        guard amount > 0 else { remainder = 0; return delta }
        remainder += delta
        guard abs(remainder) > amount else { return 0 }
        let movement = remainder - (remainder > 0 ? amount : -amount)
        remainder -= movement
        return movement
    }
    public mutating func touch(down next: Bool, x nextX: Double, y nextY: Double, at now: Double, settings: PadSteamTrackpadSettings) -> Motion {
        guard settings.mode.movesPointer, now.isFinite, nextX.isFinite, nextY.isFinite else { reset(); return Motion() }
        guard sampleTime == nil || now >= sampleTime! else { reset(); return Motion() }
        let px = min(1,max(0,nextX)), py = min(1,max(0,nextY))
        func speed(_ value: Double) -> Double { value.isFinite ? min(10000,max(100,value)) : 1500 }
        let wasDown = down
        defer { down = next; x = px; y = py; sampleTime = now; if next || wasDown { tickTime = now } }
        if next && !down {
            vx = 0; vy = 0; restX = 0; restY = 0; movedTime = nil; steadyX = 0; steadyY = 0; edgeEntryTime = nil; velocityHistory = []
            filterX = px; filterY = py; rateX = 0; rateY = 0; landed = now
            return Motion()
        }
        if !next {
            if wasDown {
                if settings.mode != .trackball || movedTime == nil || now - movedTime! > 0.05 { vx = 0; vy = 0 }
                else {
                    // Lift can roll the fingertip along the pad edge before the
                    // touch bit clears. Do not launch momentum from that last spike.
                    // At a physical edge, the main coordinate can saturate while
                    // a rolling fingertip continues sideways for longer than 18 ms.
                    // For a short edge dwell, launch from the approach, not that roll.
                    let edgeEnd = edgeEntryTime.flatMap { now - $0 <= 0.12 ? $0 - 0.001 : nil }
                    let end = edgeEnd ?? now - 0.018
                    var samples = velocityHistory.filter { $0.time >= end - 0.08 && $0.time <= end }
                    if samples.count < 2 && edgeEnd == nil { samples = velocityHistory.count >= 3 ? Array(velocityHistory.dropLast()) : velocityHistory }
                    if !samples.isEmpty {
                        func median(_ values: [Double]) -> Double { let v = values.sorted(); return v.count % 2 == 0 ? (v[v.count/2-1] + v[v.count/2])/2 : v[v.count/2] }
                        vx = median(samples.map(\.x)); vy = median(samples.map(\.y))
                    }
                }
            }
            return Motion()
        }
        guard let previous = sampleTime, now - previous > 0, now - previous <= 0.1 else { vx = 0; vy = 0; velocityHistory = []; return Motion() }
        func edge(_ x: Double, _ y: Double) -> Bool { x < 0.02 || x > 0.98 || y < 0.02 || y > 0.98 }
        if edge(px,py) {
            if !edge(x,y) { edgeEntryTime = now }
        } else { edgeEntryTime = nil }
        let requested = settings.steadiness ?? 0
        let steadiness = requested.isFinite ? min(5,max(0,requested)) : 0
        var moveX = px - x, moveY = py - y
        let strength = settings.smoothing.map { $0.isFinite ? min(1,max(0,$0)) : 0 } ?? 0
        if strength > 0 {
            // A filter whose cutoff rises with finger speed: sensor noise under a resting or slow finger is
            // held back, while a deliberate movement passes with a millisecond or two of lag. Unlike a dead
            // band it never has to be "pushed through" when the finger changes direction.
            let dt = max(0.0005, now - previous)
            func blend(_ cutoff: Double) -> Double { let tau = 1 / (2 * Double.pi * cutoff); return dt / (dt + tau) }
            let rateBlend = blend(15)
            rateX += rateBlend * ((px - x) / dt - rateX); rateY += rateBlend * ((py - y) / dt - rateY)
            let a = blend(25 * pow(0.1, strength) + 80 * (rateX * rateX + rateY * rateY).squareRoot())
            let nextX = filterX + a * (px - filterX), nextY = filterY + a * (py - filterY)
            // The contact patch grows for a moment as a finger lands, which shifts its centre: ease in.
            let settle = min(1, max(0, (now - landed) / 0.03))
            moveX = (nextX - filterX) * settle; moveY = (nextY - filterY) * settle
            filterX = nextX; filterY = nextY
        }
        if let degrees = settings.rotation, degrees.isFinite, degrees != 0 {
            // Screen coordinates (y down): a positive angle turns the pad's axes the way Valve does for the right pad.
            let r = min(45,max(-45,degrees)) * Double.pi / 180, c = cos(r), sn = sin(r)
            (moveX, moveY) = (c * moveX + sn * moveY, -sn * moveX + c * moveY)
        }
        let dx = Self.steady(moveX * speed(settings.sensitivityX ?? settings.sensitivity), amount:steadiness, remainder:&steadyX)
        let dy = Self.steady(moveY * speed(settings.sensitivityY ?? settings.sensitivity) * (settings.invertY ? -1 : 1), amount:steadiness, remainder:&steadyY)
        if abs(dx) + abs(dy) > 0.01 {
            let dt = max(0.001,now - previous)
            vx = min(20000,max(-20000,dx / dt)); vy = min(20000,max(-20000,dy / dt)); movedTime = now
            velocityHistory.append((now,vx,vy))
            velocityHistory = Array(velocityHistory.filter { $0.time >= now - 0.2 }.suffix(32))
        } else if let movedTime, now - movedTime > 0.05 { vx = 0; vy = 0 }
        return motion(dx,dy)
    }
    public mutating func tick(at now: Double, settings: PadSteamTrackpadSettings) -> Motion {
        guard now.isFinite else { reset(); return Motion() }
        defer { tickTime = now }
        guard !down, settings.mode == .trackball, let previous = tickTime else { return Motion() }
        let dt = now - previous
        guard dt >= 0, dt <= 0.1 else { reset(); return Motion() }
        let halfLife = settings.halfLife.isFinite ? min(1,max(0.02,settings.halfLife)) : 0.16
        let decay = log(2) / halfLife, factor = exp(-decay * dt)
        let dx = vx * (1 - factor) / decay, dy = vy * (1 - factor) / decay
        vx *= factor; vy *= factor
        if abs(vx) + abs(vy) < 0.5 { vx = 0; vy = 0 }
        return motion(dx,dy)
    }
}

extension PadProfiles {
    /// A layer's own pad settings (the last profile in the stack that gives that layer some), if any.
    public static func layerSteamTrackpad(_ side: Int, layer: String, profile: Profile, all: [Profile]) -> PadSteamTrackpadSettings? {
        stack(profile, all: all).compactMap { q in
            q.layers.dropFirst().first { $0.name.caseInsensitiveCompare(layer) == .orderedSame }.flatMap { side == 0 ? $0.steamLeftTrackpad : $0.steamRightTrackpad }
        }.last
    }
    /// The pad's settings as they apply: in `layer` (nil or unknown: the base layer) with routing and the
    /// recommended defaults filled in.
    public static func steamTrackpad(_ side: Int, profile: Profile, all: [Profile], layer: String? = nil) -> PadSteamTrackpadSettings {
        var settings = layer.flatMap { layerSteamTrackpad(side, layer: $0, profile: profile, all: all) }
            ?? (side == 0 ? top(profile, all: all, \.steamLeftTrackpad) : top(profile, all: all, \.steamRightTrackpad)) ?? PadSteamTrackpadSettings()
        let routing = top(profile, all: all, \.routingMode) ?? .legacy
        let key = side == 0 ? "touch" : "rstick"
        let route = stack(profile, all: all).compactMap { $0.controlRoutes?[key] }.last
        if routing == .native || (routing == .selective && (route == .native || route == .disabled)) { settings.mode = .existing }
        // Unset means the recommended feel; an explicit 0 keeps raw, unturned movement.
        if settings.smoothing == nil { settings.smoothing = PadSteamTrackpadSettings.defaultSmoothing }
        if settings.rotation == nil { settings.rotation = PadSteamTrackpadSettings.defaultRotation(side: side) }
        return settings
    }
}

/// Which of a pad's direction and edge inputs are held for a finger position. No output is made here.
/// Coordinates are the pad's own −1…1 with y up; the pad angle is applied first, as for pointer movement.
public struct PadSteamPadZones {
    public private(set) var held: Set<PadProfiles.Input> = []
    public init() {}
    public mutating func reset() { held = [] }
    public static func edgeSize(_ settings: PadSteamTrackpadSettings) -> Double {
        guard let e = settings.edge, e.isFinite else { return 0 }
        return e < 0.02 ? 0 : min(0.6, e)
    }
    public static func deadzone(_ settings: PadSteamTrackpadSettings) -> Double {
        let d = settings.deadzone ?? PadSteamTrackpadSettings.defaultDeadzone
        return d.isFinite ? min(0.8, max(0.05, d)) : PadSteamTrackpadSettings.defaultDeadzone
    }
    /// Returns the inputs now held. A little stickiness at each boundary keeps a finger resting on one from chattering.
    @discardableResult
    public mutating func update(side: Int, down: Bool, x: Double, y: Double, settings: PadSteamTrackpadSettings) -> Set<PadProfiles.Input> {
        guard down, x.isFinite, y.isFinite else { held = []; return held }
        var px = x, py = y
        if let degrees = settings.rotation, degrees.isFinite, degrees != 0 {
            let r = min(45,max(-45,degrees)) * Double.pi / 180
            (px, py) = (cos(r) * x - sin(r) * y, sin(r) * x + cos(r) * y)
        }
        let radius = min(1, (px * px + py * py).squareRoot())
        var next: Set<PadProfiles.Input> = []
        let edgeInput = PadProfiles.Input.padEdge(side), edge = Self.edgeSize(settings)
        if edge > 0, radius >= 1 - edge - (held.contains(edgeInput) ? 0.04 : 0) { next.insert(edgeInput) }
        if settings.mode == .directions {
            let d = PadProfiles.Input.padDirections(side), dead = Self.deadzone(settings)
            let moving = !held.isDisjoint(with: d)
            if radius >= dead - (moving ? 0.05 : 0) {
                // Eight ways: a direction covers 135°, so neighbours overlap on the diagonals.
                let a = atan2(py, px) * 180 / Double.pi
                func within(_ centre: Double, _ input: PadProfiles.Input) -> Bool {
                    var off = abs(a - centre); if off > 180 { off = 360 - off }
                    return off <= 67.5 + (held.contains(input) ? 4 : 0)
                }
                if within(90, d[0]) { next.insert(d[0]) }
                if within(-90, d[1]) { next.insert(d[1]) }
                if within(180, d[2]) { next.insert(d[2]) }
                if within(0, d[3]) { next.insert(d[3]) }
            }
        }
        held = next
        return held
    }
}
