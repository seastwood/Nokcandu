import AppKit
import SceneKit
import SwiftUI
import simd
import NokcanduCore
import GameController
import Metal
import Combine
import os

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
    @Published var arranging = false { didSet { if arranging != oldValue { applyArranging(); scheduleDraw() } } }
    /// Settings views showing the overlay's settings: it's shown even without a controller while any is open.
    var previewing = 0 { didSet { scheduleDraw() } }
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
    /// Over a full-screen stream, the overlay is drawn into the stream's own frames instead of the panel.
    private var inStream: StreamMetalRenderer?
    private var streamDrawer: StreamOverlayDrawer?
    private var streamCheck: Timer?
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
        host.view(from: settings.viewAngle)
        if old?.mode != settings.mode || (panel == nil && window == nil) {
            panel?.orderOut(nil); panel?.contentView = nil; panel = nil
            if let w = window { w.delegate = nil; w.contentView = nil; w.orderOut(nil) }; window = nil
            if settings.mode == .onScreen { showPanel(host) } else { showWindow(host) }
        } else {
            resize()
        }
        HeadMotionOverlay.shared.configure(settings, overlayOn: settings.mode == .onScreen, screen: targetScreen, highlight: Self.color(settings.highlightColor))
        watchStreams()
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
        streamCheck?.invalidate(); streamCheck = nil; leaveStream()
        HeadMotionOverlay.shared.tearDown()
        panel?.orderOut(nil); panel = nil
        if let w = window { w.delegate = nil; w.orderOut(nil) }; window = nil
        host = nil; model = nil; modelKind = nil; shownInput = nil; shownOrientation = nil
        wheelNode = nil; shownWheel = nil; shownLabels = nil
        zoomTimer?.invalidate(); zoomTimer = nil; zoom = 0; zoomTarget = 0; zoomHeld = false
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
        p.setFrame(zoomed(NSRect(origin: origin, size: size), in: f), display: true)
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
        // Arranging needs the panel to drag; the stream drawing comes back afterwards.
        if arranging { leaveStream() } else if settings.mode == .onScreen { updateStream() }
        panel?.ignoresMouseEvents = !arranging
        host?.arranging = arranging && panel != nil
        HeadMotionOverlay.shared.arrange(arranging && panel != nil)
    }

    // MARK: Inside a full-screen stream

    /// Twice a second while the overlay is over everything: is a stream showing full screen on the overlay's screen?
    private func watchStreams() {
        guard settings.mode == .onScreen else { streamCheck?.invalidate(); streamCheck = nil; leaveStream(); return }
        updateStream()
        guard streamCheck == nil else { return }
        streamCheck = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStream() }
        }
    }

    private func updateStream() {
        guard let host, let screen = targetScreen, !arranging,
              let stream = DesktopPad.shared.stream as? StreamWindowController, let w = stream.window, w.isVisible, w.screen == screen,
              w.styleMask.contains(.fullScreen) || w.frame.equalTo(screen.frame),
              let renderer = stream.connection.video.metalRenderer else { leaveStream(); return }
        // Where the panel would be, in points from the screen's top left (the drawable covers the screen).
        let f = screen.frame, size = self.size
        var origin = CGPoint(x: f.width * settings.positionX - size.width / 2, y: f.height * settings.positionY - size.height / 2)
        origin.x = min(max(origin.x, 0), f.width - size.width); origin.y = min(max(origin.y, 0), f.height - size.height)
        let normal = CGRect(x: origin.x, y: f.height - origin.y - size.height, width: size.width, height: size.height)
        let rect = zoomed(normal, in: CGRect(origin: .zero, size: f.size))
        // While it's big or moving, it's rendered once at the big size and only drawn smaller or larger.
        let render = zoom > 0 ? bigSize(in: f.size) : size
        if inStream !== renderer {
            leaveStream()
            let d = StreamOverlayDrawer(device: renderer.metalDevice, scene: host.scene, camera: host.camera)
            let head = HeadMotionOverlay.shared.streamImage
            head.use(renderer.metalDevice)
            renderer.setOverlay { enc, target in d.draw(enc, target); head.draw(enc, target) }
            HeadMotionOverlay.shared.streaming(true)
            inStream = renderer; streamDrawer = d
            panel?.orderOut(nil)
            host.viewPaused = true
            StreamLog.shared.add("Controller overlay: drawn into the stream's frames")
        }

        streamDrawer?.place(rect, render: render, screenWidth: f.width, scale: screen.backingScaleFactor, opacity: settings.opacity)
        HeadMotionOverlay.shared.streamImage.place(HeadMotionOverlay.shared.streamRect(screenFrame: f), screenWidth: f.width, opacity: settings.opacity)
    }

    private func leaveStream() {
        guard let r = inStream else { return }
        r.setOverlay(nil); inStream = nil; streamDrawer = nil
        HeadMotionOverlay.shared.streaming(false)
        host?.viewPaused = false
        if settings.mode == .onScreen, let panel { panel.orderFrontRegardless() }
        StreamLog.shared.add("Controller overlay: over the screen again (a window above the stream)")
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
        watchMappings()
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
        if active == "steam" { move(state.sdlGyro, state.sdlAcceleration) }
    }

    private func readMapped(_ source: String, _ buttons: Set<PadProfiles.Input>?, _ axes: [Int: Int]) {
        guard let buttons else { gone(source); return }
        let name = MappedGamepads.shared.native[source]?.name
            ?? source.split(separator: ":").last.flatMap { UInt64($0) }.flatMap { MappedGamepads.shared.pads[$0]?.info.name }
            ?? (source.hasPrefix("xinput") ? "Xbox" : "Controller")
        update(source, ControllerOverlayInput(buttons: buttons, axes: axes), kind: .forName(source.hasPrefix("switch2") ? "switch" : name), name: name)
    }

    /// The controllers macOS knows (less Steam Controllers) with their key and name, worked out when one connects or
    /// disconnects: reading a controller's category or vendor costs more than reading its buttons, 60 times a second.
    private var gcPads: [(controller: GCController, key: String, name: String, kind: ControllerOverlaySettings.Model, touchpad: GCControllerTouchpad?)] = []

    private func watchGameControllers() {
        let pads = gameControllers
        gcPads = pads.map { c in
            let name = c.vendorName ?? c.productCategory
            return (c, "gc:\(ObjectIdentifier(c).hashValue)", name, .forName(c.productCategory + " " + name),
                    c.physicalInputProfile.allElements.compactMap { $0 as? GCControllerTouchpad }.first)
        }
        for key in sources.keys where key.hasPrefix("gc:") && !gcPads.contains(where: { $0.key == key }) { gone(key) }
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
        for (c, key, name, kind, touchpad) in gcPads {
            guard let g = c.extendedGamepad else { continue }
            let state = PadGC.state(g)
            var i = ControllerOverlayInput(buttons: Set(state.buttons.filter(\.1).map(\.0)), axes: [:])
            func v(_ n: Int32) -> Float { state.axes.first { $0.0 == n }?.1 ?? 0 }
            i.leftStick = [v(0), -v(1)]; i.rightStick = [v(2), -v(3)]
            i.leftTrigger = v(4); i.rightTrigger = v(5)
            // The first touchpad (DualShock 4, DualSense): the overlay's left pad.
            if let tp = touchpad {
                i.leftTouch = tp.touchState != .up
                i.leftPad = [tp.touchSurface.xAxis.value, tp.touchSurface.yAxis.value]
            }
            update(key, i, kind: kind, name: name)
            if active == key, settings.gyro, let m = c.motion {
                if m.sensorsRequireManualActivation && !m.sensorsActive { m.sensorsActive = true }
                let r = m.rotationRate, a = m.hasGravityAndUserAcceleration ? m.gravity : m.acceleration
                move(GameControllerMotion.gyro(r.x, r.y, r.z), GameControllerMotion.acceleration(a.x, a.y, a.z), source: key)
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
        if active == nil || (used && active != key && mayShow(key)) {
            active = key; motion.reset()
            if showing != name { showing = name }
            if settings.model == .automatic { useModel(kind) }
            shownInput = nil; scheduleDraw()
        }
        if active == key { watchRecenterCombo(input) }
        if changed && active == key { scheduleDraw() }
    }

    /// With "Player 1's controller", another player's controller takes the overlay only while no controller here is
    /// player 1 (then it's the one used last, as with "The controller used last").
    private func mayShow(_ key: String) -> Bool {
        guard settings.follow == .playerOne else { return true }
        if isPlayerOne(key) { return true }
        return !sources.keys.contains { isPlayerOne($0) }
    }
    private func isPlayerOne(_ key: String) -> Bool {
        // The overlay names macOS's controllers by its own key; the Controllers panel by the profile's source name.
        let source = gcPads.first { $0.key == key }.map { String(describing: ObjectIdentifier($0.controller)) } ?? key
        return ControllerDevices.shared.player(forSource: source) == 1
    }

    /// Back and Start held together for a second: the way the controller is held becomes level and the front.
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
        // The steering bar follows the controller even when the drawing doesn't turn.
        if !settings.gyro, wheelNode?.isHidden == false { scheduleDraw() }
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

    // MARK: Steering bar

    /// Above the drawing while the gyro is a steering wheel: how far it's turned, the straight range, full lock.
    private var wheelNode: SCNNode?
    private var shownWheel: String?
    private func updateWheel(hidden: Bool) {
        let w = DesktopPad.shared.wheelState()
        let key = w.map { "\(($0.angle * 2).rounded())|\($0.lock)|\($0.dead)" }
        guard key != shownWheel || (wheelNode?.isHidden ?? true) != (w == nil || hidden) else { return }
        shownWheel = key
        guard let w, !hidden, let camera = host?.camera else { wheelNode?.isHidden = true; return }
        let node = wheelNode ?? {
            let plane = SCNPlane(width: 1.7, height: 0.17)
            let m = SCNMaterial(); m.lightingModel = .constant; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false; m.blendMode = .alpha
            plane.materials = [m]
            let n = SCNNode(geometry: plane)
            n.simdPosition = SIMD3(0, 0.74, -4)          // in front of the camera, near the top of the view
            n.renderingOrder = 30
            camera.addChildNode(n)
            wheelNode = n
            return n
        }()
        node.isHidden = false
        node.geometry?.firstMaterial?.diffuse.contents = WheelBarImage.draw(angle: w.angle, lock: w.lock, dead: w.dead, highlight: Self.color(settings.highlightColor))
    }

    // MARK: Mappings on the drawing

    private var shownLabels: OverlayMappings?
    private var mappingsHeld = false, mappingsOn = false
    private var mappingWatch: [AnyCancellable] = []
    private var mappingsShown: Bool {
        switch settings.mappings {
        case .off: false
        case .always: true
        case .whileHeld: mappingsHeld
        case .toggle: mappingsOn
        }
    }

    /// A button set to "Show mappings on the overlay" was pressed or let go.
    func mappingsButton(down: Bool) {
        switch settings.mappings {
        case .whileHeld: mappingsHeld = down
        case .toggle: if down { mappingsOn.toggle() }
        case .always: zoomHeld = down
        case .off: return
        }
        setZoom(settings.zoomWithMappings && (settings.mappings == .always ? zoomHeld : mappingsShown))
        scheduleDraw()
    }

    // MARK: Zooming in to read the mappings

    private var zoomHeld = false
    /// 0 at its place … 1 big in the middle; eased while it moves.
    private var zoom = 0.0, zoomTarget = 0.0
    private var zoomTimer: Timer?, zoomLast = 0.0
    static let zoomTime = 0.24

    private func setZoom(_ on: Bool) {
        zoomTarget = on ? 1 : 0
        guard zoom != zoomTarget, zoomTimer == nil else { return }
        zoomLast = CACurrentMediaTime()
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.zoomStep() }
        }
    }

    private func zoomStep() {
        let now = CACurrentMediaTime(), dt = now - zoomLast; zoomLast = now
        let step = dt / Self.zoomTime
        zoom = zoomTarget > zoom ? min(zoomTarget, zoom + step) : max(zoomTarget, zoom - step)
        if zoom == zoomTarget { zoomTimer?.invalidate(); zoomTimer = nil }
        if inStream != nil { updateStream() } else if let panel { placePanel(panel) }
    }

    /// The zoom's eased amount.
    private var zoomEased: CGFloat { let z = CGFloat(zoom); return z * z * (3 - 2 * z) }

    /// Big in the middle of a screen this size: most of its height or width.
    private func bigSize(in f: CGSize) -> CGSize {
        let w = min(f.width * 0.72, f.height * 0.8 / aspect)
        return CGSize(width: w.rounded(), height: (w * aspect).rounded())
    }

    /// Its frame now: from `normal` toward big in the middle of `screen`, by the zoom.
    private func zoomed(_ normal: CGRect, in screen: CGRect) -> CGRect {
        let e = zoomEased
        guard e > 0 else { return normal }
        let b = bigSize(in: screen.size)
        let big = CGRect(x: screen.midX - b.width / 2, y: screen.midY - b.height / 2, width: b.width, height: b.height)
        return CGRect(x: normal.minX + (big.minX - normal.minX) * e, y: normal.minY + (big.minY - normal.minY) * e,
                      width: normal.width + (big.width - normal.width) * e, height: normal.height + (big.height - normal.height) * e).integral
    }

    /// Redraws when the profile or its layer changes.
    private func watchMappings() {
        guard mappingWatch.isEmpty else { return }
        mappingWatch = [
            DesktopPad.shared.$overlayProfile.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleDraw() } },
            DesktopPad.shared.$overlayLayer.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleDraw() } },
        ]
    }

    private var family: Controllers.Family? {
        switch modelKind ?? wantedKind {
        case .steam2015, .automatic: .valve
        case .steam2026: .steam2026
        case .switchPro: .nintendo
        case .dualShock4: .playstation
        case .xbox: nil
        }
    }

    /// A part's own name, short, for when it does what it's called (drawn dimmed).
    static func ownName(_ i: PadProfiles.Input, _ f: Controllers.Family?) -> String {
        switch (i, f) {
        case (.up, _): "↑"; case (.down, _): "↓"; case (.left, _): "←"; case (.right, _): "→"
        case (.guide, _): "⌂"
        case (.a, .playstation): "✕"; case (.b, .playstation): "○"; case (.x, .playstation): "□"; case (.y, .playstation): "△"
        case (.back, .nintendo): "−"; case (.start, .nintendo): "+"; case (.misc, .nintendo): "◉"
        case (.back, .playstation): "Create"; case (.start, .playstation): "Opt"; case (.misc, .playstation): "Mute"
        case (.back, .valve): "◀"; case (.start, .valve): "▶"
        case (.back, _): "View"; case (.start, _): "Menu"
        case (.misc, .steam2026): "QAM"; case (.misc, _): "Share"
        case (.paddle1, .steam2026): "R4"; case (.paddle2, .steam2026): "L4"; case (.paddle3, .steam2026): "R5"; case (.paddle4, .steam2026): "L5"
        case (.paddle1, .valve): "R Grip"; case (.paddle2, .valve): "L Grip"
        case (.paddle1, _): "P1"; case (.paddle2, _): "P2"; case (.paddle3, _): "P3"; case (.paddle4, _): "P4"
        default: PadLabel.abbreviate(i.title(f), limit: 3)
        }
    }

    /// What every part does in the layer that's on, with what's held and toggled now.
    private func currentMappings(_ model: OverlayControllerModel) -> OverlayMappings? {
        let pad = DesktopPad.shared
        guard let p = pad.overlayProfile, !p.layers.isEmpty else { return nil }
        let layer = min(max(0, pad.overlayLayer), p.layers.count - 1)
        let live = pad.overlayLive(), fam = family
        func binding(_ i: PadProfiles.Input) -> PadProfiles.Binding? { p.layers[layer].bindings[i] ?? (layer > 0 ? p.layers[0].bindings[i] : nil) }
        func text(_ i: PadProfiles.Input) -> PadLabel.Text? {
            guard let b = binding(i), !b.isEmpty, !OverlayMappingRules.isItself(b, i) else { return nil }
            return PadLabel.text(b, family: fam, macros: p.macros, menus: p.menus)
        }
        var m = OverlayMappings()
        for i in PadProfiles.Input.allCases where !i.isVirtual {
            // Beside a button its own name would only add clutter for a stick click; the Steam/guide button reads as ⌂.
            let own = (model.moved.contains(i) && (i == .ls || i == .rs)) ? "" : Self.ownName(i, fam)
            m.buttons[i] = .init(text: text(i), own: own, toggled: live.toggled.contains(i))
        }
        // A trigger's full pull has no part of its own: it goes on the trigger, underneath (⇊), and a toggle of
        // either rings the trigger.
        for (t, full) in [(PadProfiles.Input.lt, PadProfiles.Input.ltfull), (.rt, .rtfull)] {
            guard var cap = m.buttons[t] else { continue }
            if let f = text(full) {
                if var main = cap.text { main.second = "⇊" + f.main; cap.text = main }
                else { cap.text = PadLabel.Text(main: "⇊" + f.main, toggles: f.toggles) }
            }
            cap.toggled = live.toggled.contains(t) || live.toggled.contains(full)
            m.buttons[t] = cap
        }
        let input = active.flatMap { sources[$0]?.input } ?? ControllerOverlayInput()
        let pads = pad.overlayPads(layer: layer)
        for (side, click) in model.padClicks {
            m.pads[side] = OverlayPadFace.steamPad(side: side, settings: pads.indices.contains(side) ? pads[side] : PadSteamTrackpadSettings(),
                                                   label: text, held: live.held, toggled: live.toggled, clickInput: click, clicked: input.buttons.contains(click))
        }
        let sticks = p.sticks.indices.contains(layer) ? p.sticks[layer] : (p.sticks.first ?? [])
        for side in 0..<2 where sticks.indices.contains(side) {
            let st = sticks[side], click: PadProfiles.Input = side == 0 ? .ls : .rs
            var t = OverlayMappingRules.stick(st, side: side, label: text)
            if model.moved.contains(click) {
                // The click is written below the stick.
            } else if let c = text(click) {
                // The click goes in the middle when the directions are around the edge, else underneath.
                if let a = t?.around { t = PadLabel.Text(main: "⏎" + c.main, around: a) }
                else { t = PadLabel.Text(main: t?.main ?? (side == 0 ? "L" : "R"), second: "⏎" + c.main) }
            }
            m.sticks[side] = .init(text: t, own: side == 0 ? "L" : "R", toggled: live.toggled.contains(click))
        }
        return m
    }

    private func draw() {
        guard let model else { return }
        let input = active.flatMap { sources[$0]?.input } ?? ControllerOverlayInput()
        let q = settings.gyro ? motion.orientation(strength: Float(settings.gyroStrength)) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let inputChanged = shownInput.map { !$0.looksLike(input) } ?? true
        // A fifth of a degree: smaller turns can't be seen at overlay sizes.
        let turned = shownOrientation.map { 2 * acos(min(1, abs(simd_dot($0.vector, q.vector)))) > 0.0035 } ?? true
        let labels = mappingsShown ? currentMappings(model) : nil
        let labelsChanged = labels != shownLabels
        let wheel = DesktopPad.shared.wheelState()
        let wheelKey = wheel.map { "\(($0.angle * 2).rounded())|\($0.lock)|\($0.dead)" }
        // Shown without a controller while it's being moved or its settings are open, to see what's edited.
        let hidden = settings.hideWithoutController && sources.isEmpty && !arranging && previewing == 0
        guard inputChanged || turned || labelsChanged || wheelKey != shownWheel || hidden != model.root.isHidden else { return }
        lastDraw = ProcessInfo.processInfo.systemUptime
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        if inputChanged { model.show(input); shownInput = input }
        if labelsChanged { model.showMappings(labels); shownLabels = labels }
        updateWheel(hidden: model.root.isHidden)
        if model.root.isHidden != hidden { model.root.isHidden = hidden }
        if turned { model.root.simdOrientation = q; shownOrientation = q }
        SCNTransaction.commit()
        streamDrawer?.changed()
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
    var camera: SCNNode? { sceneView.pointOfView }
    /// While the drawing goes into a stream's frames, the on-screen view stops drawing (its window is hidden, but
    /// SceneKit would still render it on every change, with its own display timing).
    var viewPaused = false {
        didSet {
            guard viewPaused != oldValue else { return }
            sceneView.scene = viewPaused ? nil : scene
            sceneView.isHidden = viewPaused
        }
    }
    /// Above the controller and towards the player, `degrees` above level, looking at it.
    func view(from degrees: Double) {
        guard let camera else { return }
        let a = Float(degrees * .pi / 180), distance: Float = 9.16
        camera.simdPosition = SIMD3(0, distance * sin(a), distance * cos(a))
        camera.simdLook(at: SIMD3(0, -0.1, 0.05), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }
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
        content
            .onAppear { overlay.previewing += 1 }
            .onDisappear { overlay.previewing = max(0, overlay.previewing - 1) }
    }

    @ViewBuilder private var content: some View {
        Section("Controller overlay") {
            Picker("Show", selection: $overlay.settings.mode) {
                ForEach(ControllerOverlaySettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("A 3D controller showing your buttons, sticks, triggers and trackpads as you use them, turning with the gyro. Over games and streams, it sits on top of everything and never takes clicks. In its own window, add it to OBS as a macOS Screen Capture source set to Window, and use a background colour with a Chroma Key filter. Over a full-screen stream it's drawn into the stream's own picture, so it adds almost no delay.")
                .font(.caption).foregroundStyle(.secondary)
            if overlay.settings.mode != .off {
                Picker("Controller", selection: $overlay.settings.model) {
                    ForEach(ControllerOverlaySettings.Model.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("With several controllers", selection: $overlay.settings.follow) {
                    ForEach(ControllerOverlaySettings.Follow.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(overlay.showing.isEmpty ? "No controller connected." : "Showing: \(overlay.showing)\(overlay.settings.follow == .playerOne ? ". Player 1 is set in Profiles → Controllers (Auto: the order they connected, the Steam Controller a profile reads first)." : "")")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("While these settings are open or the overlay is being moved, it shows anyway, so you can see what you're changing.").font(.caption).foregroundStyle(.secondary)
                Picker("Show mappings", selection: $overlay.settings.mappings) {
                    ForEach(ControllerOverlaySettings.Mappings.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(overlay.settings.mappings == .off ? "Writes what each button, trackpad region and stick does on the controller itself, for the layer that's on: a key's symbol (⇧ ⌃ ␣ ↩ …) or a short name, a hold or double tap underneath, a ring on anything toggled on, and the trackpad region your thumb is on lit up."
                     : overlay.settings.mappings == .always ? "Shown all the time, for the layer that's on."
                     : "Give a button \"Show mappings on the overlay\" in your controller profile (it can share a button with something else through a layer or a hold). \(overlay.settings.mappings == .whileHeld ? "Mappings show while it's held." : "Each press shows or hides them.")")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Zoom in with the mappings button", isOn: $overlay.settings.zoomWithMappings)
                Text("The \"Show mappings on the overlay\" button grows the controller big in the middle of the screen to read its mappings, and shrinks it back to its place after. With mappings shown always, it zooms while the button is held. In a stream it's drawn once at the big size, so zooming adds nothing to the frames.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Headphone motion picture", isOn: $overlay.settings.headMotion.shown)
                if overlay.settings.headMotion.shown {
                    LabeledContent("Across") {
                        Slider(value: $overlay.settings.headMotion.positionX, in: 0...1).frame(width: 180)
                    }
                    LabeledContent("Up") {
                        Slider(value: $overlay.settings.headMotion.positionY, in: 0...1).frame(width: 180)
                    }
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: $overlay.settings.headMotion.size, in: ControllerOverlaySettings.DevicePanel.sizes, step: 5).frame(width: 180)
                            Text(verbatim: "\(Int(overlay.settings.headMotion.size)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Text("A small picture of its own, placed separately, while a profile with headphone motion (AirPods) is in use: where your head points, the dead zone, how far it reaches, and the directions it's pressing. Shown with the overlay over games and streams.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Turn with the gyro", isOn: $overlay.settings.gyro)
                if overlay.settings.gyro {
                    LabeledContent("Movement shown") {
                        HStack {
                            Slider(value: $overlay.settings.gyroStrength, in: 0...1.5, step: 0.05).frame(width: 180)
                            Text(verbatim: "\(Int((overlay.settings.gyroStrength * 100).rounded()))%").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    LabeledContent("Seen from") {
                        HStack {
                            Text("In front").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $overlay.settings.viewAngle, in: ControllerOverlaySettings.viewAngles, step: 1).frame(width: 160)
                            Text("Above").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Recentre") { overlay.recenter() }
                        Text("Or hold Back and Start together for a second (View and Menu, Share and Options, − and +). The way you hold the controller then becomes level and facing the front. Both also settle back by themselves a moment after you stop moving it.")
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


// MARK: - Drawing into a stream's frames

/// Draws the overlay's scene into a stream frame on the stream's render queue. SceneKit renders the controller into
/// a texture of its own (sRGB, at twice the size for smooth edges, clear around it), which is then blended onto the
/// frame: SceneKit lights in linear colour and only an sRGB target converts it back, so drawing straight into the
/// stream's plain 8-bit frame would come out much darker. The scene is changed on the main thread inside SceneKit
/// transactions; the drawing holds SceneKit's lock, so it never sees half a change.
final class StreamOverlayDrawer: @unchecked Sendable {
    /// The 3D drawing is rendered on the main thread with its own command queue, only when it changed, into one of
    /// two textures; each stream frame just copies the newest finished one. The stream never waits for SceneKit
    /// (rendering inside the frame, a moving controller held up frames: up to 70 ms).
    private let renderer: SCNRenderer
    private let device: MTLDevice
    private let queue: MTLCommandQueue?
    private struct Target { let color: MTLTexture; let encoded: MTLTexture; let depth: MTLTexture }
    private var targets: [Target] = []           // main thread
    private var next = 0                          // main thread
    private var inFlight = false, pending = false // main thread
    private var front: Target?                    // guarded by `lock`
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]   // render queue
    private let library: MTLLibrary?
    private let sampler: MTLSamplerState?
    private var lock = os_unfair_lock()
    private var rect = CGRect.zero, screenWidth: CGFloat = 1, opacity: Double = 1   // guarded by `lock`
    private var renderSize = CGSize.zero                                            // main thread
    private var scale: CGFloat = 2                                                  // main thread

    init(device: MTLDevice, scene: SCNScene, camera: SCNNode?) {
        self.device = device
        queue = device.makeCommandQueue()
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = false
        library = try? device.makeLibrary(source: Self.shader, options: nil)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sd)
    }

    /// Main thread: where it goes (points from the screen's top left), the screen's scale, and how opaque it is.
    func place(_ r: CGRect, render: CGSize, screenWidth w: CGFloat, scale s: CGFloat, opacity o: Double) {
        os_unfair_lock_lock(&lock)
        rect = r; screenWidth = max(1, w); opacity = o
        os_unfair_lock_unlock(&lock)
        // A new picture only when the size it's rendered at changes; moving or zooming just draws it elsewhere.
        if render != renderSize || s != scale || front == nil { renderSize = render; scale = s; changed() }
    }

    /// Main thread: the drawing changed (buttons, sticks, the gyro's turn, colours, the controller drawn). Renders it
    /// now, or right after the render in progress (never more than one behind).
    func changed() {
        guard !inFlight else { pending = true; return }
        let r = CGRect(origin: .zero, size: renderSize)
        // Twice the screen's pixels, for smooth edges when it's drawn down onto the frame.
        let tw = max(1, Int(r.width * scale * 2)), th = max(1, Int(r.height * scale * 2))
        guard r.width > 0, let queue, let buffer = queue.makeCommandBuffer() else { return }
        if targets.first?.color.width != tw || targets.first?.color.height != th {
            targets = (0..<2).compactMap { _ in makeTarget(tw, th) }; next = 0
        }
        guard targets.count == 2 else { return }
        let t = targets[next]; next = 1 - next
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t.color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = t.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(x: 0, y: 0, width: tw, height: th), commandBuffer: buffer, passDescriptor: pass)
        inFlight = true
        buffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            os_unfair_lock_lock(&self.lock); self.front = t; os_unfair_lock_unlock(&self.lock)
            DispatchQueue.main.async {
                self.inFlight = false
                if self.pending { self.pending = false; self.changed() }
            }
        }
        buffer.commit()
    }

    private func makeTarget(_ w: Int, _ h: Int) -> Target? {
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead, .pixelFormatView]; cd.storageMode = .private
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .private
        guard let c = device.makeTexture(descriptor: cd), let e = c.makeTextureView(pixelFormat: .bgra8Unorm),
              let d = device.makeTexture(descriptor: dd) else { return nil }
        return Target(color: c, encoded: e, depth: d)
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    vertex V overlay_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        V v; v.position = float4(p * 2 - 1, 0, 1); v.uv = float2(p.x, 1 - p.y); return v;
    }
    fragment float4 overlay_fragment(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                                     constant float &opacity [[buffer(0)]]) {
        return t.sample(s, in.uv) * opacity;        // premultiplied
    }
    """

    private func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = pipelines[format] { return p }
        guard let library, let v = library.makeFunction(name: "overlay_vertex"), let f = library.makeFunction(name: "overlay_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v; d.fragmentFunction = f
        let c = d.colorAttachments[0]!
        c.pixelFormat = format
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let p = try? device.makeRenderPipelineState(descriptor: d)
        pipelines[format] = p
        return p
    }

    /// Render queue: the newest finished drawing onto the frame (a copy; nothing waits for SceneKit).
    func draw(_ enc: MTLRenderCommandEncoder, _ target: MTLTexture) {
        os_unfair_lock_lock(&lock); let r = rect, w = screenWidth, o = Float(opacity), t = front; os_unfair_lock_unlock(&lock)
        guard let t, r.width > 0, let pipeline = pipeline(target.pixelFormat), let sampler else { return }
        let s = CGFloat(target.width) / w
        // An 8-bit frame holds sRGB-encoded values (read the drawing undecoded), a floating-point (EDR) one linear values.
        let source = target.pixelFormat == .bgra8Unorm || target.pixelFormat == .rgba8Unorm ? t.encoded : t.color
        enc.setRenderPipelineState(pipeline)
        enc.setViewport(MTLViewport(originX: Double(r.minX * s), originY: Double(r.minY * s), width: Double(r.width * s), height: Double(r.height * s), znear: 0, zfar: 1))
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        var opacity = o
        enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

