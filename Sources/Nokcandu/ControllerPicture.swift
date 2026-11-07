import SwiftUI
import GameController
import NokcanduCore
import NokcanduPadEngine

/// A drawn controller: click any button, a stick, the triggers or the gyro to set what it does. Buttons that do
/// something else are tinted and show it; pressed buttons light up while testing.
struct ControllerPicture: View {
    let family: Controllers.Family?
    @Binding var selection: ControllerProfileEditor.Part
    @ObservedObject var tester: PadTester
    var pressed: Set<PadProfiles.Input> { tester.pressed }
    var sticks: [CGPoint] { tester.sticks }
    let mapped: (PadProfiles.Input) -> Bool
    let label: (PadProfiles.Input) -> String?
    /// What each stick does, when it isn't simply a stick ("Mouse", "WSAD"…).
    var stickLabel: (Int) -> String? = { _ in nil }

    typealias I = PadProfiles.Input
    /// The drawn body's proportions (width ÷ height). Places are fractions of the body's box.
    static let aspect: CGFloat = 1.55

    var psLayout: Bool { family == .playstation }
    /// Xbox and Nintendo: left stick high, d-pad low. PlayStation: d-pad high, both sticks low.
    var dpadCenter: CGPoint { psLayout ? CGPoint(x: 0.24, y: 0.36) : CGPoint(x: 0.37, y: 0.585) }
    var stickPlaces: [CGPoint] { [psLayout ? CGPoint(x: 0.37, y: 0.585) : CGPoint(x: 0.24, y: 0.36), CGPoint(x: 0.63, y: 0.585)] }

    func place(_ i: I) -> CGPoint {
        let d = dpadCenter, face = CGPoint(x: 0.76, y: 0.36)
        let dx: CGFloat = 0.058, dy: CGFloat = 0.09
        switch i {
        case .up: return CGPoint(x: d.x, y: d.y - dy)
        case .down: return CGPoint(x: d.x, y: d.y + dy)
        case .left: return CGPoint(x: d.x - dx, y: d.y)
        case .right: return CGPoint(x: d.x + dx, y: d.y)
        // Nintendo: A right, B bottom, X top, Y left. Others: Y top, A bottom, X left, B right.
        case .y: return family == .nintendo ? CGPoint(x: face.x - dx, y: face.y) : CGPoint(x: face.x, y: face.y - dy)
        case .a: return family == .nintendo ? CGPoint(x: face.x + dx, y: face.y) : CGPoint(x: face.x, y: face.y + dy)
        case .x: return family == .nintendo ? CGPoint(x: face.x, y: face.y - dy) : CGPoint(x: face.x - dx, y: face.y)
        case .b: return family == .nintendo ? CGPoint(x: face.x, y: face.y + dy) : CGPoint(x: face.x + dx, y: face.y)
        case .back: return CGPoint(x: 0.42, y: 0.33)
        case .start: return CGPoint(x: 0.58, y: 0.33)
        case .guide: return CGPoint(x: 0.5, y: psLayout ? 0.47 : 0.19)
        case .lb: return CGPoint(x: 0.22, y: -0.07)
        case .rb: return CGPoint(x: 0.78, y: -0.07)
        case .lt: return CGPoint(x: 0.22, y: -0.24)
        case .rt: return CGPoint(x: 0.78, y: -0.24)
        case .ltfull: return CGPoint(x: 0.1, y: -0.24)
        case .rtfull: return CGPoint(x: 0.9, y: -0.24)
        default: return CGPoint(x: -1, y: -1)
        }
    }
    var shown: [I] { [.lt, .rt, .ltfull, .rtfull, .lb, .rb, .up, .down, .left, .right, .y, .a, .x, .b, .back, .start, .guide] }

    var body: some View {
        GeometryReader { geo in
            let sw = min(geo.size.width * 0.92, (geo.size.height * 0.74) * Self.aspect)
            let sh = sw / Self.aspect
            let x0 = (geo.size.width - sw) / 2, y0 = geo.size.height - sh - 2
            let at = { (p: CGPoint) in CGPoint(x: x0 + p.x * sw, y: y0 + p.y * sh) }
            ZStack {
                ControllerShape()
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                    .overlay(ControllerShape().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .frame(width: sw, height: sh)
                    .position(x: x0 + sw / 2, y: y0 + sh / 2)
                    .accessibilityHidden(true)
                // the d-pad's cross, under its four buttons
                DPadWell().fill(Color.primary.opacity(0.08))
                    .frame(width: sw * 0.17, height: sh * 0.265)
                    .position(at(dpadCenter))
                    .accessibilityHidden(true)
                ForEach(shown, id: \.self) { i in spot(i).position(at(place(i))) }
                ForEach(0..<2, id: \.self) { s in stick(s).position(at(stickPlaces[s])) }
                Button { selection = .gyro } label: {
                    Label("Gyro", systemImage: "gyroscope").font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(selection == .gyro ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
                        .overlay(Capsule().stroke(selection == .gyro ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain).position(at(CGPoint(x: 0.5, y: 0.93)))
                .accessibilityLabel("Gyro settings")
            }
        }
    }

    func spot(_ i: I) -> some View {
        let selected = selection == .input(i)
        let on = pressed.contains(i)
        let round = ![.lb, .rb, .lt, .rt, .ltfull, .rtfull].contains(i)
        let short: String = {
            switch i {
            case .up: "▲"; case .down: "▼"; case .left: "◀"; case .right: "▶"
            case .ltfull, .rtfull: "full"
            default: i.title(family).count <= 3 ? i.title(family) : String(i.title(family).prefix(1))
            }
        }()
        return Button { selection = .input(i) } label: {
            VStack(spacing: 1) {
                Text(short).font(.system(size: 11, weight: .semibold))
                    .frame(minWidth: round ? 28 : 46, minHeight: 28)
                    .background(Capsule().fill(on ? Color.accentColor : mapped(i) ? Color.accentColor.opacity(0.35) : Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                if let l = label(i), l != "—" { Text(l).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor).lineLimit(1).frame(maxWidth: 64) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i.title(family) + (label(i).map { ": \($0)" } ?? ""))
        .help(i.title(family))
    }

    func stick(_ s: Int) -> some View {
        let p = sticks.indices.contains(s) ? sticks[s] : .zero
        let click: I = s == 0 ? .ls : .rs
        let selected = selection == .stick(s) || selection == .input(click)
        return Button { selection = .stick(s) } label: {
            ZStack {
                Circle().fill(pressed.contains(click) ? Color.accentColor.opacity(0.5) : stickLabel(s) != nil ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor)).frame(width: 54, height: 54)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 0.5).frame(width: 54, height: 54)
                Circle().fill(Color.primary.opacity(0.55)).frame(width: 12, height: 12).offset(x: p.x * 20, y: -p.y * 20)
                VStack(spacing: 0) {
                    if let m = stickLabel(s) { Text(m).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor).lineLimit(1).fixedSize() }
                    if let l = label(click), l != "—" { Text("click: " + l).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.accentColor.opacity(0.85)).lineLimit(1).fixedSize() }
                }
                .offset(y: 42)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel((s == 0 ? "Left stick" : "Right stick") + (stickLabel(s).map { ": \($0)" } ?? ""))
    }
}

// MARK: - Live test

/// Reads the connected controller through macOS and runs it through the same mapping engine as the game, so the
/// editor can show what the game would get: keys, mouse buttons, mouse movement, controller buttons.
@MainActor
final class PadTester: ObservableObject {
    @Published var pressed: Set<PadProfiles.Input> = []
    @Published var sticks: [CGPoint] = [.zero, .zero]
    @Published var holding: [String] = []          // outputs held now
    @Published var dot = CGPoint(x: 0.5, y: 0.5)   // where the mouse would go (0…1, wraps)
    @Published var gyroSpeed = 0.0                  // degrees per second
    /// The profile's devices: inputs held now ("<device id>.<key>"), axis positions (−1…1, "<id>.<n>"), and the
    /// last thing pressed or moved on one (to pick it by pressing).
    @Published var deviceHeld: Set<String> = []
    @Published var deviceAxes: [String: Double] = [:]
    @Published var lastDeviceInput: DeviceInput?
    struct DeviceInput: Equatable { let device: String; let key: String; let at: Double }
    private var axesPending: [String: Double] = [:], axesFlush = false
    private lazy var feed: DeviceFeed = {
        let f = DeviceFeed { [weak self] in self?.engine }
        f.onInput = { [weak self] id, k, down in self?.deviceInput(id, k, down) }
        f.onAxis = { [weak self] id, n, v in self?.deviceAxis(id, n, v) }
        return f
    }()
    private var devices: [PadProfiles.Device] = []
    private var padAxes: [Int: Int] = [:]
    @Published var controllerName: String?
    @Published var hasMotion = false

    private var engine: OpaquePointer?
    private var held: [String: Int] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastButtons: [Int: Bool] = [:]
    private var lastAxes: [Int: Int] = [:]
    private var lastGyroShown = 0.0
    var family: Controllers.Family?

    func start(profile text: String, devices: [PadProfiles.Device] = []) {
        DesktopPad.testerOpen = true
        reload(text, devices: devices)
        observers.append(NotificationCenter.default.addObserver(forName: .hidDevicesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        })
        GCController.shouldMonitorBackgroundEvents = true
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        })
        attach()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, let e = self.engine else { return }; pe_tick(e, Self.now()) }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        for c in GCController.controllers() { c.extendedGamepad?.valueChangedHandler = nil; c.motion?.valueChangedHandler = nil }
        feed.stop()
        if let e = engine { pe_destroy(e) }; engine = nil
        DesktopPad.testerOpen = false
        DesktopPad.shared.attach()
    }
    func reload(_ text: String, devices: [PadProfiles.Device]? = nil) {
        if let e = engine { pe_release_all(e, Self.now()); pe_destroy(e) }
        held = [:]; holding = []; padAxes = [:]
        if let devices, devices != self.devices {
            self.devices = devices
            feed.set(devices, always: true)
            attach()
        }
        var sink = pe_sink()
        sink.ctx = Unmanaged.passUnretained(self).toOpaque()
        sink.pad_button = { c, b, d in PadTester.of(c).out("pad:" + String(cString: pe_input_name(b)), d) }
        sink.pad_axis = { c, a, v in PadTester.of(c).axisOut(Int(a), Int(v)) }
        sink.key = { c, k, d in PadTester.of(c).out("key:\(k)", d) }
        sink.mouse_button = { c, b, d in PadTester.of(c).out("mouse:\(["left", "right", "middle", "back", "forward"][Int(b)])", d) }
        sink.mouse_move = { c, x, y in PadTester.of(c).move(Int(x), Int(y)) }
        sink.wheel = { c, n in PadTester.of(c).flash("wheel:\(n > 0 ? "up" : "down")") }
        sink.text = { c, t in let s = t.map { String(cString: $0) } ?? ""; PadTester.of(c).flash("text:" + s) }
        sink.menu = { c, m, sl in PadTester.of(c).menu(Int(m), Int(sl)) }
        sink.calibration = { _, p in MainActor.assumeIsolated { PadHUD.shared.calibration(p) } }
        engine = text.withCString { pe_create($0, sink) }
        lastButtons = [:]; lastAxes = [:]
    }
    nonisolated static func of(_ c: UnsafeMutableRawPointer?) -> PadTester { Unmanaged<PadTester>.fromOpaque(c!).takeUnretainedValue() }
    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    nonisolated func out(_ token: String, _ down: Bool) {
        MainActor.assumeIsolated {
            held[token, default: 0] += down ? 1 : -1
            if (held[token] ?? 0) <= 0 { held[token] = nil }
            holding = held.keys.sorted()
        }
    }
    nonisolated func flash(_ token: String) {
        MainActor.assumeIsolated {
            out(token, true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.out(token, false) }
        }
    }
    nonisolated func move(_ x: Int, _ y: Int) {
        MainActor.assumeIsolated {
            var d = dot
            d.x = (d.x + Double(x) / 1500).truncatingRemainder(dividingBy: 1); if d.x < 0 { d.x += 1 }
            d.y = (d.y + Double(y) / 1000).truncatingRemainder(dividingBy: 1); if d.y < 0 { d.y += 1 }
            dot = d
        }
    }

    /// A stick or trigger the game would see moved (from a device's axis, or the gyro as a stick).
    nonisolated func axisOut(_ a: Int, _ v: Int) {
        MainActor.assumeIsolated {
            let was = abs(padAxes[a] ?? 0) > 9000, now = abs(v) > 9000
            padAxes[a] = v
            if was != now { out("axis:\(a)", now) }
        }
    }
    private func deviceInput(_ id: String, _ k: String, _ down: Bool) {
        let key = id + "." + k
        if down { if !deviceHeld.contains(key) { deviceHeld.insert(key) }; lastDeviceInput = DeviceInput(device: id, key: k, at: Self.now()) }
        else if deviceHeld.contains(key) { deviceHeld.remove(key) }
    }
    private func deviceAxis(_ id: String, _ n: Int, _ v: Double) {
        let key = id + "." + String(n), old = deviceAxes[key] ?? 0
        // Moved well away from where it was: that's the axis being picked (a resting pedal or throttle doesn't count).
        if abs(v - old) > 0.5 && abs(v) > 0.5 { lastDeviceInput = DeviceInput(device: id, key: "axis\(n)", at: Self.now()) }
        axesPending[key] = (v * 50).rounded() / 50
        guard !axesFlush else { return }
        axesFlush = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.axesFlush = false
            var a = self.deviceAxes
            for (k, v) in self.axesPending { a[k] = v }
            self.axesPending = [:]
            if a != self.deviceAxes { self.deviceAxes = a }
        }
    }

    /// The radial menu open in the test (its slice pointed at), and whether the keyboard was asked for.
    @Published var openMenu: (menu: Int, slice: Int)?
    nonisolated func menu(_ m: Int, _ slice: Int) {
        MainActor.assumeIsolated {
            if m == Int(PE_KEYBOARD_MENU) { flash("keyboard"); return }
            if m == Int(PE_RUMBLE_MENU) { flash("rumble"); PadFeedback.shared.rumble(GCController.controllers(), strong: true); return }
            openMenu = slice == -2 ? nil : (m, slice)
        }
    }
    func calibrate() { if let e = engine { pe_calibrate(e, Self.now()) } }

    func title(_ token: String) -> String {
        if token.hasPrefix("text:") { return "Types “\(token.dropFirst(5))”" }
        if token.hasPrefix("axis:"), let a = Int(token.dropFirst(5)) {
            return ["Left stick", "Left stick", "Right stick", "Right stick", PadProfiles.Input.lt.title(family), PadProfiles.Input.rt.title(family)][min(max(a, 0), 5)]
        }
        return PadProfiles.Output(token: token)?.title(family) ?? token
    }

    private func attach() {
        feed.attachGamepads()
        let c = feed.mainControllers().first
        controllerName = c?.vendorName
        guard let c, let gp = c.extendedGamepad else { hasMotion = false; return }
        gp.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated { self?.read(pad) }
        }
        if let m = c.motion {
            hasMotion = m.hasRotationRate
            if m.sensorsRequireManualActivation { m.sensorsActive = true }
            m.valueChangedHandler = { [weak self] motion in
                let r = motion.rotationRate
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let speed = (sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 180 / .pi).rounded()
                    let t = Self.now()
                    if speed != self.gyroSpeed, t - self.lastGyroShown > 0.1 { self.gyroSpeed = speed; self.lastGyroShown = t }
                    if let e = self.engine {
                        pe_gyro(e, Float(r.x), Float(r.y), Float(r.z), Self.now())
                        let a = motion.hasGravityAndUserAcceleration ? motion.gravity : motion.acceleration
                        if pe_uses_tilt(e) { pe_accel(e, Float(a.x), Float(a.y), Float(a.z), Self.now()) }
                    }
                }
            }
        } else { hasMotion = false }
        PadGC.watchTouchpads(c) { [weak self] f, down, x, y in
            MainActor.assumeIsolated { if let e = self?.engine { pe_touch(e, Int32(f), down, x, y, Self.now()) } }
        }
    }

    private func read(_ g: GCExtendedGamepad) {
        typealias I = PadProfiles.Input
        let (buttons, axes) = PadGC.state(g)
        let now = Self.now()
        var p = Set<I>()
        for (i, down) in buttons {
            if down { p.insert(i) }
            let n = Int(pe_input_named(i.rawValue))
            if lastButtons[n] != down { lastButtons[n] = down; if let e = engine { pe_button(e, Int32(n), down, now) } }
        }
        for (a, v) in axes {
            let iv = Int(max(-32768, min(32767, v * 32767)))
            if lastAxes[Int(a)] != iv { lastAxes[Int(a)] = iv; if let e = engine { pe_axis(e, a, Int32(iv), now) } }
        }
        if g.leftTrigger.value > 0.3 { p.insert(.lt) }
        if g.rightTrigger.value > 0.3 { p.insert(.rt) }
        if g.leftTrigger.value > 0.95 { p.insert(.ltfull) }
        if g.rightTrigger.value > 0.95 { p.insert(.rtfull) }
        if p != pressed { pressed = p }
        let s = [CGPoint(x: (Double(g.leftThumbstick.xAxis.value) * 20).rounded() / 20, y: (Double(g.leftThumbstick.yAxis.value) * 20).rounded() / 20),
                 CGPoint(x: (Double(g.rightThumbstick.xAxis.value) * 20).rounded() / 20, y: (Double(g.rightThumbstick.yAxis.value) * 20).rounded() / 20)]
        if s != sticks { sticks = s }
    }
}

struct PadTestView: View {
    @ObservedObject var tester: PadTester
    let family: Controllers.Family?

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let n = tester.controllerName {
                        Text("Testing with \(n)").font(.caption).foregroundStyle(.secondary)
                        if tester.holding.isEmpty {
                            Text("Press buttons to see what the game gets.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            FlowRow {
                                ForEach(tester.holding, id: \.self) { t in
                                    Text(tester.title(t)).font(.callout.weight(.medium))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.3)))
                                }
                            }
                        }
                        if let m = tester.openMenu {
                            Text(m.slice >= 0 ? "Radial menu: choice \(m.slice + 1)" : "Radial menu open — point a stick").font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
                        }
                        if tester.hasMotion {
                            HStack(spacing: 8) {
                                Text(String(format: "Gyro: %.0f °/s", tester.gyroSpeed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button("Calibrate") { tester.calibrate() }.controlSize(.small)
                                    .help("Put the controller down (or hold it very still) for two seconds")
                            }
                        }
                    } else {
                        Text("Connect a controller to test the profile here.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1))
                    GeometryReader { g in
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            .position(x: tester.dot.x * g.size.width, y: tester.dot.y * g.size.height)
                    }
                }
                .frame(width: 110, height: 70)
                .help("Mouse movement from the sticks or gyro")
                .accessibilityLabel("Mouse movement preview")
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Test").font(.headline) }
        .onAppear { tester.family = family }
        .onChange(of: family) { _, f in tester.family = f }
    }
}


/// A controller body: a wide top with rounded shoulders and two grips, no holes.
struct ControllerShape: Shape {
    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.30, 0.05))
        path.addCurve(to: p(0.70, 0.05), control1: p(0.40, 0.03), control2: p(0.60, 0.03))
        path.addCurve(to: p(0.96, 0.42), control1: p(0.80, 0.07), control2: p(0.94, 0.16))
        path.addCurve(to: p(0.85, 0.98), control1: p(0.99, 0.70), control2: p(0.96, 0.98))
        path.addCurve(to: p(0.70, 0.78), control1: p(0.77, 0.98), control2: p(0.75, 0.84))
        path.addCurve(to: p(0.30, 0.78), control1: p(0.60, 0.69), control2: p(0.40, 0.69))
        path.addCurve(to: p(0.15, 0.98), control1: p(0.25, 0.84), control2: p(0.23, 0.98))
        path.addCurve(to: p(0.04, 0.42), control1: p(0.04, 0.98), control2: p(0.01, 0.70))
        path.addCurve(to: p(0.30, 0.05), control1: p(0.06, 0.16), control2: p(0.20, 0.07))
        path.closeSubpath()
        return path
    }
}

/// A rounded plus: the well the d-pad's buttons sit in.
struct DPadWell: Shape {
    func path(in r: CGRect) -> Path {
        let t = min(r.width, r.height) * 0.36
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.midX - t / 2, y: r.minY, width: t, height: r.height), cornerSize: CGSize(width: t / 3, height: t / 3))
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.midY - t / 2, width: r.width, height: t), cornerSize: CGSize(width: t / 3, height: t / 3))
        return p
    }
}


/// A controller's buttons and axes from macOS's GameController framework, in the mapping engine's terms.
enum PadGC {
    /// The connected controller's name, to remember choices per controller.
    static var connectedName: String {
        GCController.controllers().first { $0.extendedGamepad != nil }.map { $0.vendorName ?? $0.productCategory } ?? "none"
    }
    /// The connected controller's maker, from the name macOS gives it (a Switch Pro Controller, a DualSense…),
    /// else from the devices' maker codes.
    static func connectedFamily() -> Controllers.Family? {
        for c in GCController.controllers() where c.extendedGamepad != nil {
            let n = (c.productCategory + " " + (c.vendorName ?? "")).lowercased()
            if n.contains("switch") || n.contains("joy-con") || n.contains("nintendo") || n.contains("pro controller") { return .nintendo }
            if n.contains("dualsense") || n.contains("dualshock") || n.contains("playstation") || n.contains("ps4") || n.contains("ps5") { return .playstation }
            if n.contains("steam") { return .valve }
            if n.contains("xbox") { return nil }
        }
        return Controllers.connected().compactMap(\.family).first
    }

    /// The touchpad's fingers (DualSense, DualShock 4): 0 or 1, touching or lifted, at x, y 0…1 (y down).
    static func watchTouchpads(_ c: GCController, _ f: @escaping (Int, Bool, Float, Float) -> Void) {
        let pads = c.physicalInputProfile.allElements.compactMap { $0 as? GCControllerTouchpad }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for (i, tp) in pads.prefix(2).enumerated() {
            let finger = i
            let report: GCControllerTouchpadHandler = { _, x, y, _, _ in f(finger, true, (x + 1) / 2, (1 - y) / 2) }
            tp.touchDown = report
            tp.touchMoved = report
            tp.touchUp = { _, x, y, _, _ in f(finger, false, (x + 1) / 2, (1 - y) / 2) }
        }
    }

    static func state(_ g: GCExtendedGamepad) -> (buttons: [(PadProfiles.Input, Bool)], axes: [(Int32, Float)]) {
        typealias I = PadProfiles.Input
        var buttons: [(I, Bool)] = [
            (.a, g.buttonA.isPressed), (.b, g.buttonB.isPressed), (.x, g.buttonX.isPressed), (.y, g.buttonY.isPressed),
            (.lb, g.leftShoulder.isPressed), (.rb, g.rightShoulder.isPressed),
            (.ls, g.leftThumbstickButton?.isPressed ?? false), (.rs, g.rightThumbstickButton?.isPressed ?? false),
            (.start, g.buttonMenu.isPressed), (.back, g.buttonOptions?.isPressed ?? false), (.guide, g.buttonHome?.isPressed ?? false),
            (.up, g.dpad.up.isPressed), (.down, g.dpad.down.isPressed), (.left, g.dpad.left.isPressed), (.right, g.dpad.right.isPressed),
        ]
        if let ds = g as? GCDualSenseGamepad { buttons.append((.touchpad, ds.touchpadButton.isPressed)) }
        else if let d4 = g as? GCDualShockGamepad { buttons.append((.touchpad, d4.touchpadButton.isPressed)) }
        if let xb = g as? GCXboxGamepad {
            buttons += [(.paddle1, xb.paddleButton1?.isPressed ?? false), (.paddle2, xb.paddleButton2?.isPressed ?? false),
                        (.paddle3, xb.paddleButton3?.isPressed ?? false), (.paddle4, xb.paddleButton4?.isPressed ?? false),
                        (.misc, xb.buttonShare?.isPressed ?? false)]
        }
        let axes: [(Int32, Float)] = [(0, g.leftThumbstick.xAxis.value), (1, -g.leftThumbstick.yAxis.value),
                                      (2, g.rightThumbstick.xAxis.value), (3, -g.rightThumbstick.yAxis.value),
                                      (4, g.leftTrigger.value), (5, g.rightTrigger.value)]
        return (buttons, axes)
    }
}
