import Foundation

public struct PadSteamTrackpadSettings: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case existing, mouse, trackball, directions, stick, dial
        /// The pad moves the pointer itself (rather than acting as mappings or directions).
        public var movesPointer: Bool { self == .mouse || self == .trackball }
        public var title: String { switch self {
        case .directions: "Four directions"
        case .stick: "Analog stick"
        case .dial: "Scroll wheel (circle)"
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
    /// Zones for taps and clicks, independent of the pad behavior (nil: none).
    public var zoneLayout: PadSteamZoneLayout?
    /// Scroll wheel: degrees of circling per scroll step, the other way round, and a haptic tick per step.
    public var dialStep: Double?
    public var dialReverse: Bool?
    public var dialHaptic: Double?
    public static let defaultDialStep = 30.0
    public static let defaultSmoothing = 0.4
    /// The pad's own directions unless you choose an angle. Valve's ±15° made a straight up-and-down swipe
    /// come out partly sideways for at least one player, which felt like the cursor hooking.
    public static func defaultRotation(side: Int) -> Double { 0 }
    /// Valve's angle for this pad, offered in the slider's explanation.
    public static func valveRotation(side: Int) -> Double { side == 0 ? -15 : 15 }
    public init(mode: Mode = .existing) { self.mode = mode }
}

/// Relative pad motion and time-based momentum; no OS input is posted here.
/// Coordinates are normalized 0...1, y down. Touch cancels inertia immediately.
public struct PadSteamTrackpad {
    /// Whole-pixel movement for games (the remainder is carried to the next report), and the exact movement
    /// of this report for the Mac pointer, which can sit between pixels: rounding every report to whole
    /// pixels turned slow curves into staircases.
    public struct Motion: Equatable {
        public var x: Int = 0, y: Int = 0
        public var fx = 0.0, fy = 0.0
        public init(x: Int = 0, y: Int = 0, fx: Double = 0, fy: Double = 0) { self.x = x; self.y = y; self.fx = fx; self.fy = fy }
        public var isEmpty: Bool { x == 0 && y == 0 && fx == 0 && fy == 0 }
        public static func == (a: Motion, b: Motion) -> Bool { a.x == b.x && a.y == b.y }
    }
    private var down = false
    private var x = 0.0, y = 0.0, sampleTime: Double?, tickTime: Double?, movedTime: Double?
    private var vx = 0.0, vy = 0.0, restX = 0.0, restY = 0.0
    private var steadyX = 0.0, steadyY = 0.0
    private var edgeEntryTime: Double?
    private var velocityHistory: [(time: Double, x: Double, y: Double)] = []
    private var filterX = 0.0, filterY = 0.0, rateX = 0.0, rateY = 0.0, landed = 0.0
    /// Where the finger landed, and whether it has since clearly started to move.
    private var landX = 0.0, landY = 0.0, released = false
    private var slowSince: Double?
    /// The latest positions, for the finger's average drift: sensor noise averages out, movement doesn't.
    private var recent: [(t: Double, x: Double, y: Double)] = []
    /// The pad's own noise: the scatter of its readings around the finger's path, averaged over about a fifth of
    /// a second; while the finger moves it rises five times slower, because a curving swipe also scatters
    /// around a straight line for a moment. Kept from touch to touch.
    public private(set) var noiseLevel = 0.0
    /// Noise filtering while the finger moves. A recorded Steam Controller pad (November 2026) scattered
    /// 0.002–0.003 of the pad per axis, moving or still, haptics or not, nearly white: 6–8 px of cursor jitter
    /// on every report. Below `quietNoise` nothing is filtered (the movement stays exactly raw); from
    /// `noisyNoise` up the filter is fully on: a low-pass at `noiseCutoff` Hz that opens by `noiseOpening` Hz
    /// for each pad-width per second of finger speed, so a slow finger trails by a pixel or two and a swipe by
    /// about a millisecond. The speed that opens it is counted beyond what the noise alone reads as
    /// (`noiseSpeed` × the noise level), or the noise would open the filter by itself.
    public static let quietNoise = 0.0008, noisyNoise = 0.002
    public static let noiseCutoff = 4.0, noiseOpening = 80.0, noiseSpeed = 60.0
    /// A finger settling onto the pad (or the pad's touch pulse) reads as a little movement: nothing moves
    /// until the finger has gone this far from where it landed, or this long has passed.
    public static let landingDistance = 0.008
    /// Below this speed (part of the pad per second, of the finger's average position) for `restTime`, the
    /// finger is resting: the pointer holds still until it clearly moves again. A slow, deliberate aim is several
    /// times faster.
    public static let restSpeed = 0.05, restTime = 0.08
    /// The averaging window. A recorded Steam Controller pad wandered ±0.7 % of its width on every report under
    /// a still thumb (November 2026), so an instant speed never fell below `restSpeed`; averages over 80 ms do.
    public static let restWindow = 0.08
    /// A reading this far from where the finger rests, in multiples of the pad's current noise (its spread
    /// under the resting finger), is movement on that same report. On a quiet pad that is under
    /// `landingDistance`, so nothing waits; a noisy one (a recorded thumb spread 0.003–0.0045 with single
    /// readings up to 0.014 out) needs a clearer move. Capped so a very noisy pad still responds.
    public static let noiseMultiple = 5.0, clearMoveCap = 0.03
    /// RMS distance of the samples from their least-squares straight line in time (0 with fewer than five).
    static func scatter(_ w: [(t: Double, x: Double, y: Double)]) -> Double {
        guard w.count >= 5 else { return 0 }
        let n = Double(w.count), mt = w.map(\.t).reduce(0, +) / n
        let mx = w.map(\.x).reduce(0, +) / n, my = w.map(\.y).reduce(0, +) / n
        let tt = w.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
        let sx = tt > 0 ? w.map { ($0.t - mt) * ($0.x - mx) }.reduce(0, +) / tt : 0
        let sy = tt > 0 ? w.map { ($0.t - mt) * ($0.y - my) }.reduce(0, +) / tt : 0
        let r = w.map { p -> Double in
            let ex = p.x - (mx + sx * (p.t - mt)), ey = p.y - (my + sy * (p.t - mt)); return ex * ex + ey * ey
        }.reduce(0, +) / n
        return r.squareRoot()
    }
    static func clearMove(noise: Double) -> Double { min(clearMoveCap, max(landingDistance, noiseMultiple * noise)) }
    /// The average position over the last window, and its speed against the window before (nil: too little yet).
    private func drift(now: Double) -> (x: Double, y: Double, speed: Double?)? {
        let a = recent.filter { $0.t > now - Self.restWindow }, b = recent.filter { $0.t <= now - Self.restWindow && $0.t > now - 2 * Self.restWindow }
        guard !a.isEmpty else { return nil }
        func mean(_ s: [(t: Double, x: Double, y: Double)]) -> (t: Double, x: Double, y: Double) {
            let n = Double(s.count); return (s.map(\.t).reduce(0, +) / n, s.map(\.x).reduce(0, +) / n, s.map(\.y).reduce(0, +) / n)
        }
        let ma = mean(a)
        guard b.count >= 3, a.count >= 3 else { return (ma.x, ma.y, nil) }
        let mb = mean(b), dt = max(0.01, ma.t - mb.t)
        return (ma.x, ma.y, ((ma.x - mb.x) * (ma.x - mb.x) + (ma.y - mb.y) * (ma.y - mb.y)).squareRoot() / dt)
    }
    public init() {}
    /// Forgets the touch; the pad's noise level is the pad's, and stays.
    public mutating func reset() { let noise = noiseLevel; self = Self(); noiseLevel = noise }
    private mutating func motion(_ x: Double, _ y: Double) -> Motion {
        restX += x; restY += y
        let result = Motion(x: Int(restX), y: Int(restY), fx: x.isFinite ? x : 0, fy: y.isFinite ? y : 0)
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
            landX = px; landY = py; released = false; slowSince = nil; recent = [(now, px, py)]
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
        // A resting thumb wobbles a little (and so does the pad under a haptic pulse). Hold the pointer still
        // while the finger rests — when it lands and whenever it comes to rest again — until it has clearly
        // moved; it then starts from where the finger is, so the wobble is never replayed. (A time limit on
        // this let a resting thumb's wobble move the pointer and buzz the movement haptics.)
        // Judged on the finger's average position, so the pad's own noise doesn't count as movement. (The
        // trackball also waited for its momentum to settle, which noise kept from ever happening: the cursor
        // jiggled and the movement haptics buzzed, shaking the pad further.)
        recent.append((now, px, py))
        if recent.count > 64 || (recent.first.map { $0.t < now - 2 * Self.restWindow - 0.02 } ?? false) {
            recent.removeAll { $0.t < now - 2 * Self.restWindow - 0.02 }
            if recent.count > 64 { recent.removeFirst(recent.count - 64) }
        }
        let average = drift(now: now)
        let window = recent.filter { $0.t > now - Self.restWindow }
        let noise = Self.scatter(window)
        if window.count >= 5 { noiseLevel += (noise < noiseLevel || !released ? 0.05 : 0.01) * (noise - noiseLevel) }
        if released {
            if let speed = average?.speed, speed < Self.restSpeed {
                if slowSince == nil { slowSince = now }
                if now - slowSince! >= Self.restTime, let average {
                    released = false; landX = average.x; landY = average.y; vx = 0; vy = 0
                }
            } else { slowSince = nil }
        }
        if !released {
            // The last few reports' average: enough to keep the noise inside the landing distance, short enough
            // that a thumb starting to move gets going within a report or two.
            // The pad's noise now: the scatter of the last window's readings around the finger's straight-line
            // path, so a finger starting to move doesn't count as noise (only jitter does).
            // One reading clearly beyond the noise starts the cursor on that same report (on a quiet pad, the
            // same distance as before: no added latency). A slow start the size of the noise is told apart by
            // the last few reports' average.
            let rawAway = ((px - landX) * (px - landX) + (py - landY) * (py - landY)).squareRoot()
            let last = recent.suffix(4), n = Double(last.count)
            let ax = last.map(\.x).reduce(0, +) / n, ay = last.map(\.y).reduce(0, +) / n
            let away = ((ax - landX) * (ax - landX) + (ay - landY) * (ay - landY)).squareRoot()
            let clear = Self.clearMove(noise: noise)
            if rawAway < clear && (clear <= Self.landingDistance || away < max(Self.landingDistance, clear * 0.75)) {
                filterX = px; filterY = py; rateX = 0; rateY = 0
                return Motion()
            }
            released = true; slowSince = nil; filterX = x; filterY = y
        }
        // Steadiness is a per-axis dead band. With Smoothing on as well it caught most small reports, so the
        // pointer stalled mid-swipe and one axis froze then jumped (a recorded session: 32 ms stalls, a
        // sideways hook on vertical swipes). Smoothing replaces it; steadiness applies only without it.
        let requested = (settings.smoothing ?? 0) > 0 ? 0 : (settings.steadiness ?? 0)
        let steadiness = requested.isFinite ? min(5,max(0,requested)) : 0
        var moveX = px - x, moveY = py - y
        let strength = settings.smoothing.map { $0.isFinite ? min(1,max(0,$0)) : 0 } ?? 0
        let amount = min(1, max(0, (noiseLevel - Self.quietNoise) / (Self.noisyNoise - Self.quietNoise)))
        if strength > 0 || amount > 0 {
            // A filter whose cutoff rises with finger speed: sensor noise under a resting or slow finger is
            // held back, while a deliberate movement passes with a millisecond or two of lag. Unlike a dead
            // band it never has to be "pushed through" when the finger changes direction, and unlike a
            // straight-line prediction it never runs past a finger that stops.
            let dt = max(0.0005, now - previous)
            func blend(_ cutoff: Double) -> Double { let tau = 1 / (2 * Double.pi * cutoff); return dt / (dt + tau) }
            let rateBlend = blend(15)
            rateX += rateBlend * ((px - x) / dt - rateX); rateY += rateBlend * ((py - y) / dt - rateY)
            // The finger's speed beyond what the pad's noise alone reads as (nothing on a quiet pad).
            let fingerSpeed = max(0, (rateX * rateX + rateY * rateY).squareRoot() - Self.noiseSpeed * noiseLevel)
            // The Smoothing setting, and the pad's own noise whatever the setting: the stronger of the two.
            var a = strength > 0 ? blend(25 * pow(0.1, strength) + 80 * fingerSpeed) : 1
            if amount > 0 { a = min(a, 1 - amount * (1 - blend(Self.noiseCutoff + Self.noiseOpening * fingerSpeed))) }
            let nextX = a >= 1 ? px : filterX + a * (px - filterX), nextY = a >= 1 ? py : filterY + a * (py - filterY)
            // The contact patch grows for a moment as a finger lands, which shifts its centre: ease in.
            let settle = strength > 0 ? min(1, max(0, (now - landed) / 0.03)) : 1
            moveX = (nextX - filterX) * settle; moveY = (nextY - filterY) * settle
            filterX = nextX; filterY = nextY
        } else { filterX = px; filterY = py; rateX = 0; rateY = 0 }
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

/// A trackpad as an analog stick: the pad's angle and a centre dead zone applied, then full push a little
/// before the rim so the whole stick range is reachable. Coordinates are the pad's own −1…1, y up.
public enum PadSteamPadStick {
    public static let defaultDeadzone = 0.08
    public static func deadzone(_ settings: PadSteamTrackpadSettings) -> Double {
        let d = settings.deadzone ?? defaultDeadzone
        return d.isFinite ? min(0.6, max(0, d)) : defaultDeadzone
    }
    public static func vector(x: Double, y: Double, settings: PadSteamTrackpadSettings) -> (x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        var px = x, py = y
        if let degrees = settings.rotation, degrees.isFinite, degrees != 0 {
            let r = min(45,max(-45,degrees)) * Double.pi / 180
            (px, py) = (cos(r) * x - sin(r) * y, sin(r) * x + cos(r) * y)
        }
        let m = (px * px + py * py).squareRoot(), dead = deadzone(settings), full = 0.9
        guard m > dead else { return (0, 0) }
        let scaled = min(1, (m - dead) / max(0.05, full - dead))
        return (px / m * scaled, py / m * scaled)
    }
}

/// A quick touch: down and up again within a fifth of a second without moving far. The tap is then held
/// for a moment so a key or click it sends has time to register; a second tap soon after is a double tap.
public struct PadSteamTap {
    private var start: Double?, moved = 0.0
    /// Where the latest touch began (the pad's −1…1, y up): a tap counts in the zone it started in.
    public private(set) var startX = 0.0, startY = 0.0
    public private(set) var releaseAt: Double?
    public init() {}
    public mutating func reset() { self = Self() }
    public enum Change: Equatable { case none, press, release }
    public mutating func update(down: Bool, x: Double, y: Double, at now: Double) -> Change {
        if let r = releaseAt, now >= r || now < r - 1 { releaseAt = nil; return .release }
        if down {
            if start == nil { start = now; startX = x; startY = y; moved = 0 }
            else if x.isFinite, y.isFinite { moved = max(moved, ((x - startX) * (x - startX) + (y - startY) * (y - startY)).squareRoot()) }
            return .none
        }
        guard let s = start else { return .none }
        start = nil
        if releaseAt == nil, now - s >= 0, now - s <= 0.2, moved < 0.15 { releaseAt = now + 0.05; return .press }
        return .none
    }
    /// Lets a held tap go once its moment has passed, between reports.
    public mutating func tick(at now: Double) -> Bool {
        guard let r = releaseAt, now >= r || now < r - 1 else { return false }
        releaseAt = nil; return true
    }
}

/// How a trackpad is divided for zone taps and clicks.
public enum PadSteamZoneLayout: String, Codable, CaseIterable, Sendable {
    case off, leftRight, topBottom, quadrants, cross
    public var title: String {
        switch self {
        case .off: "No zones"; case .leftRight: "Left and right halves"; case .topBottom: "Top and bottom halves"
        case .quadrants: "Four corners"; case .cross: "Centre and four sides"
        }
    }
    public var names: [String] {
        switch self {
        case .off: []; case .leftRight: ["Left", "Right"]; case .topBottom: ["Top", "Bottom"]
        case .quadrants: ["Top left", "Top right", "Bottom left", "Bottom right"]
        case .cross: ["Centre", "Top", "Bottom", "Left", "Right"]
        }
    }
    /// The zone (0-based) under a finger at the pad's −1…1 (y up), after the pad angle; nil off the pad.
    public func zone(x: Double, y: Double, rotation: Double? = nil) -> Int? {
        guard self != .off, x.isFinite, y.isFinite else { return nil }
        var px = x, py = y
        if let degrees = rotation, degrees.isFinite, degrees != 0 {
            let r = min(45,max(-45,degrees)) * Double.pi / 180
            (px, py) = (cos(r) * x - sin(r) * y, sin(r) * x + cos(r) * y)
        }
        switch self {
        case .off: return nil
        case .leftRight: return px < 0 ? 0 : 1
        case .topBottom: return py >= 0 ? 0 : 1
        case .quadrants: return (px < 0 ? 0 : 1) + (py >= 0 ? 0 : 2)
        case .cross:
            if (px * px + py * py).squareRoot() < 0.35 { return 0 }
            return abs(py) >= abs(px) ? (py >= 0 ? 1 : 2) : (px < 0 ? 3 : 4)
        }
    }
}

/// Sends a pad's taps and clicks to its zones. A zone with nothing set falls back to the pad's ordinary
/// tap or click, so adding zones never takes anything away. Pure: the host does the delivering.
public struct PadSteamZoneRouter {
    public private(set) var clickHeld: PadProfiles.Input?
    private var clicked = false
    public init() {}
    public mutating func reset() { self = Self() }
    /// The input a tap that started at (x, y) should press.
    public static func tap(side: Int, x: Double, y: Double, settings: PadSteamTrackpadSettings, bound: (PadProfiles.Input) -> Bool) -> PadProfiles.Input {
        if let layout = settings.zoneLayout, let z = layout.zone(x: x, y: y, rotation: settings.rotation) {
            let input = PadProfiles.Input.padZoneTap(side, z)
            if bound(input) { return input }
        }
        return .padTap(side)
    }
    /// Call with the pad click's state on every report. Returns the zone click to press or let go, and
    /// whether the plain click must be kept from the engine (it was taken by a zone).
    public mutating func click(side: Int, down: Bool, touching: Bool, x: Double, y: Double, settings: PadSteamTrackpadSettings,
                               bound: (PadProfiles.Input) -> Bool) -> (change: (input: PadProfiles.Input, down: Bool)?, suppress: Bool) {
        defer { clicked = down }
        if down && !clicked {
            if touching, let layout = settings.zoneLayout, let z = layout.zone(x: x, y: y, rotation: settings.rotation) {
                let input = PadProfiles.Input.padZoneClick(side, z)
                if bound(input) { clickHeld = input; return ((input, true), true) }
            }
            return (nil, false)
        }
        if !down, let held = clickHeld { clickHeld = nil; return ((held, false), true) }
        return (nil, clickHeld != nil)
    }
}

/// A trackpad as a scroll wheel, the way the Steam Controller was designed: circling the pad scrolls, one
/// step for each `dialStep` degrees; clockwise scrolls down. Only the outer part of the pad counts, where
/// the angle is steady. Returns the wheel steps (positive: up) for each report.
public struct PadSteamDial {
    private var last: Double?, turned = 0.0
    public init() {}
    public mutating func reset() { self = Self() }
    public static func step(_ settings: PadSteamTrackpadSettings) -> Double {
        let s = settings.dialStep ?? PadSteamTrackpadSettings.defaultDialStep
        return s.isFinite ? min(120, max(5, s)) : PadSteamTrackpadSettings.defaultDialStep
    }
    public mutating func update(down: Bool, x: Double, y: Double, settings: PadSteamTrackpadSettings) -> Int {
        guard down, x.isFinite, y.isFinite, (x * x + y * y).squareRoot() >= 0.3 else { last = nil; turned = 0; return 0 }
        let angle = atan2(y, x) * 180 / Double.pi            // counter-clockwise positive (y up)
        defer { last = angle }
        guard let previous = last else { return 0 }
        var delta = angle - previous
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        guard abs(delta) < 90 else { return 0 }               // a jump, not a turn
        // Changing direction starts afresh, so the first step the other way comes after one step's turn.
        if turned * delta < 0 { turned = 0 }
        turned += delta
        let step = Self.step(settings)
        let steps = Int((turned + (turned < 0 ? -1e-9 : 1e-9)) / step)
        guard steps != 0 else { return 0 }
        turned -= Double(steps) * step
        // Counter-clockwise (positive) scrolls up, clockwise down; Reverse swaps them.
        return settings.dialReverse == true ? -steps : steps
    }
}
