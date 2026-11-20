import AppKit
import SceneKit
import SwiftUI
import simd
import NokcanduCore
import GameController

/// The 3D controller overlay (Controllers → Settings → Controller overlay): over everything, or in a window of its
/// own for window capture in OBS. It reads the controller the same way the remapper does and changes nothing about
/// it. Drawn only when something visible changed, at most 60 times a second; nothing at all while the controller
/// rests.
@MainActor
final class ControllerOverlay: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ControllerOverlay()

    @Published var settings = ControllerOverlaySettings.load() {
        didSet {
            var s = settings; s.clamp()
            if s != settings { settings = s; return }
            guard settings != oldValue else { return }
            settings.save()
            apply(from: oldValue)
        }
    }
    /// The on-screen overlay takes the pointer so it can be dragged into place.
    @Published var arranging = false { didSet { if arranging != oldValue { applyArranging() } } }
    /// The controller being shown, by name ("" when none is connected).
    @Published private(set) var showing = ""

    /// Every controller it can read, by source: what it's doing, and which drawing it gets.
    private struct Source { var input = ControllerOverlayInput(); var kind: ControllerOverlaySettings.Model; var name: String; var flipGravity: Bool? }
    private var sources: [String: Source] = [:]
    private var active: String?
    private let steamID = UUID()
    private var mappedToken: UUID?, motionToken: UUID?
    private var listening = false
    private var gcTimer: Timer?
    private var gcObservers: [NSObjectProtocol] = []
    private var motion = ControllerOverlayMotion()
    private var shownInput: ControllerOverlayInput?
    private var shownOrientation: simd_quatf?
    private var drawPending = false, lastDraw = 0.0
    /// When Back and Start started being held together (recentring after a second).
    private var comboSince: Double?, comboDone = false
    private var panel: NSPanel?, window: NSWindow?
    private var host: OverlayHostView?
    private var model: OverlayControllerModel?
    private var modelKind: ControllerOverlaySettings.Model?

    /// At launch (and when controllers are turned on in Nokcandu's features).
    func start() { apply(from: nil) }

    func recenter() { motion.recenter(); scheduleDraw() }

    /// The drawing: the one chosen, or the controller in use (the 2015 Steam Controller until one is used).
    private var wantedKind: ControllerOverlaySettings.Model {
        if settings.model != .automatic { return settings.model }
        return active.flatMap { sources[$0]?.kind } ?? sources.values.first?.kind ?? .steam2015
    }
    private var aspect: Double { model?.aspect ?? OverlayLayout.make(wantedKind).aspect }

    private func apply(from old: ControllerOverlaySettings?) {
        guard settings.mode != .off, AppFeatures.current.contains(.profiles) else { tearDown(); return }
        let host = self.host ?? makeHost()
        useModel(wantedKind)
        host.background = settings.background == .color ? Self.color(settings.backgroundColor) : nil
        host.alphaValue = settings.opacity
        if old?.mode != settings.mode || (panel == nil && window == nil) {
            panel?.orderOut(nil); panel?.contentView = nil; panel = nil
            if let w = window { w.delegate = nil; w.contentView = nil; w.orderOut(nil) }; window = nil
            if settings.mode == .onScreen { showPanel(host) } else { showWindow(host) }
        } else {
            resize()
        }
        if settings.mode != .onScreen { arranging = false }
        listen()
        drawNow()
    }

    private var size: CGSize { CGSize(width: settings.size.rounded(), height: (settings.size * aspect).rounded()) }

    private func resize() {
        if let panel { placePanel(panel) }
        else if let window {
            window.contentAspectRatio = NSSize(width: 1, height: aspect)
            if abs(window.contentLayoutRect.width - size.width) > 1 || abs(window.contentLayoutRect.height - size.height) > 1 { window.setContentSize(size) }
        }
    }

    /// Builds the drawing for a controller when it changes (another controller picked up, or chosen).
    private func useModel(_ kind: ControllerOverlaySettings.Model) {
        guard let host else { return }
        if kind != modelKind {
            model?.root.removeFromParentNode()
            let m = OverlayControllerModel(OverlayLayout.make(kind))
            host.scene.rootNode.addChildNode(m.root)
            model = m; modelKind = kind
            shownInput = nil; shownOrientation = nil
            resize()
        }
        model?.colors(body: Self.color(settings.bodyColor), buttons: Self.color(settings.buttonColor), highlight: Self.color(settings.highlightColor))
        shownInput = nil
    }

    private func tearDown() {
        arranging = false
        if listening {
            SteamControllerUSB.shared.remove(steamID)
            MappedGamepads.shared.stopListening(mappedToken); MappedGamepads.shared.stopListeningMotion(motionToken)
            mappedToken = nil; motionToken = nil
            gcTimer?.invalidate(); gcTimer = nil
            gcObservers.forEach(NotificationCenter.default.removeObserver); gcObservers = []
            listening = false
        }
        panel?.orderOut(nil); panel = nil
        if let w = window { w.delegate = nil; w.orderOut(nil) }; window = nil
        host = nil; model = nil; modelKind = nil; shownInput = nil; shownOrientation = nil
        sources = [:]; active = nil; showing = ""
        motion.reset()
    }

    private func makeHost() -> OverlayHostView {
        let h = OverlayHostView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        h.onDragEnd = { [weak self] in self?.savePanelPosition() }
        h.onDone = { [weak self] in self?.arranging = false }
        host = h
        return h
    }

    // MARK: Over everything

    private func showPanel(_ host: OverlayHostView) {
        let p = padOverlayPanel()
        p.contentView = host
        panel = p
        placePanel(p)
        p.orderFrontRegardless()
        applyArranging()
    }

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.localizedName == settings.screen } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func placePanel(_ p: NSPanel) {
        guard let s = targetScreen else { return }
        let f = s.frame, size = self.size
        var origin = CGPoint(x: f.minX + f.width * settings.positionX - size.width / 2, y: f.minY + f.height * settings.positionY - size.height / 2)
        origin.x = min(max(origin.x, f.minX), f.maxX - size.width); origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func savePanelPosition() {
        guard let p = panel, let s = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: p.frame.midX, y: p.frame.midY)) }) ?? p.screen else { return }
        var next = settings
        next.positionX = (p.frame.midX - s.frame.minX) / s.frame.width
        next.positionY = (p.frame.midY - s.frame.minY) / s.frame.height
        next.screen = s.localizedName
        settings = next
    }

    private func applyArranging() {
        panel?.ignoresMouseEvents = !arranging
        host?.arranging = arranging && panel != nil
    }

    // MARK: A window of its own

    private func showWindow(_ host: OverlayHostView) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Controller Overlay"
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.contentAspectRatio = NSSize(width: 1, height: aspect)
        w.contentMinSize = NSSize(width: ControllerOverlaySettings.sizes.lowerBound, height: ControllerOverlaySettings.sizes.lowerBound * 0.6)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.setFrameAutosaveName("NokcanduControllerOverlay")
        w.setContentSize(size)
        w.delegate = self
        w.orderFront(nil)
        window = w
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let w = window else { return }
        settings.size = w.contentLayoutRect.width.rounded()
    }
    func windowWillClose(_ notification: Notification) {
        // Closing the window turns the overlay off, as the settings show.
        window?.delegate = nil; window = nil
        settings.mode = .off
    }

    // MARK: Input

    /// Reads every controller the remapper does, the same way, changing nothing about them: Steam Controllers from
    /// Nokcandu's own reader, controllers it reads with its drivers or community mappings, and the ones macOS knows
    /// (Xbox, PlayStation, Switch Pro) by looking at their state 60 times a second while one is connected.
    private func listen() {
        guard !listening else { return }
        listening = true
        SteamControllerUSB.shared.listen(steamID) { [weak self] state in self?.readSteam(state) }
        mappedToken = MappedGamepads.shared.listen { [weak self] source, buttons, axes in
            MainActor.assumeIsolated { self?.readMapped(source, buttons, axes) }
        }
        motionToken = MappedGamepads.shared.listenMotion { [weak self] source, gyro, accel in
            MainActor.assumeIsolated { guard let self, source == self.active else { return }; self.move(gyro, accel) }
        }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            gcObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchGameControllers() }
            })
        }
        watchGameControllers()
    }

    private func readSteam(_ state: SteamControllerReport.State?) {
        guard let state else { gone("steam"); return }
        let kind: ControllerOverlaySettings.Model = state.kind == .steam2026 ? .steam2026 : .steam2015
        update("steam", ControllerOverlayInput(state), kind: kind, name: kind.title)
        if active == "steam" { move(state.gyro, state.acceleration) }
    }

    private func readMapped(_ source: String, _ buttons: Set<PadProfiles.Input>?, _ axes: [Int: Int]) {
        guard let buttons else { gone(source); return }
        let name = MappedGamepads.shared.native[source]?.name
            ?? source.split(separator: ":").last.flatMap { UInt64($0) }.flatMap { MappedGamepads.shared.pads[$0]?.info.name }
            ?? (source.hasPrefix("xinput") ? "Xbox" : "Controller")
        update(source, ControllerOverlayInput(buttons: buttons, axes: axes), kind: .forName(source.hasPrefix("switch2") ? "switch" : name), name: name)
    }

    private func watchGameControllers() {
        let pads = gameControllers
        for key in sources.keys where key.hasPrefix("gc:") && !pads.contains(where: { "gc:\(ObjectIdentifier($0).hashValue)" == key }) { gone(key) }
        if pads.isEmpty { gcTimer?.invalidate(); gcTimer = nil; return }
        guard gcTimer == nil else { return }
        gcTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollGameControllers() }
        }
    }

    /// Controllers macOS knows, less the Steam Controllers (read directly).
    private var gameControllers: [GCController] {
        GCController.controllers().filter { $0.extendedGamepad != nil && !$0.productCategory.lowercased().contains("steam") && !($0.vendorName ?? "").lowercased().contains("steam") }
    }

    private func pollGameControllers() {
        for c in gameControllers {
            guard let g = c.extendedGamepad else { continue }
            let key = "gc:\(ObjectIdentifier(c).hashValue)", name = c.vendorName ?? c.productCategory
            let state = PadGC.state(g)
            var i = ControllerOverlayInput(buttons: Set(state.buttons.filter(\.1).map(\.0)), axes: [:])
            func v(_ n: Int32) -> Float { state.axes.first { $0.0 == n }?.1 ?? 0 }
            i.leftStick = [v(0), -v(1)]; i.rightStick = [v(2), -v(3)]
            i.leftTrigger = v(4); i.rightTrigger = v(5)
            // The first touchpad (DualShock 4, DualSense): the overlay's left pad.
            if let tp = c.physicalInputProfile.allElements.compactMap({ $0 as? GCControllerTouchpad }).first {
                i.leftTouch = tp.touchState != .up
                i.leftPad = [tp.touchSurface.xAxis.value, tp.touchSurface.yAxis.value]
            }
            update(key, i, kind: .forName(c.productCategory + " " + name), name: name)
            if active == key, settings.gyro, let m = c.motion {
                if m.sensorsRequireManualActivation && !m.sensorsActive { m.sensorsActive = true }
                let r = m.rotationRate, a = m.hasGravityAndUserAcceleration ? m.gravity : m.acceleration
                move([Float(r.x), Float(r.y), Float(r.z)], [Float(a.x), Float(a.y), Float(a.z)], source: key)
            }
        }
    }

    /// A controller's latest state. One that's being used (a button, a stick or trigger pushed well, a pad
    /// touched) becomes the one shown.
    private func update(_ key: String, _ input: ControllerOverlayInput, kind: ControllerOverlaySettings.Model, name: String) {
        var s = sources[key] ?? Source(kind: kind, name: name)
        let changed = !s.input.looksLike(input)
        s.input = input; s.kind = kind; s.name = name
        sources[key] = s
        let used = !input.buttons.isEmpty || input.leftTouch || input.rightTouch || simd_length(input.leftStick) > 0.35
            || simd_length(input.rightStick) > 0.35 || input.leftTrigger > 0.3 || input.rightTrigger > 0.3
        if active == nil || (used && active != key) {
            active = key; motion.reset()
            if showing != name { showing = name }
            if settings.model == .automatic { useModel(kind) }
            shownInput = nil; scheduleDraw()
        }
        if active == key { watchRecenterCombo(input) }
        if changed && active == key { scheduleDraw() }
    }

    /// Back and Start held together for a second: the way the controller is held becomes the rest position.
    private func watchRecenterCombo(_ input: ControllerOverlayInput) {
        guard input.buttons.isSuperset(of: [.back, .start]) else { comboSince = nil; comboDone = false; return }
        let now = ProcessInfo.processInfo.systemUptime
        if comboSince == nil { comboSince = now }
        guard !comboDone, let since = comboSince else { return }
        if now - since >= ControllerOverlaySettings.recenterHold { comboDone = true; recenter(); return }
        // Reports stop while nothing changes: look again when the second is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + ControllerOverlaySettings.recenterHold - (now - since) + 0.01) { [weak self] in
            guard let self, let key = self.active, let i = self.sources[key]?.input else { return }
            self.watchRecenterCombo(i)
        }
    }

    private func gone(_ key: String) {
        guard sources.removeValue(forKey: key) != nil else { return }
        if active == key {
            active = sources.keys.sorted().first; motion.reset()
            showing = active.flatMap { sources[$0]?.name } ?? ""
            if settings.model == .automatic { useModel(wantedKind) }
            shownInput = nil; scheduleDraw()
        }
    }

    /// Motion from the controller shown. Gravity's sign differs between sources: up, out of the face, should read
    /// positive while it's held, so a source reading it negative at first is turned round.
    private func move(_ gyro: [Float], _ accel: [Float], source: String? = nil) {
        guard settings.gyro, gyro.count == 3, accel.count == 3 else { return }
        var a = accel
        if let key = source ?? active, var s = sources[key] {
            if s.flipGravity == nil, abs(simd_length(SIMD3(a[0], a[1], a[2])) - 1) < 0.2 { s.flipGravity = a[1] < 0; sources[key] = s }
            if s.flipGravity == true { a = a.map { -$0 } }
        }
        motion.update(gyro: gyro, acceleration: a, at: ProcessInfo.processInfo.systemUptime)
        scheduleDraw()
    }

    private func scheduleDraw() {
        guard !drawPending else { return }
        let wait = max(0, 1.0 / 60 - (ProcessInfo.processInfo.systemUptime - lastDraw))
        drawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.drawPending = false
            self.draw()
        }
    }

    private func drawNow() { shownInput = nil; shownOrientation = nil; draw() }

    private func draw() {
        guard let model else { return }
        let input = active.flatMap { sources[$0]?.input } ?? ControllerOverlayInput()
        let q = settings.gyro ? motion.orientation(strength: Float(settings.gyroStrength)) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let inputChanged = shownInput.map { !$0.looksLike(input) } ?? true
        // A fifth of a degree: smaller turns can't be seen at overlay sizes.
        let turned = shownOrientation.map { 2 * acos(min(1, abs(simd_dot($0.vector, q.vector)))) > 0.0035 } ?? true
        guard inputChanged || turned else { return }
        lastDraw = ProcessInfo.processInfo.systemUptime
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        if inputChanged { model.show(input); shownInput = input }
        let hidden = settings.hideWithoutController && sources.isEmpty
        if model.root.isHidden != hidden { model.root.isHidden = hidden }
        if turned { model.root.simdOrientation = q; shownOrientation = q }
        SCNTransaction.commit()
    }

    static func color(_ hex: String) -> NSColor {
        guard let c = ControllerOverlaySettings.rgb(hex) else { return .gray }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

// MARK: - The view

/// The scene, its camera and lights, and (while arranging) a frame to drag it by.
final class OverlayHostView: NSView {
    let scene = SCNScene()
    private let sceneView: SCNView
    private let arrangeView = OverlayArrangeView()
    var onDragEnd: (() -> Void)?
    var onDone: (() -> Void)? { didSet { arrangeView.onDone = onDone } }
    var arranging = false { didSet { arrangeView.isHidden = !arranging } }
    var background: NSColor? {
        didSet {
            sceneView.backgroundColor = background ?? .clear
            layer?.backgroundColor = (background ?? .clear).cgColor
        }
    }

    override init(frame: NSRect) {
        sceneView = SCNView(frame: frame, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        sceneView.scene = scene
        sceneView.backgroundColor = .clear
        sceneView.allowsCameraControl = false
        sceneView.rendersContinuously = false
        sceneView.isPlaying = false
        sceneView.preferredFramesPerSecond = 60
        sceneView.antialiasingMode = .multisampling4X
        sceneView.autoresizingMask = [.width, .height]
        sceneView.frame = bounds
        addSubview(sceneView)
        arrangeView.frame = bounds
        arrangeView.autoresizingMask = [.width, .height]
        arrangeView.isHidden = true
        arrangeView.onDragEnd = { [weak self] in self?.onDragEnd?() }
        addSubview(arrangeView)

        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 25
        camera.camera?.zNear = 0.1; camera.camera?.zFar = 50
        // In front of the player and above, looking down at the controller as it's held.
        camera.simdPosition = SIMD3(0, 7.4, 5.4)
        camera.simdLook(at: SIMD3(0, -0.1, 0.05))
        scene.rootNode.addChildNode(camera)
        sceneView.pointOfView = camera

        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.62, alpha: 1)
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional
        key.light?.color = NSColor(white: 1.0, alpha: 1)
        key.simdPosition = SIMD3(-2, 6, 4); key.simdLook(at: .zero)
        scene.rootNode.addChildNode(key)
        let rim = SCNNode(); rim.light = SCNLight(); rim.light?.type = .directional
        rim.light?.color = NSColor(white: 0.5, alpha: 1)
        rim.simdPosition = SIMD3(3, 2, -5); rim.simdLook(at: .zero)
        scene.rootNode.addChildNode(rim)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// While arranging: a dashed frame that moves the overlay when dragged, and Done.
final class OverlayArrangeView: NSView {
    var onDragEnd: (() -> Void)?
    var onDone: (() -> Void)?
    private var start: (mouse: CGPoint, origin: CGPoint)?
    private lazy var done: NSButton = {
        let b = NSButton(title: "Done", target: self, action: #selector(finish))
        b.bezelStyle = .rounded; b.controlSize = .small
        addSubview(b)
        return b
    }()

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        path.lineWidth = 2; path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.setStroke(); path.stroke()
        let text = "Drag to move" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 8), withAttributes: attrs)
    }
    override func layout() {
        super.layout()
        done.sizeToFit()
        done.frame.origin = CGPoint(x: (bounds.width - done.frame.width) / 2, y: 8)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        start = (NSEvent.mouseLocation, w.frame.origin)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let start, let w = window else { return }
        let now = NSEvent.mouseLocation
        w.setFrameOrigin(CGPoint(x: start.origin.x + now.x - start.mouse.x, y: start.origin.y + now.y - start.mouse.y))
    }
    override func mouseUp(with e: NSEvent) {
        if start != nil { onDragEnd?() }
        start = nil
    }
    @objc private func finish() { onDone?() }
}

// MARK: - Settings

/// Controllers → Settings → Controller overlay. Every change shows at once.
struct ControllerOverlaySettingsView: View {
    @ObservedObject private var overlay = ControllerOverlay.shared

    var body: some View {
        Section("Controller overlay") {
            Picker("Show", selection: $overlay.settings.mode) {
                ForEach(ControllerOverlaySettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("A 3D controller showing your buttons, sticks, triggers and trackpads as you use them, turning with the gyro. Over games and streams, it sits on top of everything and never takes clicks. In its own window, add it to OBS as a macOS Screen Capture source set to Window, and use a background colour with a Chroma Key filter. Anything drawn over a full-screen stream can add a millisecond or two of latency.")
                .font(.caption).foregroundStyle(.secondary)
            if overlay.settings.mode != .off {
                Picker("Controller", selection: $overlay.settings.model) {
                    ForEach(ControllerOverlaySettings.Model.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(overlay.showing.isEmpty ? "No controller connected." : "Showing: \(overlay.showing)").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $overlay.settings.size, in: ControllerOverlaySettings.sizes, step: 10).frame(width: 180)
                        Text(verbatim: "\(Int(overlay.settings.size)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $overlay.settings.opacity, in: 0.1...1, step: 0.05).frame(width: 180)
                        Text(verbatim: "\(Int((overlay.settings.opacity * 100).rounded()))%").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                ColorPicker("Body", selection: color(\.bodyColor), supportsOpacity: false)
                ColorPicker("Buttons", selection: color(\.buttonColor), supportsOpacity: false)
                ColorPicker("Pressed", selection: color(\.highlightColor), supportsOpacity: false)
                Picker("Background", selection: $overlay.settings.background) {
                    ForEach(ControllerOverlaySettings.Background.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if overlay.settings.background == .color { ColorPicker("Background colour", selection: color(\.backgroundColor), supportsOpacity: false) }
                Toggle("Hide when no controller is connected", isOn: $overlay.settings.hideWithoutController)
                Toggle("Turn with the gyro", isOn: $overlay.settings.gyro)
                if overlay.settings.gyro {
                    LabeledContent("Movement shown") {
                        HStack {
                            Slider(value: $overlay.settings.gyroStrength, in: 0...1.5, step: 0.05).frame(width: 180)
                            Text(verbatim: "\(Int((overlay.settings.gyroStrength * 100).rounded()))%").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    HStack {
                        Button("Recentre") { overlay.recenter() }
                        Text("Or hold Back and Start together for a second (View and Menu, Share and Options, − and +). The way you hold the controller then becomes its rest position. Turning drifts back to the front by itself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if overlay.settings.mode == .onScreen {
                    HStack {
                        Button(overlay.arranging ? "Done Moving" : "Move Overlay…") { overlay.arranging.toggle() }
                        Text(overlay.arranging ? "Drag the overlay where you want it, on any screen." : "Drag it anywhere on the screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(_ key: WritableKeyPath<ControllerOverlaySettings, String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: ControllerOverlay.color(overlay.settings[keyPath: key])) }, set: { c in
            guard let rgb = NSColor(c).usingColorSpace(.sRGB) else { return }
            overlay.settings[keyPath: key] = ControllerOverlaySettings.hex(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)
        })
    }
}
