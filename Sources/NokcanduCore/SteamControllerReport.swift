import Foundation

/// Original cable / 2.4 GHz receiver Steam Controller full-state protocol.
/// Not Deck, BLE or a receiver-presence claim.
/// Layout facts checked against Valve's SDL controller_structs.h and SDL_hidapi_steam.c.
/// No device commands are issued by this decoder.
public struct SteamControllerReport {
    public struct Point: Equatable, Sendable {
        public var x: Float, y: Float
        public init(_ x: Float = 0, _ y: Float = 0) { self.x = x; self.y = y }
    }
    public struct State: Equatable, Sendable {
        public var counter: UInt32
        public var buttons: Set<PadProfiles.Input>
        public var stick: Point
        public var leftPad: Point, rightPad: Point
        public var leftTouch: Bool, rightTouch: Bool
        public var leftTrigger: Float, rightTrigger: Float
        public var gyro: [Float], acceleration: [Float]
        /// Axes use the existing engine's SDL order and y-down convention.
        public var axes: [Int: Int] {
            [0: Self.axis(stick.x), 1: Self.axis(-stick.y),
             2: Self.axis(rightTouch ? rightPad.x : 0), 3: Self.axis(rightTouch ? -rightPad.y : 0),
             4: Self.axis(leftTrigger), 5: Self.axis(rightTrigger)]
        }
        /// The stick axes for the engine, with either pad as an analog stick when it is set to be one: the pad
        /// drives its side's stick (left pad: the left stick, which it shares with the joystick — whichever is
        /// pushed further wins).
        public func mappingAxes(left: PadSteamTrackpadSettings, right: PadSteamTrackpadSettings) -> [Int: Int] {
            var result = mappingAxes(rightTrackpadAsStick: right.mode == .existing)
            if right.mode == .stick {
                let v = rightTouch ? PadSteamPadStick.vector(x: Double(rightPad.x), y: Double(rightPad.y), settings: right) : (x: 0, y: 0)
                result[2] = Self.axis(Float(v.x)); result[3] = Self.axis(Float(-v.y))
            }
            if left.mode == .stick, leftTouch {
                let v = PadSteamPadStick.vector(x: Double(leftPad.x), y: Double(leftPad.y), settings: left)
                if v.x * v.x + v.y * v.y > Double(stick.x * stick.x + stick.y * stick.y) {
                    result[0] = Self.axis(Float(v.x)); result[1] = Self.axis(Float(-v.y))
                }
            }
            return result
        }
        public func mappingAxes(rightTrackpadAsStick: Bool) -> [Int: Int] {
            var result = axes
            if !rightTrackpadAsStick { result[2] = 0; result[3] = 0 }
            return result
        }
        private static func axis(_ v: Float) -> Int { Int(max(-32768, min(32767, v * 32767))) }
    }
    private var left = Point(), stick = Point()
    private var counter: UInt32?
    public init() {}
    public static func isInputReport(_ bytes: [UInt8]) -> Bool {
        bytes.count == 64 && bytes[0] == 1 && bytes[1] == 0 && bytes[2] == 1 && (44...60).contains(bytes[3])
    }
    public mutating func decode(_ bytes: [UInt8]) -> State? {
        guard Self.isInputReport(bytes) else { return nil }
        let sequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4+$1]) << (8*$1) }
        guard sequence != counter else { return nil }
        func signed(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8) }
        func point(_ i: Int) -> Point { Point(max(-1,Float(signed(i))/32767),max(-1,Float(signed(i+2))/32767)) }
        let flags = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16
        func bit(_ n: Int) -> Bool { flags & (1 << n) != 0 }
        let isPad = bit(19), interleaved = bit(23)
        if isPad { left = point(16); if !interleaved { stick = Point() } }
        else { stick = point(16); if !interleaved { left = Point() } }
        let mappings: [(Int,PadProfiles.Input)] = [(2,.rb),(3,.lb),(4,.y),(5,.b),(6,.x),(7,.a),
            (8,.up),(9,.right),(10,.left),(11,.down),(12,.back),(13,.guide),(14,.start),
            (15,.paddle2),(16,.paddle1),(18,.rs),(22,.ls)]
        var buttons = Set(mappings.filter { bit($0.0) }.map(\.1))
        // Older firmware multiplexes the left pad click as the stick click.
        if bit(17) { buttons.insert(isPad || interleaved ? .touchpad : .ls) }
        counter = sequence
        let gyroScale = Float(2000.0 / 32768.0 * Double.pi / 180)
        return State(counter: sequence, buttons: buttons, stick: stick, leftPad: left, rightPad: point(20),
            leftTouch: isPad || interleaved, rightTouch: bit(20),
            leftTrigger: bit(1) ? 1 : Float(bytes[11])/255, rightTrigger: bit(0) ? 1 : Float(bytes[12])/255,
            gyro: [34,36,38].map { Float(signed($0))*gyroScale },
            acceleration: [28,30,32].map { Float(signed($0))/16384 })
    }
}

/// Freshness is independent of change suppression: repeated valid input keeps a
/// hold alive, while heartbeat/status packets cannot keep stale actions held.
public struct SteamControllerStream {
    private var decoder = SteamControllerReport()
    public private(set) var state: SteamControllerReport.State?
    private var received: Double?
    public init() {}
    public mutating func accept(_ bytes: [UInt8], at time: Double) -> SteamControllerReport.State? {
        guard time.isFinite, SteamControllerReport.isInputReport(bytes) else { return nil }
        if let received, time < received { reset() }
        received = time
        guard let next = decoder.decode(bytes) else { return nil }
        state = next; return next
    }
    public mutating func expire(at time: Double, after timeout: Double = 0.3) -> Bool {
        guard state != nil, let received else { return false }
        guard time.isFinite, time >= received, time-received <= timeout else { reset(); return true }
        return false
    }
    public mutating func reset() { decoder = SteamControllerReport(); state = nil; received = nil }
}
