import SwiftUI
import GameController
import NokcanduCore
import NokcanduPadEngine

/// A drawn controller: click any button, a stick, the triggers or the gyro to set what it does. Buttons that do
/// something else are tinted and show it; pressed buttons light up while testing.
struct ControllerPicture: View {
    let family: Controllers.Family?
    @Binding var selection: ControllerProfileEditor.Part
    let pressed: Set<PadProfiles.Input>
    let sticks: [CGPoint]
    let mapped: (PadProfiles.Input) -> Bool
    let label: (PadProfiles.Input) -> String?

    typealias I = PadProfiles.Input
    /// Positions as fractions of the picture (Xbox and Nintendo layout; PlayStation swaps the left stick and d-pad).
    var spots: [(I, CGPoint)] {
        let ps = family == .playstation
        let dpad = ps ? CGPoint(x: 0.25, y: 0.42) : CGPoint(x: 0.36, y: 0.66)
        return [
            (.lt, CGPoint(x: 0.2, y: 0.05)), (.rt, CGPoint(x: 0.8, y: 0.05)),
            (.lb, CGPoint(x: 0.2, y: 0.15)), (.rb, CGPoint(x: 0.8, y: 0.15)),
            (.up, CGPoint(x: dpad.x, y: dpad.y - 0.08)), (.down, CGPoint(x: dpad.x, y: dpad.y + 0.08)),
            (.left, CGPoint(x: dpad.x - 0.055, y: dpad.y)), (.right, CGPoint(x: dpad.x + 0.055, y: dpad.y)),
            (.y, CGPoint(x: 0.76, y: 0.32)), (.x, CGPoint(x: 0.7, y: 0.42)), (.b, CGPoint(x: 0.82, y: 0.42)), (.a, CGPoint(x: 0.76, y: 0.52)),
            (.back, CGPoint(x: 0.41, y: 0.34)), (.start, CGPoint(x: 0.59, y: 0.34)), (.guide, CGPoint(x: 0.5, y: ps ? 0.56 : 0.26)),
            (.ltfull, CGPoint(x: 0.09, y: 0.05)), (.rtfull, CGPoint(x: 0.91, y: 0.05)),
        ]
    }
    var stickSpots: [CGPoint] {
        family == .playstation ? [CGPoint(x: 0.37, y: 0.68), CGPoint(x: 0.63, y: 0.68)] : [CGPoint(x: 0.25, y: 0.42), CGPoint(x: 0.64, y: 0.66)]
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                body(w: w, h: h)
                ForEach(Array(spots.enumerated()), id: \.offset) { _, s in
                    spot(s.0).position(x: s.1.x * w, y: s.1.y * h)
                }
                ForEach(0..<2, id: \.self) { i in
                    stick(i).position(x: stickSpots[i].x * w, y: stickSpots[i].y * h)
                }
                Button { selection = .gyro } label: {
                    Label("Gyro", systemImage: "gyroscope").font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(selection == .gyro ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain).position(x: 0.5 * w, y: 0.86 * h)
                .accessibilityLabel("Gyro settings")
            }
        }
    }

    func body(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: h * 0.22).fill(Color.secondary.opacity(0.10))
                .frame(width: w * 0.78, height: h * 0.52).position(x: w * 0.5, y: h * 0.45)
            Ellipse().fill(Color.secondary.opacity(0.10)).frame(width: w * 0.3, height: h * 0.62).rotationEffect(.degrees(-18)).position(x: w * 0.22, y: h * 0.62)
            Ellipse().fill(Color.secondary.opacity(0.10)).frame(width: w * 0.3, height: h * 0.62).rotationEffect(.degrees(18)).position(x: w * 0.78, y: h * 0.62)
        }
        .accessibilityHidden(true)
    }

    func spot(_ i: I) -> some View {
        let selected = selection == .input(i)
        let on = pressed.contains(i)
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
                    .frame(minWidth: 26, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor : mapped(i) ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
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
                Circle().fill(pressed.contains(click) ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.18)).frame(width: 50, height: 50)
                Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2).frame(width: 50, height: 50)
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
                    self.gyroSpeed = sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 180 / .pi
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
        sticks = [CGPoint(x: Double(g.leftThumbstick.xAxis.value), y: Double(g.leftThumbstick.yAxis.value)),
                  CGPoint(x: Double(g.rightThumbstick.xAxis.value), y: Double(g.rightThumbstick.yAxis.value))]
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
