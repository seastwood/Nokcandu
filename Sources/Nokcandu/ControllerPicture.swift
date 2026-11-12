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
    /// A Steam Controller trackpad's settings as they apply (left 0, right 1), for drawing its angle and edge.
    var steamPad: (Int) -> PadSteamTrackpadSettings? = { _ in nil }

    typealias I = PadProfiles.Input
    /// The drawn body's proportions (width ÷ height). Places are fractions of the body's box.
    static let aspect: CGFloat = 1.55
    /// The Steam Controller's trackpads, in points at the picture's full size.
    static let steamPadSize: CGFloat = 104

    var steamLayout: Bool { family == .valve }
    var psLayout: Bool { family == .playstation }
    /// Xbox and Nintendo: left stick high, d-pad low. PlayStation: d-pad high, both sticks low.
    var dpadCenter: CGPoint { psLayout ? CGPoint(x: 0.24, y: 0.36) : CGPoint(x: 0.37, y: 0.585) }
    var stickPlaces: [CGPoint] { steamLayout ? [CGPoint(x:0.37,y:0.66),CGPoint(x:0.75,y:0.33)] : [psLayout ? CGPoint(x: 0.37, y: 0.585) : CGPoint(x: 0.24, y: 0.36), CGPoint(x: 0.63, y: 0.585)] }

    func place(_ i: I) -> CGPoint {
        let d = dpadCenter, face = steamLayout ? CGPoint(x:0.63,y:0.67) : CGPoint(x: 0.76, y: 0.36)
        let dx: CGFloat = steamLayout ? 0.048 : 0.058, dy: CGFloat = steamLayout ? 0.075 : 0.09
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
        case .back: return steamLayout ? CGPoint(x: 0.42, y: 0.25) : CGPoint(x: 0.42, y: 0.33)
        case .start: return steamLayout ? CGPoint(x: 0.58, y: 0.25) : CGPoint(x: 0.58, y: 0.33)
        case .guide: return CGPoint(x: 0.5, y: steamLayout ? 0.25 : psLayout ? 0.47 : 0.19)
        case .paddle1: return CGPoint(x:0.79,y:0.86)
        case .paddle2: return CGPoint(x:0.21,y:0.86)
        case .lb: return CGPoint(x: 0.22, y: -0.07)
        case .rb: return CGPoint(x: 0.78, y: -0.07)
        case .lt: return CGPoint(x: 0.22, y: -0.24)
        case .rt: return CGPoint(x: 0.78, y: -0.24)
        case .ltfull: return CGPoint(x: 0.1, y: -0.24)
        case .rtfull: return CGPoint(x: 0.9, y: -0.24)
        default: return CGPoint(x: -1, y: -1)
        }
    }
    var shown: [I] { (steamLayout ? [.lt, .rt, .ltfull, .rtfull, .lb, .rb, .y, .a, .x, .b, .back, .start, .guide, .paddle1, .paddle2] : [.lt, .rt, .ltfull, .rtfull, .lb, .rb, .up, .down, .left, .right, .y, .a, .x, .b, .back, .start, .guide]) }

    var body: some View {
        GeometryReader { geo in
            let sw = min(geo.size.width * 0.92, (geo.size.height * 0.74) * Self.aspect)
            let sh = sw / Self.aspect
            let x0 = (geo.size.width - sw) / 2, y0 = geo.size.height - sh - 2
            // Controls keep their size down to a point, then shrink with the body so they never run into each other.
            let k = max(0.62, min(1, sw / 420))
            let at = { (p: CGPoint) in CGPoint(x: x0 + p.x * sw, y: y0 + (steamLayout && p.y >= 0 ? p.y - 0.06 : p.y) * sh) }
            ZStack {
                ControllerShape()
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                    .overlay(ControllerShape().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .frame(width: sw, height: sh)
                    .position(x: x0 + sw / 2, y: y0 + sh / 2)
                    .accessibilityHidden(true)
                // the d-pad's cross, under its four buttons
                if steamLayout {
                    Button { selection = .touchpad } label: {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.18)).frame(width:Self.steamPadSize*k,height:Self.steamPadSize*k)
                            Circle().stroke(selection == .touchpad ? Color.accentColor : Color.secondary.opacity(0.35),lineWidth:1.5).frame(width:Self.steamPadSize*k,height:Self.steamPadSize*k)
                            if let pad = steamPad(0) { SteamPadFace(side: 0, diameter: Self.steamPadSize*k, settings: pad, held: pressed, label: label) }
                            Circle().fill(Color.primary.opacity(0.55)).frame(width:10,height:10)
                                .offset(x:tester.leftSteamPad.x*Self.steamPadSize*0.42*k,y:-tester.leftSteamPad.y*Self.steamPadSize*0.42*k)
                            Text("Left trackpad").font(.caption2).lineLimit(1).fixedSize().offset(x:-Self.steamPadSize*0.2*k,y:Self.steamPadSize/2*k+9)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Left trackpad settings")
                        .position(at(CGPoint(x:0.25,y:0.33)))
                } else { DPadWell().fill(Color.primary.opacity(0.08))
                    .frame(width: sw * 0.17, height: sh * 0.265)
                    .position(at(dpadCenter))
                    .accessibilityHidden(true) }
                ForEach(shown, id: \.self) { i in spot(i, k).position(at(place(i))) }
                ForEach(0..<2, id: \.self) { s in stick(s, k).position(at(stickPlaces[s])) }
                Button { selection = .gyro } label: {
                    Label("Gyro", systemImage: "gyroscope").font(.callout)
                        .padding(.horizontal, 10 * k).padding(.vertical, 5 * k)
                        .background(Capsule().fill(selection == .gyro ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
                        .overlay(Capsule().stroke(selection == .gyro ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain).position(at(CGPoint(x: 0.5, y: 0.93)))
                .accessibilityLabel("Gyro settings")
            }
        }
    }

    func spot(_ i: I, _ k: CGFloat = 1) -> some View {
        let selected = selection == .input(i)
        let on = pressed.contains(i)
        let round = ![.lb, .rb, .lt, .rt, .ltfull, .rtfull].contains(i)
        let outwardLabel = steamLayout && [.y, .a, .x, .b].contains(i)
        let captionOffset: CGSize = i == .y ? CGSize(width: 0, height: -14 * k - 8) : i == .a ? CGSize(width: 0, height: 14 * k + 8) : CGSize(width: i == .x ? -12 * k - 32 : 12 * k + 32, height: 0)
        let short: String = {
            switch i {
            case .up: "▲"; case .down: "▼"; case .left: "◀"; case .right: "▶"
            case .ltfull, .rtfull: "full"
            case .guide where steamLayout: "Steam"
            case .back where steamLayout: "◀"
            case .start where steamLayout: "▶"
            case .paddle1 where steamLayout: "Rear R"
            case .paddle2 where steamLayout: "Rear L"
            default: i.title(family).count <= 3 ? i.title(family) : String(i.title(family).prefix(1))
            }
        }()
        return Button { selection = .input(i) } label: {
            VStack(spacing: 1) {
                Text(short).font(.system(size: max(9, 11 * k), weight: .semibold)).lineLimit(1)
                    .frame(minWidth: (steamLayout && [.guide, .paddle1, .paddle2].contains(i) ? 44 : round ? (steamLayout ? 24 : 28) : 46) * k, minHeight: 28 * k)
                    .background(Capsule().fill(on ? Color.accentColor : mapped(i) ? Color.accentColor.opacity(0.35) : Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                if !outwardLabel, let l = label(i), l != "—" { Text(l).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: 64).help(l) }
            }
            .overlay {
                if outwardLabel, let l = label(i), l != "—" {
                    Text(l).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.accentColor)
                        .lineLimit(1).minimumScaleFactor(0.7).frame(width: 58, alignment: i == .x ? .trailing : i == .b ? .leading : .center).help(l)
                        .offset(captionOffset)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(i.title(family) + (label(i).map { ": \($0)" } ?? ""))
        .help(i.title(family))
    }

    func stick(_ s: Int, _ k: CGFloat = 1) -> some View {
        let p = sticks.indices.contains(s) ? sticks[s] : .zero
        let click: I = s == 0 ? .ls : .rs
        let selected = selection == .stick(s) || selection == .input(click)
        let diameter: CGFloat = (steamLayout && s == 1 ? Self.steamPadSize : steamLayout ? 48 : 54) * k
        return Button { selection = .stick(s) } label: {
            ZStack {
                Circle().fill(pressed.contains(click) ? Color.accentColor.opacity(0.5) : stickLabel(s) != nil ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor)).frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 0.5).frame(width: diameter, height: diameter)
                if steamLayout && s == 1, let pad = steamPad(1) { SteamPadFace(side: 1, diameter: diameter, settings: pad, held: pressed, label: label) }
                Circle().fill(Color.primary.opacity(0.55)).frame(width: 12, height: 12).offset(x: p.x * (steamLayout && s == 1 ? Self.steamPadSize * 0.42 : 20) * k, y: -p.y * (steamLayout && s == 1 ? Self.steamPadSize * 0.42 : 20) * k)
                VStack(spacing: 0) {
                    if let m = steamLayout ? (s == 1 ? (stickLabel(s) ?? "Right trackpad") : "Joystick") : stickLabel(s) { Text(m).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor).lineLimit(1).fixedSize() }
                    if let l = label(click), l != "—" { Text("click: " + l).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.accentColor.opacity(0.85)).lineLimit(1).fixedSize() }
                }
                .offset(x: steamLayout && s == 1 ? diameter * 0.2 : 0, y: diameter/2+(steamLayout ? 9 : 13))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel((s == 0 ? "Left stick" : steamLayout ? "Right trackpad" : "Right stick") + (stickLabel(s).map { ": \($0)" } ?? ""))
    }
}

/// What a Steam Controller trackpad's settings look like on the pad itself: its axes turned by the pad angle,
/// the edge ring at its chosen size (lit while a finger is in it), and for four directions the dead zone and
/// what each way does.
struct SteamPadFace: View {
    let side: Int
    let diameter: CGFloat
    let settings: PadSteamTrackpadSettings
    let held: Set<PadProfiles.Input>
    let label: (PadProfiles.Input) -> String?

    var body: some View {
        let edge = PadSteamPadZones.edgeSize(settings), edgeInput = PadProfiles.Input.padEdge(side)
        let angle = settings.mode == .existing ? 0 : (settings.rotation ?? 0)
        let directions = PadProfiles.Input.padDirections(side)
        ZStack {
            if edge > 0 {
                Circle().strokeBorder(held.contains(edgeInput) ? Color.accentColor.opacity(0.75) : Color.accentColor.opacity(0.28), lineWidth: diameter / 2 * edge)
                Circle().stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])).frame(width: diameter * (1 - edge), height: diameter * (1 - edge))
            }
            if settings.mode != .existing {
                // The pad's own left–right and up–down, as the pointer or the directions will follow them.
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.32)).frame(width: diameter * 0.86, height: 1)
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: diameter * 0.86)
                    if settings.mode == .directions {
                        let dead = PadSteamPadZones.deadzone(settings)
                        Circle().stroke(Color.primary.opacity(0.3), lineWidth: 0.75).frame(width: diameter * dead, height: diameter * dead)
                        ForEach(Array(directions.enumerated()), id: \.offset) { n, input in
                            let reach = diameter * (0.5 - max(edge, 0.12) / 2 - 0.13)
                            Text(label(input).flatMap { $0 == "—" ? nil : $0 } ?? ["▲", "▼", "◀", "▶"][n])
                                .font(.system(size: max(7, diameter * 0.13), weight: .bold)).lineLimit(1).fixedSize()
                                .foregroundStyle(held.contains(input) ? Color.white : Color.accentColor)
                                .padding(.horizontal, 2)
                                .background(Capsule().fill(held.contains(input) ? Color.accentColor : .clear))
                                .rotationEffect(.degrees(-angle))          // text stays upright
                                .offset(x: n == 2 ? -reach : n == 3 ? reach : 0, y: n == 0 ? -reach : n == 1 ? reach : 0)
                        }
                    }
                }
                .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    private var dotNow = CGPoint(x: 0.5, y: 0.5), dotShown = 0.0
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
        f.onDisconnect = { [weak self] id in
            guard let self else { return }
            self.deviceHeld = self.deviceHeld.filter { !$0.hasPrefix(id + ".") }
            self.deviceAxes = self.deviceAxes.filter { !$0.key.hasPrefix(id + ".") }
        }
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
    private var primaryID: ObjectIdentifier?
    private let steamReaderID = UUID()
    private var steamSource = false
    private var steamPadSettings = [PadSteamTrackpadSettings(), PadSteamTrackpadSettings()]
    private var steamPadMotion = [PadSteamTrackpad(), PadSteamTrackpad()]
    private var steamZones = [PadSteamPadZones(), PadSteamPadZones()]
    func configureSteamPads(left: PadSteamTrackpadSettings?, right: PadSteamTrackpadSettings?) {
        let next = [left ?? PadSteamTrackpadSettings(), right ?? PadSteamTrackpadSettings()]
        if next != steamPadSettings { steamPadMotion = [PadSteamTrackpad(), PadSteamTrackpad()] }
        steamPadSettings = next
    }
    var isSteamSource: Bool { steamSource }
    @Published var leftSteamPad = CGPoint.zero
    func selectSource(_ source: PadProfiles.ControllerSource) {
        let next = source == .steamUSB
        guard next != steamSource else { return }
        if let e = engine { pe_release_main(e,Self.now()) }
        steamSource = next; lastButtons = [:]; lastAxes = [:]; pressed = []; sticks = [.zero,.zero]
        if engine != nil { attach() }
    }
    var family: Controllers.Family?

    func start(profile text: String, devices: [PadProfiles.Device] = []) {
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
            Task { @MainActor in guard let self, let e = self.engine else { return }; self.sample(); pe_tick(e, Self.now()) }
        }
    }
    func stop() {
        steamPadMotion = [PadSteamTrackpad(), PadSteamTrackpad()]
        SteamControllerUSB.shared.remove(steamReaderID)
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        feed.stop()
        if let e = engine { pe_destroy(e) }; engine = nil
        DesktopPad.shared.attach()
    }
    func reload(_ text: String, devices: [PadProfiles.Device]? = nil) {
        if (devices == nil || devices == self.devices), let e = engine, text.withCString({ pe_update_profile(e, $0) }) { return }
        if let e = engine { pe_release_all(e, Self.now()); pe_destroy(e) }
        held = [:]; holding = []; padAxes = [:]; steamZones = [PadSteamPadZones(), PadSteamPadZones()]
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
        sink.calibration = { c, p in MainActor.assumeIsolated { PadHUD.shared.calibration(p, manual: pe_calibration_is_manual(PadTester.of(c).engine)) } }
        engine = text.withCString { pe_create($0, sink) }
        lastButtons = [:]; lastAxes = [:]
        if steamSource { attach() }
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
            var d = dotNow
            d.x = (d.x + Double(x) / 1500).truncatingRemainder(dividingBy: 1); if d.x < 0 { d.x += 1 }
            d.y = (d.y + Double(y) / 1000).truncatingRemainder(dividingBy: 1); if d.y < 0 { d.y += 1 }
            dotNow = d
            // Movement arrives hundreds of times a second; the picture only needs it thirty.
            let now = Self.now()
            if now - dotShown >= 1.0 / 30 { dot = d; dotShown = now }
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
        feed.reconcile()
        if steamSource {
            controllerName = SteamControllerUSB.shared.controllerName; hasMotion = false
            SteamControllerUSB.shared.listen(steamReaderID) { [weak self] state in self?.readSteam(state) }
            return
        }
        SteamControllerUSB.shared.remove(steamReaderID)
        let c = feed.mainControllers().first
        let next = c.map(ObjectIdentifier.init)
        if primaryID != next {
            if primaryID != nil, let e = engine { pe_release_main(e, Self.now()) }
            lastButtons = [:]; lastAxes = [:]; pressed = []; sticks = [.zero, .zero]
            primaryID = next
        }
        controllerName = c?.vendorName
        hasMotion = c?.motion?.hasRotationRate ?? false
        if let m = c?.motion, m.sensorsRequireManualActivation { m.sensorsActive = true }
    }

    /// Preview samples state without replacing the active runtime's callbacks. Its
    /// telemetry rate is independent of the hardware-driven mapping pipeline.
    private func sample() {
        feed.sampleGamepads()
        if steamSource {
            for side in 0..<2 { steamMouse(steamPadMotion[side].tick(at: Self.now(), settings: steamPadSettings[side]), side: side) }
        }
        guard !steamSource else { return }
        guard let c = feed.mainControllers().first, let g = c.extendedGamepad else { return }
        guard primaryID == ObjectIdentifier(c) else { attach(); return }
        read(g)
        if let m = c.motion, let e = engine {
            let r = m.rotationRate, t = Self.now()
            pe_gyro(e, Float(r.x), Float(r.y), Float(r.z), t)
            let a = m.hasGravityAndUserAcceleration ? m.gravity : m.acceleration
            if pe_uses_tilt(e) { pe_accel(e, Float(a.x), Float(a.y), Float(a.z), t) }
            if t - lastGyroShown > 0.1 {
                let speed = (sqrt(r.x * r.x + r.y * r.y + r.z * r.z) * 180 / .pi).rounded()
                if speed != gyroSpeed { gyroSpeed = speed }
                lastGyroShown = t
            }
        }
        let pads = c.physicalInputProfile.allElements.compactMap { $0 as? GCControllerTouchpad }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for (i, tp) in pads.prefix(2).enumerated() {
            if let e = engine { pe_touch(e, Int32(i), tp.touchState != .up,
                (tp.touchSurface.xAxis.value + 1) / 2, (1 - tp.touchSurface.yAxis.value) / 2, Self.now()) }
        }
    }

    private func readSteam(_ state: SteamControllerReport.State?) {
        guard steamSource, let e = engine else { return }
        let name = SteamControllerUSB.shared.controllerName
        if controllerName != name { controllerName = name }       // setting it at all redraws the editor
        // Once this controller has shown it has a gyro, the Gyro row stays: a resting gyro reads exactly zero
        // now and then, and a row that came and went with it made the pane's height (and scroll bar) flicker.
        if state == nil { if hasMotion { hasMotion = false } }
        else if !hasMotion, state?.gyro.contains(where: { $0 != 0 }) == true { hasMotion = true }
        guard let state else {
            steamPadMotion = [PadSteamTrackpad(), PadSteamTrackpad()]
            steamZones = [PadSteamPadZones(), PadSteamPadZones()]
            pe_release_main(e,Self.now()); lastButtons = [:]; lastAxes = [:]
            pressed = []; sticks = [.zero,.zero]; leftSteamPad = .zero; return
        }
        let now = Self.now()
        if !DesktopPad.shared.suppliesSteamHaptics {
            for side in 0..<2 {
                SteamControllerUSB.shared.touchFeedback(side: side, down: side == 0 ? state.leftTouch : state.rightTouch, strength: steamPadSettings[side].touchFeedback ?? 0)
            }
        }
        let touchRequired = steamPadSettings.contains { $0.gyroWhileTouched == true }
        let gyroTouch = (steamPadSettings[0].gyroWhileTouched == true && state.leftTouch) || (steamPadSettings[1].gyroWhileTouched == true && state.rightTouch)
        pe_gyro_touch(e, touchRequired, gyroTouch)
        pe_touch(e,0,state.leftTouch && steamPadSettings[0].mode == .existing,(state.leftPad.x+1)/2,(1-state.leftPad.y)/2,now)
        for side in 0..<2 where steamPadSettings[side].mode != .existing {
            let pad = side == 0 ? state.leftPad : state.rightPad
            steamMouse(steamPadMotion[side].touch(down: side == 0 ? state.leftTouch : state.rightTouch,
                x: Double(pad.x+1)/2, y: Double(1-pad.y)/2, at: now, settings: steamPadSettings[side]), side: side)
        }
        var zones: Set<PadProfiles.Input> = []
        for side in 0..<2 {
            let pad = side == 0 ? state.leftPad : state.rightPad, before = steamZones[side].held
            let after = steamZones[side].update(side: side, down: side == 0 ? state.leftTouch : state.rightTouch, x: Double(pad.x), y: Double(pad.y), settings: steamPadSettings[side])
            for input in before.symmetricDifference(after) { pe_pad_zone(e, pe_input_named(input.rawValue), after.contains(input), now) }
            zones.formUnion(after)
        }
        for input in PadProfiles.Input.padButtons {
            let n = Int(pe_input_named(input.rawValue)), down = state.buttons.contains(input)
            if lastButtons[n] != down { lastButtons[n] = down; pe_button(e,Int32(n),down,now) }
        }
        let axes = state.mappingAxes(rightTrackpadAsStick: steamPadSettings[1].mode == .existing)
        for (a,v) in axes where lastAxes[a] != v { lastAxes[a] = v; pe_axis(e,Int32(a),Int32(v),now) }
        pe_gyro(e,state.gyro[0],state.gyro[1],state.gyro[2],now)
        if pe_uses_tilt(e) { pe_accel(e,state.acceleration[0],state.acceleration[1],state.acceleration[2],now) }
        var held = state.buttons.union(zones)
        if state.leftTrigger > 0.3 { held.insert(.lt) }; if state.leftTrigger > 0.95 { held.insert(.ltfull) }
        if state.rightTrigger > 0.3 { held.insert(.rt) }; if state.rightTrigger > 0.95 { held.insert(.rtfull) }
        if pressed != held { pressed = held }
        func point(_ p: SteamControllerReport.Point) -> CGPoint { CGPoint(x:(Double(p.x)*20).rounded()/20,y:(Double(p.y)*20).rounded()/20) }
        let positions = [point(state.stick),state.rightTouch ? point(state.rightPad) : .zero]
        if positions != sticks { sticks = positions }
        let left = state.leftTouch ? point(state.leftPad) : .zero
        if leftSteamPad != left { leftSteamPad = left }
        if now-lastGyroShown > 0.1 {
            let speed = Double(sqrt(state.gyro.reduce(0) { $0+$1*$1 })*180/Float.pi).rounded()
            if speed != gyroSpeed { gyroSpeed = speed }; lastGyroShown = now
        }
    }

    private func steamMouse(_ motion: PadSteamTrackpad.Motion, side: Int) {
        guard motion.x != 0 || motion.y != 0, let engine else { return }
        if !DesktopPad.shared.suppliesSteamHaptics { _ = SteamControllerUSB.shared.movementFeedback(side: side, dx: motion.x, dy: motion.y, strength: steamPadSettings[side].movementFeedback ?? 0, rate: steamPadSettings[side].hapticRate ?? 40, spacingMS: steamPadSettings[side].hapticSpacingMS ?? 1, followsMovement: steamPadSettings[side].hapticFollowsMovement ?? true) }
        if !pe_menu_mouse(engine, Double(motion.x), Double(motion.y)) { move(motion.x,motion.y) }
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
    @ObservedObject private var steam = SteamControllerUSB.shared

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let n = tester.controllerName {
                        Text("Testing with \(n)").font(.caption).foregroundStyle(.secondary)
                        if tester.isSteamSource { Text(steam.status).font(.caption).foregroundStyle(.secondary) }
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
