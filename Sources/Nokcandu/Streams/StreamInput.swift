// SPDX-License-Identifier: GPL-3.0-only
// Keyboard, mouse and controllers to the host.
import AppKit
import GameController
import NokcanduCore
import NokcanduStreamCore

/// Controllers on the host. Without a Nokcandu profile each controller is sent as itself; with one, the
/// profile's mapped controller is player one (DesktopPad sends its output here).
@MainActor final class StreamGamepads {
    struct Pad: Equatable {
        var buttons: Int32 = 0
        var lt: UInt8 = 0, rt: UInt8 = 0
        var lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0
    }
    let settings: StreamProfile.Controller
    let usesProfile: Bool
    private(set) var pads: [Int: Pad] = [:]
    private var numbers: [ObjectIdentifier: Int] = [:]
    private var observers: [NSObjectProtocol] = []
    private var motionWanted: [Int: (accel: Bool, gyro: Bool)] = [:]
    private var rumbleState: [Int: (low: Double, high: Double)] = [:]
    private var rumbleTimer: Timer?
    var active = false

    init(settings: StreamProfile.Controller) {
        self.settings = settings
        usesProfile = settings.profileID != nil
    }

    /// Bitmask of the controllers the host should create, for the launch request.
    var mask: Int {
        if settings.sendAs == .profileOnly { return 0 }
        if usesProfile { return 1 }
        let n = GCController.controllers().filter { $0.extendedGamepad != nil }.count
        return n == 0 ? 1 : (settings.multipleControllers ? (1 << min(n, 16)) - 1 : 1)
    }

    func start() {
        active = true
        if settings.sendAs == .profileOnly { return }
        if usesProfile {
            arrive(0, controller: GCController.controllers().first { $0.extendedGamepad != nil })
            return
        }
        for c in GCController.controllers() where c.extendedGamepad != nil { connect(c) }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self.connect(c) } }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self.disconnect(c) } }
        })
    }

    func stop() {
        // Tell the host these controllers are gone (it removes a controller whose bit leaves the mask).
        if active { for n in pads.keys { LiSendMultiControllerEvent(Int16(n), 0, 0, 0, 0, 0, 0, 0, 0) } }
        active = false
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        for c in GCController.controllers() {
            c.extendedGamepad?.valueChangedHandler = nil
            c.motion?.valueChangedHandler = nil
        }
        rumbleTimer?.invalidate(); rumbleTimer = nil
        numbers = [:]; pads = [:]
    }

    private var activeMask: Int16 {
        var m: Int16 = 0
        for n in pads.keys { m |= Int16(1 << n) }
        return m == 0 ? 1 : m
    }

    private func type(for c: GCController?) -> UInt8 {
        switch settings.sendAs {
        case .xbox: return UInt8(LI_CTYPE_XBOX)
        case .playstation: return UInt8(LI_CTYPE_PS)
        case .nintendo: return UInt8(LI_CTYPE_NINTENDO)
        case .profileOnly: return UInt8(LI_CTYPE_UNKNOWN)
        case .automatic:
            // A Nokcandu profile that presents the controller as another one: the host gets that one too.
            if let id = settings.profileID, let p = PadProfiles.profiles().first(where: { $0.id == id }),
               let shown = PadProfiles.top(p, all: PadProfiles.profiles(), \.presentAs) {
                switch shown { case .xbox: return UInt8(LI_CTYPE_XBOX); case .dualShock4: return UInt8(LI_CTYPE_PS); case .switchPro: return UInt8(LI_CTYPE_NINTENDO) }
            }
            guard let g = c?.extendedGamepad else { return UInt8(LI_CTYPE_XBOX) }
            if g is GCDualSenseGamepad || g is GCDualShockGamepad { return UInt8(LI_CTYPE_PS) }
            let n = ((c?.productCategory ?? "") + " " + (c?.vendorName ?? "")).lowercased()
            if n.contains("switch") || n.contains("joy-con") || n.contains("pro controller") { return UInt8(LI_CTYPE_NINTENDO) }
            return UInt8(LI_CTYPE_XBOX)
        }
    }

    private func arrive(_ n: Int, controller c: GCController?) {
        pads[n] = Pad()
        var caps = UInt16(LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE)
        if c?.motion != nil { caps |= UInt16(LI_CCAP_GYRO | LI_CCAP_ACCEL) }
        if c?.light != nil { caps |= UInt16(LI_CCAP_RGB_LED) }
        if c?.extendedGamepad is GCDualSenseGamepad || c?.extendedGamepad is GCDualShockGamepad { caps |= UInt16(LI_CCAP_TOUCHPAD) }
        let all: UInt32 = 0x3FFFFF
        LiSendControllerArrivalEvent(UInt8(n), UInt16(bitPattern: activeMask), type(for: c), all, caps)
        send(n)
    }

    private func connect(_ c: GCController) {
        guard let g = c.extendedGamepad, numbers[ObjectIdentifier(c)] == nil else { return }
        let used = Set(numbers.values)
        let n = settings.multipleControllers ? (0..<16).first { !used.contains($0) } ?? 0 : 0
        numbers[ObjectIdentifier(c)] = n
        arrive(n, controller: c)
        g.valueChangedHandler = { [weak self] pad, _ in MainActor.assumeIsolated { self?.read(pad, number: n) } }
        if let m = c.motion {
            m.valueChangedHandler = { [weak self] motion in
                let r = motion.rotationRate, a = motion.hasGravityAndUserAcceleration ? motion.acceleration : motion.acceleration
                MainActor.assumeIsolated { self?.motion(n, gyro: r, accel: a) }
            }
        }
        PadGC.watchTouchpads(c) { finger, down, x, y in
            LiSendControllerTouchEvent(UInt8(n), UInt8(down ? LI_TOUCH_EVENT_DOWN : LI_TOUCH_EVENT_UP), UInt32(finger), x, y, down ? 1 : 0)
        }
    }

    private func disconnect(_ c: GCController) {
        guard let n = numbers.removeValue(forKey: ObjectIdentifier(c)) else { return }
        pads[n] = nil
        LiSendMultiControllerEvent(Int16(n), activeMask, 0, 0, 0, 0, 0, 0, 0)
    }

    private func read(_ g: GCExtendedGamepad, number n: Int) {
        let (buttons, axes) = PadGC.state(g)
        var p = Pad()
        for (input, down) in buttons where down { p.buttons |= Self.flag(input, swap: settings.swapFaceButtons) }
        for (axis, v) in axes { Self.apply(axis: Int(axis), value: Double(v), to: &p) }
        pads[n] = p
        send(n)
    }

    // MARK: From a Nokcandu profile (SDL button and axis numbers from the pad engine)

    private var profileButtons = Set<Int>()
    func profileButton(_ b: Int, _ down: Bool) {
        guard usesProfile, settings.sendAs != .profileOnly else { return }
        if down { profileButtons.insert(b) } else { profileButtons.remove(b) }
        var p = pads[0] ?? Pad()
        p.buttons = profileButtons.reduce(0) { $0 | Self.sdlFlag($1, swap: settings.swapFaceButtons) }
        pads[0] = p
        send(0)
    }
    func profileAxis(_ a: Int, _ v: Int) {
        guard usesProfile, settings.sendAs != .profileOnly else { return }
        var p = pads[0] ?? Pad()
        let x = Double(v) / 32767
        switch a {
        case 0: p.lx = Self.stick(x)
        case 1: p.ly = Self.stick(-x)
        case 2: p.rx = Self.stick(x)
        case 3: p.ry = Self.stick(-x)
        case 4: p.lt = UInt8(max(0, min(255, x * 255)))
        case 5: p.rt = UInt8(max(0, min(255, x * 255)))
        default: return
        }
        pads[0] = p
        send(0)
    }

    private func send(_ n: Int) {
        guard active, let p = pads[n] else { return }
        LiSendMultiControllerEvent(Int16(n), activeMask, p.buttons, p.lt, p.rt, p.lx, p.ly, p.rx, p.ry)
    }

    static func stick(_ v: Double) -> Int16 { Int16(max(-32768, min(32767, (v * 32767).rounded()))) }

    static func apply(axis: Int, value v: Double, to p: inout Pad) {
        switch axis {
        case 0: p.lx = stick(v)
        case 1: p.ly = stick(-v)          // PadGC reports y down
        case 2: p.rx = stick(v)
        case 3: p.ry = stick(-v)
        case 4: p.lt = UInt8(max(0, min(255, v * 255)))
        case 5: p.rt = UInt8(max(0, min(255, v * 255)))
        default: break
        }
    }

    static func flag(_ i: PadProfiles.Input, swap: Bool) -> Int32 {
        switch i {
        case .a: return swap ? Int32(B_FLAG) : Int32(A_FLAG)
        case .b: return swap ? Int32(A_FLAG) : Int32(B_FLAG)
        case .x: return swap ? Int32(Y_FLAG) : Int32(X_FLAG)
        case .y: return swap ? Int32(X_FLAG) : Int32(Y_FLAG)
        case .back: return Int32(BACK_FLAG)
        case .guide: return Int32(SPECIAL_FLAG)
        case .start: return Int32(PLAY_FLAG)
        case .ls: return Int32(LS_CLK_FLAG)
        case .rs: return Int32(RS_CLK_FLAG)
        case .lb: return Int32(LB_FLAG)
        case .rb: return Int32(RB_FLAG)
        case .up: return Int32(UP_FLAG)
        case .down: return Int32(DOWN_FLAG)
        case .left: return Int32(LEFT_FLAG)
        case .right: return Int32(RIGHT_FLAG)
        case .misc: return Int32(MISC_FLAG)
        case .paddle1: return Int32(PADDLE1_FLAG)
        case .paddle2: return Int32(PADDLE2_FLAG)
        case .paddle3: return Int32(PADDLE3_FLAG)
        case .paddle4: return Int32(PADDLE4_FLAG)
        case .touchpad: return Int32(TOUCHPAD_FLAG)
        default: return 0
        }
    }

    /// SDL's button order (the pad engine's output) to GameStream's flags.
    static func sdlFlag(_ b: Int, swap: Bool) -> Int32 {
        let order: [PadProfiles.Input] = [.a, .b, .x, .y, .back, .guide, .start, .ls, .rs, .lb, .rb, .up, .down, .left, .right, .misc,
                                          .paddle1, .paddle2, .paddle3, .paddle4, .touchpad]
        return order.indices.contains(b) ? flag(order[b], swap: swap) : 0
    }

    // MARK: Motion, rumble and lights from the host

    func motionRequested(_ n: Int, type: UInt8, rateHz: UInt16) {
        guard settings.motion else { return }
        var w = motionWanted[n] ?? (false, false)
        if type == UInt8(LI_MOTION_TYPE_ACCEL) { w.accel = rateHz > 0 } else if type == UInt8(LI_MOTION_TYPE_GYRO) { w.gyro = rateHz > 0 }
        motionWanted[n] = w
        if w.accel || w.gyro {
            for c in GCController.controllers() where numbers[ObjectIdentifier(c)] == n || (usesProfile && n == 0) {
                if let m = c.motion, m.sensorsRequireManualActivation { m.sensorsActive = true }
            }
        }
    }

    private func motion(_ n: Int, gyro r: GCRotationRate, accel a: GCAcceleration) {
        guard let w = motionWanted[n] else { return }
        // GameStream wants degrees per second and m/s².
        let deg = 180 / Double.pi, g = 9.80665
        if w.gyro { LiSendControllerMotionEvent(UInt8(n), UInt8(LI_MOTION_TYPE_GYRO), Float(r.x * deg), Float(r.y * deg), Float(r.z * deg)) }
        if w.accel { LiSendControllerMotionEvent(UInt8(n), UInt8(LI_MOTION_TYPE_ACCEL), Float(a.x * g), Float(a.y * g), Float(a.z * g)) }
    }

    /// With a profile, its own motion goes to player one when the host asks and the profile doesn't use the gyro itself.
    func profileMotion(gyro: (Double, Double, Double), accel: (Double, Double, Double)) {
        guard usesProfile, let w = motionWanted[0] else { return }
        let deg = 180 / Double.pi, g = 9.80665
        if w.gyro { LiSendControllerMotionEvent(0, UInt8(LI_MOTION_TYPE_GYRO), Float(gyro.0 * deg), Float(gyro.1 * deg), Float(gyro.2 * deg)) }
        if w.accel { LiSendControllerMotionEvent(0, UInt8(LI_MOTION_TYPE_ACCEL), Float(accel.0 * g), Float(accel.1 * g), Float(accel.2 * g)) }
    }

    func rumble(_ n: Int, low: UInt16, high: UInt16) {
        rumbleState[n] = (Double(low) / 65535, Double(high) / 65535)
        if rumbleState[n]!.low == 0 && rumbleState[n]!.high == 0 { rumbleState[n] = nil }
        pulseRumble()
        if rumbleState.isEmpty { rumbleTimer?.invalidate(); rumbleTimer = nil }
        else if rumbleTimer == nil {
            // Host rumble is a level that lasts until changed; replay it in short pulses.
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pulseRumble() } }
            RunLoop.main.add(t, forMode: .common)
            rumbleTimer = t
        }
    }

    private func pulseRumble() {
        for (n, r) in rumbleState {
            let strength = max(r.low, r.high * 0.8)
            if usesProfile && n == 0 { DesktopPad.shared.rumbleProfileController(strength: strength, seconds: 0.25); continue }
            let cs = GCController.controllers().filter { numbers[ObjectIdentifier($0)] == n }
            PadFeedback.shared.rumble(cs, strength: strength, seconds: 0.25)
        }
    }

    func light(_ n: Int, r: UInt8, g: UInt8, b: UInt8) {
        let cs = GCController.controllers().filter { numbers[ObjectIdentifier($0)] == n || (usesProfile && n == 0) }
        PadFeedback.shared.light(String(format: "#%02X%02X%02X", r, g, b), cs)
    }
}

/// Keys from the stream window to the host.
@MainActor final class StreamKeyboard {
    private var held = Set<Int>()
    var input: StreamProfile.Input
    init(input: StreamProfile.Input) { self.input = input }

    private func windowsKey(_ mac: Int) -> Int? {
        var k = mac
        if input.swapOptionCommand {
            switch mac { case 0x37: k = 0x3A; case 0x36: k = 0x3D; case 0x3A: k = 0x37; case 0x3D: k = 0x36; default: break }
        }
        guard let vk = StreamKeys.windowsKey(k), vk != 0xFF else { return nil }
        if !input.commandAsWindowsKey, vk == 0x5B || vk == 0x5C { return nil }
        return vk
    }

    private func modifiers(_ f: NSEvent.ModifierFlags) -> Int8 {
        var m: Int32 = 0
        if f.contains(.shift) { m |= MODIFIER_SHIFT }
        if f.contains(.control) { m |= MODIFIER_CTRL }
        if f.contains(input.swapOptionCommand ? .command : .option) { m |= MODIFIER_ALT }
        if input.commandAsWindowsKey, f.contains(input.swapOptionCommand ? .option : .command) { m |= MODIFIER_META }
        return Int8(m)
    }

    func key(_ e: NSEvent, down: Bool) {
        guard let vk = windowsKey(Int(e.keyCode)) else { return }
        if down { held.insert(vk) } else { held.remove(vk) }
        streamSendKey(Int16(bitPattern: UInt16(0x8000 | vk)), Int8(down ? KEY_ACTION_DOWN : KEY_ACTION_UP), modifiers(e.modifierFlags))
    }

    /// A modifier changed. Each key's flagsChanged events alternate press and release, so a held key is
    /// being released; the flags confirm a press (so a missed event can't leave it stuck down).
    func flags(_ e: NSEvent) {
        let code = Int(e.keyCode), f = e.modifierFlags
        let flag: NSEvent.ModifierFlags
        switch code {
        case 0x38, 0x3C: flag = .shift
        case 0x3B, 0x3E: flag = .control
        case 0x3A, 0x3D: flag = .option
        case 0x37, 0x36: flag = .command
        case 0x39:
            // Caps Lock reports its lock state: send a press and a release each time it changes.
            if let vk = windowsKey(code) {
                let k = Int16(bitPattern: UInt16(0x8000 | vk))
                streamSendKey(k, Int8(KEY_ACTION_DOWN), 0); streamSendKey(k, Int8(KEY_ACTION_UP), 0)
            }
            return
        default: return
        }
        guard let vk = windowsKey(code) else { return }
        let down = !held.contains(vk) && f.contains(flag)
        if down { held.insert(vk) } else { held.remove(vk) }
        streamSendKey(Int16(bitPattern: UInt16(0x8000 | vk)), Int8(down ? KEY_ACTION_DOWN : KEY_ACTION_UP), modifiers(f))
    }

    /// Lets go of everything (the window lost focus while keys were down).
    func releaseAll() {
        for vk in held { streamSendKey(Int16(bitPattern: UInt16(0x8000 | vk)), Int8(KEY_ACTION_UP), 0) }
        held = []
    }

    /// A Mac key code from a Nokcandu profile (it outputs Mac key codes).
    func profileKey(_ mac: Int, _ down: Bool) {
        guard let vk = windowsKey(mac) else { return }
        if down { held.insert(vk) } else { held.remove(vk) }
        streamSendKey(Int16(bitPattern: UInt16(0x8000 | vk)), Int8(down ? KEY_ACTION_DOWN : KEY_ACTION_UP), 0)
    }
}

/// The pad engine's mouse buttons to GameStream's.
enum StreamMouseButtons {
    static func from(engine b: Int) -> Int32 {
        switch b { case 0: BUTTON_LEFT; case 1: BUTTON_RIGHT; case 2: BUTTON_MIDDLE; case 3: BUTTON_X1; case 4: BUTTON_X2; default: BUTTON_LEFT }
    }
    static func from(mac n: Int) -> Int32 {
        switch n { case 0: BUTTON_LEFT; case 1: BUTTON_RIGHT; case 2: BUTTON_MIDDLE; case 3: BUTTON_X1; case 4: BUTTON_X2; default: 0 }
    }
}

/// Where DesktopPad sends a profile's output while a stream window is in front.
@MainActor protocol StreamPadRoute: AnyObject {
    /// The Nokcandu profile the stream uses, or nil for the controller as it is.
    var profileID: String? { get }
    /// The stream window is the key window of the active app.
    var isFront: Bool { get }
    func padButton(_ b: Int, _ down: Bool)
    func padAxis(_ a: Int, _ v: Int)
    func key(_ mac: Int, _ down: Bool)
    func mouseButton(_ b: Int, _ down: Bool)
    func mouseMove(_ dx: Int, _ dy: Int)
    func wheel(_ clicks: Int)
    func text(_ s: String)
}

/// Sends a key and records the first few (and every failure) in the stream log.
@discardableResult func streamSendKey(_ code: Int16, _ action: Int8, _ modifiers: Int8) -> Int32 {
    let rc = LiSendKeyboardEvent(code, action, modifiers)
    StreamInputLog.note("key \(String(format: "0x%02X", Int(code) & 0xFF)) \(action == Int8(KEY_ACTION_DOWN) ? "down" : "up") mods \(modifiers)", rc)
    return rc
}

/// The first input events of each kind, and any the core refused, for troubleshooting.
enum StreamInputLog {
    nonisolated(unsafe) static var counts: [String: Int] = [:]
    static func reset() { counts = [:] }
    static func note(_ what: String, _ rc: Int32) {
        let kind = String(what.prefix(while: { $0 != " " }))
        let n = (counts[kind] ?? 0) + 1
        counts[kind] = n
        if n <= 5 || rc != 0 { StreamLog.shared.add("Input: \(what) → \(rc)") }
    }
}
