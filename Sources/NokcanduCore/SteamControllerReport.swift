import Foundation

/// Original cable / 2.4 GHz receiver Steam Controller full-state protocol.
/// Not Deck or a receiver-presence claim; Bluetooth's packets are joined by SteamControllerBLE and end up in `state`.
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
        /// Which Steam Controller: the original (its right trackpad is its right stick) or the 2026 one (a right
        /// stick of its own, square trackpads with pressure).
        public var kind: SteamControllerModel = .original
        public var rightStick = Point()
        /// The 2026 controller's trackpad pressure, 0…1.
        public var leftPressure: Float = 0, rightPressure: Float = 0
        /// Axes use the existing engine's SDL order and y-down convention.
        public var axes: [Int: Int] {
            let right = kind == .original ? (rightTouch ? rightPad : Point()) : rightStick
            return [0: Self.axis(stick.x), 1: Self.axis(-stick.y),
                    2: Self.axis(right.x), 3: Self.axis(-right.y),
                    4: Self.axis(leftTrigger), 5: Self.axis(rightTrigger)]
        }
        /// The input a trackpad's click is: the left one is the touchpad click; the original's right one is its
        /// right stick click (its right pad is that stick), the 2026 controller's its own.
        public func padClick(_ side: Int) -> PadProfiles.Input { side == 0 ? .touchpad : kind == .original ? .rs : .rpclick }
        /// The stick axes for the engine, with either pad as an analog stick when it is set to be one: the pad
        /// drives its side's stick (left pad: the left stick, which it shares with the joystick — whichever is
        /// pushed further wins).
        public func mappingAxes(left: PadSteamTrackpadSettings, right: PadSteamTrackpadSettings) -> [Int: Int] {
            var result = mappingAxes(rightTrackpadAsStick: right.mode == .existing)
            if right.mode == .existing, rightTouch {
                let p = right.rotatedPosition(x: Double(rightPad.x), y: Double(rightPad.y))
                if kind == .original || rightPad.x * rightPad.x + rightPad.y * rightPad.y > rightStick.x * rightStick.x + rightStick.y * rightStick.y {
                    result[2] = Self.axis(Float(p.x)); result[3] = Self.axis(Float(-p.y))
                }
            }
            if right.mode == .stick {
                let v = rightTouch ? PadSteamPadStick.vector(x: Double(rightPad.x), y: Double(rightPad.y), settings: right) : (x: 0, y: 0)
                // The 2026 controller's right stick is real: the pad takes over only while pushed further.
                if kind == .original || v.x * v.x + v.y * v.y > Double(rightStick.x * rightStick.x + rightStick.y * rightStick.y) {
                    result[2] = Self.axis(Float(v.x)); result[3] = Self.axis(Float(-v.y))
                }
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
            if kind == .original {
                if !rightTrackpadAsStick { result[2] = 0; result[3] = 0 }
            } else if rightTrackpadAsStick, rightTouch,
                      rightPad.x * rightPad.x + rightPad.y * rightPad.y > rightStick.x * rightStick.x + rightStick.y * rightStick.y {
                result[2] = Self.axis(rightPad.x); result[3] = Self.axis(-rightPad.y)
            }
            return result
        }
        private static func axis(_ v: Float) -> Int { Int(max(-32768, min(32767, v * 32767))) }
    }
    private var left: [Int16] = [0, 0], stick: [Int16] = [0, 0]
    private var counter: UInt32?
    public init() {}
    public static func isInputReport(_ bytes: [UInt8]) -> Bool {
        bytes.count == 64 && bytes[0] == 1 && bytes[1] == 0 && bytes[2] == 1 && (44...60).contains(bytes[3])
    }
    /// The state from the cable's raw values (Bluetooth sends the same values in pieces: SteamControllerBLE).
    /// `flags`: the 24 button bits; triggers 0–255; pads, stick and motion as the controller's signed 16-bit values.
    public static func state(counter: UInt32, flags: UInt32, leftTrigger: UInt8, rightTrigger: UInt8, stick: [Int16], leftPad: [Int16],
                             rightPad: [Int16], leftTouch: Bool, gyro: [Int16], acceleration: [Int16]) -> State {
        func bit(_ n: Int) -> Bool { flags & (1 << n) != 0 }
        func point(_ v: [Int16]) -> Point { Point(max(-1, Float(v[0]) / 32767), max(-1, Float(v[1]) / 32767)) }
        let mappings: [(Int,PadProfiles.Input)] = [(2,.rb),(3,.lb),(4,.y),(5,.b),(6,.x),(7,.a),
            (8,.up),(9,.right),(10,.left),(11,.down),(12,.back),(13,.guide),(14,.start),
            (15,.paddle2),(16,.paddle1),(18,.rs),(22,.ls)]
        var buttons = Set(mappings.filter { bit($0.0) }.map(\.1))
        // Older firmware multiplexes the left pad click as the stick click.
        if bit(17) { buttons.insert(leftTouch ? .touchpad : .ls) }
        let gyroScale = Float(2000.0 / 32768.0 * Double.pi / 180)
        return State(counter: counter, buttons: buttons, stick: point(stick), leftPad: point(leftPad), rightPad: point(rightPad),
            leftTouch: leftTouch, rightTouch: bit(20),
            leftTrigger: bit(1) ? 1 : Float(leftTrigger)/255, rightTrigger: bit(0) ? 1 : Float(rightTrigger)/255,
            gyro: gyro.map { Float($0)*gyroScale },
            acceleration: acceleration.map { Float($0)/16384 })
    }
    public mutating func decode(_ bytes: [UInt8]) -> State? {
        guard Self.isInputReport(bytes) else { return nil }
        let sequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4+$1]) << (8*$1) }
        guard sequence != counter else { return nil }
        func signed(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8) }
        func raw(_ i: Int) -> [Int16] { [signed(i), signed(i+2)] }
        let flags = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16
        func bit(_ n: Int) -> Bool { flags & (1 << n) != 0 }
        let isPad = bit(19), interleaved = bit(23)
        if isPad { left = raw(16); if !interleaved { stick = [0, 0] } }
        else { stick = raw(16); if !interleaved { left = [0, 0] } }
        counter = sequence
        return Self.state(counter: sequence, flags: flags, leftTrigger: bytes[11], rightTrigger: bytes[12],
                          stick: stick, leftPad: left,
                          rightPad: [signed(20), signed(22)], leftTouch: isPad || interleaved,
                          gyro: [signed(34), signed(36), signed(38)], acceleration: [signed(28), signed(30), signed(32)])
    }
}

/// Freshness is independent of change suppression: repeated valid input keeps a
/// hold alive, while heartbeat/status packets cannot keep stale actions held.
public struct SteamControllerStream {
    private var decoder = SteamControllerReport()
    private var bleAssembler = SteamControllerBLE.Assembler()
    private var bleDecoder = SteamControllerBLE.Decoder()
    public private(set) var state: SteamControllerReport.State?
    private var received: Double?
    public init() {}
    /// Only full input reports prove liveness; status traffic must not keep stale holds alive.
    public func hasRecentInput(at time: Double, within timeout: Double = 0.3) -> Bool {
        guard let received else { return false }
        return time.isFinite && time >= received && time - received <= timeout
    }
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
    /// A state already decoded (the 2026 controller's): kept for freshness like the others.
    public mutating func acceptDecoded(_ next: SteamControllerReport.State, at time: Double) -> Bool {
        guard time.isFinite else { return false }
        if let received, time < received { reset() }
        received = time
        state = next
        return true
    }
    /// A Bluetooth input report (a segment): returns the state once a whole state packet is in.
    public mutating func acceptBluetooth(_ bytes: [UInt8], at time: Double) -> SteamControllerReport.State? {
        guard time.isFinite, let packet = bleAssembler.add(bytes), SteamControllerBLE.Decoder.isState(packet) else { return nil }
        if let received, time < received { reset() }
        received = time
        guard let next = bleDecoder.decode(packet) else { return nil }
        state = next; return next
    }
    public mutating func reset() {
        decoder = SteamControllerReport(); bleAssembler.reset(); bleDecoder = SteamControllerBLE.Decoder(); state = nil; received = nil
    }
}

/// Feature replies can go missing while input continues. Reacquire only when both paths are silent.
/// An actual settings mismatch is handled separately and always revokes capture.
public struct SteamControllerCaptureHealth {
    public private(set) var missedReads = 0
    public init() {}
    public mutating func missingReply(hasRecentInput: Bool) -> Bool {
        missedReads = min(missedReads + 1, 3)
        return missedReads >= 3 && !hasRecentInput
    }
    public mutating func reset() { missedReads = 0 }
}
