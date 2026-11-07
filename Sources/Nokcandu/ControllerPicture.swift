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

    typealias I = PadProfiles.Input
    /// The controller symbol's proportions (width ÷ height), and where its own d-pad and buttons sit (fractions of it).
    static let aspect: CGFloat = 1.45

    /// Places on the symbol, as fractions of the symbol's box; shoulders and triggers sit above it.
    func place(_ i: I) -> CGPoint {
        let ps = family == .playstation
        let dpad = CGPoint(x: 0.265, y: 0.40), face = CGPoint(x: 0.735, y: 0.40)
        switch i {
        case .up: return CGPoint(x: dpad.x, y: dpad.y - 0.105)
        case .down: return CGPoint(x: dpad.x, y: dpad.y + 0.105)
        case .left: return CGPoint(x: dpad.x - 0.07, y: dpad.y)
        case .right: return CGPoint(x: dpad.x + 0.07, y: dpad.y)
        case .y: return CGPoint(x: face.x, y: face.y - 0.105)
        case .a: return CGPoint(x: face.x, y: face.y + 0.105)
        case .x: return CGPoint(x: face.x - 0.07, y: face.y)
        case .b: return CGPoint(x: face.x + 0.07, y: face.y)
        case .back: return CGPoint(x: 0.42, y: 0.30)
        case .start: return CGPoint(x: 0.58, y: 0.30)
        case .guide: return CGPoint(x: 0.5, y: ps ? 0.50 : 0.18)
        case .lb: return CGPoint(x: 0.22, y: -0.08)
        case .rb: return CGPoint(x: 0.78, y: -0.08)
        case .lt: return CGPoint(x: 0.22, y: -0.24)
        case .rt: return CGPoint(x: 0.78, y: -0.24)
        case .ltfull: return CGPoint(x: 0.10, y: -0.24)
        case .rtfull: return CGPoint(x: 0.90, y: -0.24)
        default: return CGPoint(x: -1, y: -1)
        }
    }
    var shown: [I] { [.lt, .rt, .ltfull, .rtfull, .lb, .rb, .up, .down, .left, .right, .y, .a, .x, .b, .back, .start, .guide] }
    var stickPlaces: [CGPoint] { [CGPoint(x: 0.38, y: 0.62), CGPoint(x: 0.62, y: 0.62)] }

    var body: some View {
        GeometryReader { geo in
            // The symbol fills the width, below room for the shoulders and triggers.
            let sw = min(geo.size.width * 0.84, (geo.size.height * 0.70) * Self.aspect)
            let sh = sw / Self.aspect
            let x0 = (geo.size.width - sw) / 2, y0 = geo.size.height * 0.27
            let at = { (p: CGPoint) in CGPoint(x: x0 + p.x * sw, y: y0 + p.y * sh) }
            ZStack {
                Image(systemName: "gamecontroller.fill")
                    .resizable().aspectRatio(Self.aspect, contentMode: .fit)
                    .foregroundStyle(Color.secondary.opacity(0.16))
                    .frame(width: sw, height: sh)
                    .position(x: x0 + sw / 2, y: y0 + sh / 2)
                    .accessibilityHidden(true)
                ForEach(shown, id: \.self) { i in spot(i).position(at(place(i))) }
                ForEach(0..<2, id: \.self) { s in stick(s).position(at(stickPlaces[s])) }
                Button { selection = .gyro } label: {
                    Label("Gyro", systemImage: "gyroscope").font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(selection == .gyro ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain).position(at(CGPoint(x: 0.5, y: 0.92)))
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
                    .frame(minWidth: round ? 24 : 40, minHeight: 24)
                    .background(Capsule().fill(on ? Color.accentColor : mapped(i) ? Color.accentColor.opacity(0.35) : Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                if let l = label(i) { Text(l).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 60) }
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
                Circle().fill(pressed.contains(click) ? Color.accentColor.opacity(0.5) : Color(nsColor: .controlBackgroundColor)).frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 0.5).frame(width: 46, height: 46)
                Circle().fill(Color.primary.opacity(0.55)).frame(width: 12, height: 12).offset(x: p.x * 18, y: -p.y * 18)
                if let l = label(click) { Text(l).font(.system(size: 9)).foregroundStyle(.secondary).offset(y: 34) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s == 0 ? "Left stick" : "Right stick")
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

    func start(profile text: String) {
        reload(text)
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
        if let e = engine { pe_destroy(e) }; engine = nil
    }
    func reload(_ text: String) {
        if let e = engine { pe_release_all(e, Self.now()); pe_destroy(e) }
        held = [:]; holding = []
        var sink = pe_sink()
        sink.ctx = Unmanaged.passUnretained(self).toOpaque()
        sink.pad_button = { c, b, d in PadTester.of(c).out("pad:" + String(cString: pe_input_name(b)), d) }
        sink.pad_axis = { _, _, _ in }
        sink.key = { c, k, d in PadTester.of(c).out("key:\(k)", d) }
        sink.mouse_button = { c, b, d in PadTester.of(c).out("mouse:\(["left", "right", "middle", "back", "forward"][Int(b)])", d) }
        sink.mouse_move = { c, x, y in PadTester.of(c).move(Int(x), Int(y)) }
        sink.wheel = { c, n in PadTester.of(c).flash("wheel:\(n > 0 ? "up" : "down")") }
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

    func title(_ token: String) -> String { PadProfiles.Output(token: token)?.title(family) ?? token }

    private func attach() {
        let c = GCController.controllers().first { $0.extendedGamepad != nil }
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
                    if let e = self.engine { pe_gyro(e, Float(r.x), Float(r.y), Float(r.z), Self.now()) }
                }
            }
        } else { hasMotion = false }
    }

    private func read(_ g: GCExtendedGamepad) {
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
        let now = Self.now()
        var p = Set<I>()
        for (i, down) in buttons {
            if down { p.insert(i) }
            let n = Int(pe_input_named(i.rawValue))
            if lastButtons[n] != down { lastButtons[n] = down; if let e = engine { pe_button(e, Int32(n), down, now) } }
        }
        let axes: [(Int32, Float)] = [(0, g.leftThumbstick.xAxis.value), (1, -g.leftThumbstick.yAxis.value),
                                      (2, g.rightThumbstick.xAxis.value), (3, -g.rightThumbstick.yAxis.value),
                                      (4, g.leftTrigger.value), (5, g.rightTrigger.value)]
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
                        if tester.hasMotion { Text(String(format: "Gyro: %.0f °/s", tester.gyroSpeed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
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
