// SPDX-License-Identifier: GPL-3.0-only
// The stream's window: the host's picture, its sound, and this Mac's keyboard, mouse and controllers going back.
import AppKit
import AVFoundation
import GameController
import NokcanduCore
import NokcanduStreamCore
import SwiftUI

/// What the overlay shows.
@MainActor final class StreamWindowState: ObservableObject {
    @Published var stage = "Connecting…"
    @Published var connected = false
    @Published var error: String?
    @Published var poorConnection = false
    @Published var statistics: StreamProfile.Window.Statistics = .off
    @Published var statsText = ""
    @Published var captured = false
    @Published var hint: String?
}

@MainActor final class StreamWindowController: NSWindowController, NSWindowDelegate, StreamConnectionDelegate, StreamPadRoute {
    let connection: StreamConnection
    let state = StreamWindowState()
    private(set) var gamepads: StreamGamepads
    let keyboard: StreamKeyboard
    /// The stream profile as it is now: settings changed during the stream that can apply, apply (see apply(_:)).
    private(set) var profile: StreamProfile
    private let identity: StreamIdentity
    private let streamView: StreamView
    private var statsTimer: Timer?
    private var displayLink: CADisplayLink?
    private var ended = false
    private var vban: StreamVBANSender?
    private var vbanSettings: VBANSettings?

    /// Settings changed in the stream profile while the stream runs. Those the host fixes at the start (picture size,
    /// frame rate, bitrate, codec, HDR, colour, channels, sound on the host, the app, the route) wait for the next stream.
    func apply(_ next: StreamProfile) {
        let old = profile
        profile = next
        connection.video.pacing = next.video.pacing
        connection.video.frameBuffer = next.video.frameBuffer
        connection.audio.volume = Float(next.audio.volume)
        connection.audio.outputDevice = next.audio.outputDevice
        keyboard.input = next.input
        if next.input.keyboardLayout != old.input.keyboardLayout { applyKeyboardLayout() }
        if next.window.statistics != old.window.statistics {
            state.statistics = next.window.statistics
            if next.window.statistics == .off { state.statsText = "" } else { updateStats() }
        }
        if next.window.display != old.window.display, let target = StreamDisplays.screen(for: next.window.display) { move(to: target) }
        else if next.window.fullScreen != old.window.fullScreen { setFullScreen(next.window.fullScreen) }
        if next.input.mouse != old.input.mouse {
            if next.input.mouse == .capture { if window?.isKeyWindow == true { captureMouse() } } else { releaseMouse() }
        }
        if next.controller != old.controller, state.connected {
            // The host sees the controllers leave and arrive again, as the new kind and with the new profile.
            gamepads.stop()
            gamepads = StreamGamepads(settings: next.controller)
            gamepads.start()
            DesktopPad.shared.evaluate(force: true)
        }
        applyVBAN(next.audio.vban)
    }

    /// Starts, restarts or stops sending the microphone over VBAN. Called when the stream starts and whenever the
    /// stream profile's VBAN settings change during the stream.
    func applyVBAN(_ settings: VBANSettings) {
        guard state.connected, !ended else { return }
        let wanted: VBANSettings? = settings.enabled ? settings : nil
        guard wanted != vbanSettings else { return }
        // Processing and push-to-talk changes apply to the running sender; the rest restarts it.
        if let w = wanted, let current = vbanSettings, let sender = vban, w.sameTransport(as: current) {
            sender.update(w); vbanSettings = w
            if w.pushToTalk { installPushToTalkMonitor() }
            return
        }
        vban?.stop(); vban = nil
        vbanSettings = wanted
        guard let wanted else { StreamLog.shared.add("VBAN: off"); return }
        let sender = StreamVBANSender(settings: wanted, hostAddress: connection.address)
        vban = sender
        if wanted.pushToTalk { installPushToTalkMonitor() }
        sender.start { [weak self] message in
            StreamLog.shared.add(message)
            self?.flash(message)
        }
    }
    /// The Mac clipboard's change count when it was last sent to (or taken from) the host.
    private var clipboardSynced = -1
    private var lastHostClipboard: String?
    /// The host turned out not to share its clipboard (not Apollo): stop asking.
    private var clipboardUnsupported = false
    var onEnd: ((String?) -> Void)?

    var profileID: String? { profile.controller.profileID }
    var isFront: Bool { NSApp.isActive && window?.isKeyWindow == true && state.connected }

    init(host: StreamHost, profile: StreamProfile, address: String, identity: StreamIdentity) {
        connection = StreamConnection(host: host, profile: profile, address: address)
        self.profile = profile
        gamepads = StreamGamepads(settings: profile.controller)
        keyboard = StreamKeyboard(input: profile.input)
        self.identity = identity
        streamView = StreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(profile.name) — \(host.name)"
        w.collectionBehavior = [.fullScreenPrimary, .managed]
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.acceptsMouseMovedEvents = true
        super.init(window: w)
        state.statistics = profile.window.statistics
        w.delegate = self
        streamView.controller = self
        streamView.videoLayer = connection.video.layer
        let overlay = PassthroughHostingView(rootView: StreamOverlay(state: state, quit: { [weak self] in self?.endStream(quitApp: false) }))
        overlay.passThrough = { [weak self] in self?.state.connected ?? false }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        streamView.addSubview(overlay)
        NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo: streamView.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: streamView.trailingAnchor),
                                     overlay.topAnchor.constraint(equalTo: streamView.topAnchor), overlay.bottomAnchor.constraint(equalTo: streamView.bottomAnchor)])
        w.contentView = streamView
        w.center()
        w.setFrameAutosaveName("NokcanduStreamWindow")
        connection.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Starting and ending

    func begin() {
        if let target = StreamDisplays.screen(for: profile.window.display) { place(on: target) }
        showWindow(nil)
        window?.makeFirstResponder(streamView)
        NSApp.activate(ignoringOtherApps: true)
        if profile.window.fullScreen { setFullScreen(true) }
        let screen = StreamDisplays.screen(for: profile.window.display) ?? window?.screen ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        // "This Mac's display" means the area the stream can use on the display it plays on: in full screen on a Mac
        // with a notch, macOS keeps the strip beside the camera for the menu bar, so asking for the whole screen
        // letterboxed the picture.
        var size = screen.map { StreamDisplays.pixels($0, fullScreen: profile.window.fullScreen) } ?? CGSize(width: 1920, height: 1080)
        if !profile.window.fullScreen, let content = window?.contentLayoutRect.size, content.width > 0 {
            size = CGSize(width: (content.width * scale / 2).rounded() * 2, height: (content.height * scale / 2).rounded() * 2)
        }
        if let screen { StreamLog.shared.add("Window: playing on \(StreamDisplays.label(screen)), \(Int(screen.backingScaleFactor))× scale, \(NSScreen.screens.count) display(s) connected") }
        let refresh = Double(screen?.maximumFramesPerSecond ?? 60)
        let mask = gamepads.mask
        StreamConnection.current = connection
        let connection = self.connection, identity = self.identity
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                try connection.start(identity: identity, size: size, refreshRate: refresh, gamepadMask: mask)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.failed(message) }
            }
        }
    }

    private func failed(_ message: String) {
        state.error = message
        state.connected = false
        finish(error: message)
    }

    /// Ends the stream; with `quitApp` the app on the host quits too.
    func endStream(quitApp: Bool) {
        guard !ended else { window?.close(); return }
        releaseMouse()
        keyboard.releaseAll()
        let c = connection, identity = self.identity
        DispatchQueue.global(qos: .userInitiated).async {
            if quitApp { c.stopAndQuit(identity: identity) } else { c.stop() }
        }
        finish(error: nil)
        window?.close()
    }

    private func finish(error: String?) {
        guard !ended else { return }
        ended = true
        statsTimer?.invalidate(); statsTimer = nil
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        if let m = pttMonitor { NSEvent.removeMonitor(m); pttMonitor = nil }
        displayLink?.invalidate(); displayLink = nil
        gamepads.stop()
        MacGameKeys.shared.streamFront(nil)
        vban?.stop(); vban = nil
        releaseMouse()
        NSEvent.isMouseCoalescingEnabled = true
        if DesktopPad.shared.stream === self { DesktopPad.shared.stream = nil }
        if StreamConnection.current === connection { StreamConnection.current = nil }
        onEnd?(error)
    }

    // MARK: StreamConnectionDelegate

    func streamStage(_ text: String) { state.stage = text }

    func streamStarted() {
        state.connected = true
        state.stage = ""
        gamepads.start()
        DesktopPad.shared.stream = self
        // Every mouse movement report, not the coalesced few per frame.
        NSEvent.isMouseCoalescingEnabled = false
        installEventMonitor()
        applyKeyboardLayout()
        applyVBAN(profile.audio.vban)
        window?.makeFirstResponder(streamView)
        let link = streamView.displayLink(target: self, selector: #selector(refresh))
        link.add(to: .main, forMode: .common)
        displayLink = link
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateStats() } }
        if profile.input.mouse == .capture, window?.isKeyWindow == true { captureMouse() }
        if profile.input.clipboard { sendClipboard(auto: true) }
        state.hint = profile.input.mouse == .capture ? "Press ⌃⌥⇧Z to free the pointer, ⌃⌥⇧Q to end the stream." : "Press ⌃⌥⇧Q to end the stream."
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.state.hint = nil }
    }

    func streamEnded(error: String?) {
        if let error { state.error = error; state.connected = false }
        finish(error: error)
        if error == nil { window?.close() }
    }

    func streamPoorConnection(_ poor: Bool) { state.poorConnection = poor }
    func streamRumble(controller: Int, low: UInt16, high: UInt16) { gamepads.rumble(controller, low: low, high: high) }
    func streamTriggerRumble(controller: Int, left: UInt16, right: UInt16) {}
    func streamMotionRequested(controller: Int, type: UInt8, rateHz: UInt16) { gamepads.motionRequested(controller, type: type, rateHz: rateHz) }
    func streamLight(controller: Int, r: UInt8, g: UInt8, b: UInt8) { gamepads.light(controller, r: r, g: g, b: b) }
    func streamHDR(_ on: Bool) {
        StreamLog.shared.add("HDR \(on ? "on" : "off")")
        connection.video.layer.wantsExtendedDynamicRangeContent = on
    }

    @objc private func refresh() { connection.video.displayRefresh() }

    private func updateStats() {
        let v = connection.video.stats.roll()
        guard state.statistics != .off else { return }
        var rtt: UInt32 = 0, variance: UInt32 = 0
        _ = LiGetEstimatedRttInfo(&rtt, &variance)
        let video = connection.video
        var lines = [String(format: "%d×%d  %@  %.0f fps", video.width, video.height, StreamConnection.formatName(connection.negotiatedFormat), v.shownFPS)]
        lines.append(String(format: "Network %d ms (±%d)  Decode %.1f ms", rtt, variance, v.decodeMs))
        if state.statistics == .detailed {
            lines.append(String(format: "Received %.0f fps  Host %.1f ms  Audio %.0f ms", v.receivedFPS, v.hostMs, connection.audio.queuedMs))
            lines.append("Frames dropped: \(v.dropped) decode, \(v.pacedDrops) pacing")
        }
        state.statsText = lines.joined(separator: "\n")
    }

    // MARK: Mouse

    func captureMouse() {
        guard profile.input.mouse == .capture, state.connected, !state.captured else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        state.captured = true
    }
    func releaseMouse() {
        guard state.captured else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        state.captured = false
    }

    // MARK: NSWindowDelegate

    /// The stream's keyboard layout, on while its window is in front.
    private func applyKeyboardLayout() {
        let front = state.connected && !ended && window?.isKeyWindow == true && NSApp.isActive
        MacGameKeys.shared.streamFront(front ? profile.input.keyMappings() : nil)
    }

    // MARK: Displays and full screen

    /// Puts the (windowed) window on a display, centred, keeping its size when it fits.
    private func place(on screen: NSScreen) {
        guard let w = window, w.screen != screen else { return }   // a saved position on that display stays
        let area = screen.visibleFrame
        var f = w.frame
        f.size.width = min(f.width, area.width); f.size.height = min(f.height, area.height)
        f.origin = CGPoint(x: area.midX - f.width / 2, y: area.midY - f.height / 2)
        w.setFrame(f, display: true)
    }

    private var pendingMove: NSScreen?

    /// Moves a running stream to another display: out of full screen, across, and back in.
    func move(to screen: NSScreen) {
        guard let w = window, w.screen != screen else { return }
        if w.styleMask.contains(.fullScreen) {
            pendingMove = screen
            setFullScreen(false)
        } else {
            place(on: screen)
            if profile.window.fullScreen { setFullScreen(true) }
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let s = window?.screen, state.connected else { return }
        StreamLog.shared.add("Window: moved to \(StreamDisplays.label(s))")
        // The host fixed the picture size at the start; say so when it no longer matches this display.
        let px = StreamDisplays.pixels(s, fullScreen: profile.window.fullScreen)
        let w = connection.video.width, h = connection.video.height
        if profile.video.width == nil, w > 0, h > 0, abs(Double(w) / Double(h) - px.width / px.height) > 0.02 {
            flash("The picture size is set when a stream starts. End and start it again to fit this display.")
        }
    }

    private var fullScreenWanted: Bool?
    private var fullScreenMoving = false
    private var fullScreenAttempts = 0

    /// Enters or leaves full screen and keeps at it until macOS has done it. A request made right after the window
    /// appears, before the app is active, or while another transition runs is dropped by macOS without an error,
    /// which left streams set to full screen in a window.
    func setFullScreen(_ on: Bool) {
        fullScreenWanted = on
        fullScreenAttempts = 0
        if on { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        driveFullScreen()
    }

    private func driveFullScreen() {
        guard let want = fullScreenWanted, let w = window, !ended else { return }
        if w.styleMask.contains(.fullScreen) == want { fullScreenWanted = nil; return }
        if !fullScreenMoving, w.isVisible, fullScreenAttempts < 8 {
            fullScreenAttempts += 1
            w.toggleFullScreen(nil)
        }
        guard fullScreenAttempts < 8 else {
            StreamLog.shared.add("Window: macOS didn't \(want ? "enter" : "leave") full screen")
            fullScreenWanted = nil; return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.driveFullScreen() }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenMoving = true }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreenMoving = true }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreenMoving = false; fullScreenSettled() }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenMoving = false; fullScreenSettled() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenMoving = false }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreenMoving = false }

    private func fullScreenSettled() {
        if let w = window {
            StreamLog.shared.add("Window: \(w.styleMask.contains(.fullScreen) ? "full screen" : "windowed"), content \(Int(w.contentLayoutRect.width))×\(Int(w.contentLayoutRect.height)) pt on \(w.screen?.localizedName ?? "?")")
        }
        if let want = fullScreenWanted, window?.styleMask.contains(.fullScreen) == want { fullScreenWanted = nil }
        if let target = pendingMove, window?.styleMask.contains(.fullScreen) == false {
            pendingMove = nil
            place(on: target)
            if profile.window.fullScreen { DispatchQueue.main.async { [weak self] in self?.setFullScreen(true) } }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applyKeyboardLayout()
        if state.connected, profile.input.mouse == .capture { captureMouse() }
        if state.connected, profile.input.clipboard { sendClipboard(auto: true) }
        DesktopPad.shared.evaluate(force: true)
    }
    func windowDidResignKey(_ notification: Notification) {
        MacGameKeys.shared.streamFront(nil)
        if state.connected, profile.input.clipboard { fetchClipboard(auto: true) }
        releaseMouse()
        keyboard.releaseAll()
        DesktopPad.shared.evaluate(force: true)
    }
    func windowWillClose(_ notification: Notification) {
        if !ended { endStream(quitApp: false) }
    }

    // MARK: Clipboard (Apollo hosts)

    private func clipboardClient() -> StreamClient {
        let h = connection.host
        return StreamClient(address: connection.address, httpPort: h.httpPort, httpsPort: h.httpsPort, identity: identity,
                            serverCertificate: h.serverCertificate.flatMap { Data(base64Encoded: $0) })
    }

    /// Sends the Mac's clipboard text to the host. Automatically only when it changed since the last sync.
    func sendClipboard(auto: Bool) {
        guard !(auto && clipboardUnsupported) else { return }
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        if auto && (pb.changeCount == clipboardSynced || text == lastHostClipboard) { return }
        let count = pb.changeCount, client = clipboardClient()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try client.setHostClipboard(text)
                DispatchQueue.main.async { self?.clipboardSynced = count; self?.lastHostClipboard = text; if !auto { self?.flash("Clipboard sent to the host.") } }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                StreamLog.shared.add("Clipboard: \(message)")
                DispatchQueue.main.async { self?.clipboardFailed(message, auto: auto) }
            }
        }
    }

    /// Puts the host's clipboard text on the Mac's clipboard. Automatically only when it changed on the host.
    func fetchClipboard(auto: Bool) {
        guard !(auto && clipboardUnsupported) else { return }
        let client = clipboardClient()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let text = try client.hostClipboard()
                DispatchQueue.main.async {
                    guard let self, !text.isEmpty else { return }
                    if auto && text == self.lastHostClipboard { return }
                    let pb = NSPasteboard.general
                    if pb.string(forType: .string) != text { pb.clearContents(); pb.setString(text, forType: .string) }
                    self.lastHostClipboard = text
                    self.clipboardSynced = pb.changeCount
                    if !auto { self.flash("Copied the host's clipboard.") }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                StreamLog.shared.add("Clipboard: \(message)")
                DispatchQueue.main.async { self?.clipboardFailed(message, auto: auto) }
            }
        }
    }

    private func clipboardFailed(_ message: String, auto: Bool) {
        if message.contains("Apollo (a Sunshine version)") { clipboardUnsupported = true }
        // Automatic syncing stays quiet on a host without it; a chosen menu item always says why.
        if !auto || !clipboardUnsupported { flash(message) }
    }

    private func flash(_ text: String) {
        state.hint = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.state.hint == text { self?.state.hint = nil } }
    }

    // MARK: Events

    private var eventMonitor: Any?

    /// Takes the stream window's keyboard and mouse events before the rest of the app sees them, so they reach
    /// the host whatever has focus inside the window (the overlay's buttons could take it). Events in other
    /// windows, menus and the title bar pass through untouched.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] e in
            nonisolated(unsafe) let event = e      // local monitors run on the main thread
            return MainActor.assumeIsolated { (self?.handle(event) ?? false) ? nil : event }
        }
    }

    // MARK: The VBAN microphone: mute and push-to-talk

    private var pttMonitor: Any?

    var micLevel: Float? { vban.map { $0.transmitting ? $0.meter : 0 } }

    func toggleMicMute() {
        guard let v = vban else { flash("The VBAN microphone is off for this stream."); return }
        v.muted.toggle()
        flash(v.muted ? "Microphone muted" : "Microphone on")
    }

    /// Whether this event is the push-to-talk input, and if so whether it's now held.
    private func pttEvent(_ e: NSEvent) -> Bool? {
        guard let s = vbanSettings, s.pushToTalk, let input = s.pushToTalkInput else { return nil }
        let parts = input.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        switch (parts[0], e.type) {
        case ("key", .keyDown) where Int(e.keyCode) == n: return true
        case ("key", .keyUp) where Int(e.keyCode) == n: return false
        case ("key", .flagsChanged) where Int(e.keyCode) == n:
            // A modifier as the key: held while its flag is set.
            let flag: NSEvent.ModifierFlags = [0x38, 0x3C].contains(n) ? .shift : [0x3B, 0x3E].contains(n) ? .control
                : [0x3A, 0x3D].contains(n) ? .option : [0x37, 0x36].contains(n) ? .command : n == 0x3F ? .function : .capsLock
            return e.modifierFlags.contains(flag)
        case ("mouse", .otherMouseDown) where e.buttonNumber == n: return true
        case ("mouse", .otherMouseUp) where e.buttonNumber == n: return false
        default: return nil
        }
    }

    private func setTalking(_ down: Bool) {
        guard let v = vban, v.talking != down else { return }
        v.talking = down
    }

    /// Push-to-talk works whichever app is in front (like VBAN Talkie's): a global monitor while the stream runs.
    private func installPushToTalkMonitor() {
        guard pttMonitor == nil else { return }
        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]) { [weak self] e in
            nonisolated(unsafe) let event = e
            MainActor.assumeIsolated { if let down = self?.pttEvent(event) { self?.setTalking(down) } }
        }
    }

    /// True when the event was sent to the host (and is used up).
    private func handle(_ e: NSEvent) -> Bool {
        // The push-to-talk key or button is the Mac's: it never reaches the host.
        if state.connected, let down = pttEvent(e) { setTalking(down); return e.window === window }
        guard state.connected, let w = window, e.window === w, w.isKeyWindow else {
            if [.keyDown, .flagsChanged].contains(e.type) {
                StreamInputLog.note("skipped \(e.type.rawValue) connected=\(state.connected) sameWindow=\(e.window === window) key=\(window?.isKeyWindow ?? false)", 0)
            }
            return false
        }
        switch e.type {
        case .keyDown, .keyUp:
            let down = e.type == .keyDown
            if down, handleShortcut(e) { return true }
            // With ⌘ kept on the Mac, its shortcuts work as usual (⌘Q, ⌘Tab, ⌘H…).
            if e.modifierFlags.contains(.command), !profile.input.commandAsWindowsKey { return false }
            if !e.isARepeat { keyboard.key(e, down: down) }
            return true
        case .flagsChanged:
            keyboard.flags(e)
            return true
        default:
            // Only the picture: the title bar (in a window) stays usable.
            let p = streamView.convert(e.locationInWindow, from: nil)
            guard state.captured || streamView.bounds.contains(p) else { return false }
            switch e.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: mouseMoved(e, in: streamView)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: mouseButton(e, down: true)
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: mouseButton(e, down: false)
            case .scrollWheel: scroll(e)
            default: return false
            }
            return true
        }
    }

    // MARK: Events from the view

    /// ⌃⌥⇧ shortcuts that stay on the Mac.
    func handleShortcut(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection([.control, .option, .shift, .command])
        guard f == [.control, .option, .shift] else { return false }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "q": endStream(quitApp: false)
        case "z": if state.captured { releaseMouse() } else { captureMouse() }
        case "s":
            let all = StreamProfile.Window.Statistics.allCases
            state.statistics = all[(all.firstIndex(of: state.statistics)! + 1) % all.count]
            if state.statistics == .off { state.statsText = "" } else { updateStats() }
        case "x": setFullScreen(!(window?.styleMask.contains(.fullScreen) ?? false))
        case "d": window?.miniaturize(nil)
        case "m": toggleMicMute()
        default: return false
        }
        return true
    }

    func keyEvent(_ e: NSEvent, down: Bool) {
        guard state.connected else { return }
        if down, handleShortcut(e) { return }
        if e.isARepeat { return }        // the host makes its own repeats
        keyboard.key(e, down: down)
    }
    func flagsEvent(_ e: NSEvent) { if state.connected { keyboard.flags(e) } }

    func mouseMoved(_ e: NSEvent, in view: NSView) {
        guard state.connected else { return }
        if profile.input.mouse == .capture {
            guard state.captured else { return }
            let dx = Int16(max(-32768, min(32767, e.deltaX.rounded()))), dy = Int16(max(-32768, min(32767, e.deltaY.rounded())))
            if dx != 0 || dy != 0 { StreamInputLog.note("move \(dx),\(dy)", LiSendMouseMoveEvent(dx, dy)) }
        } else {
            let p = view.convert(e.locationInWindow, from: nil)
            let r = streamView.videoRect
            guard r.width > 0, r.height > 0 else { return }
            let x = (p.x - r.minX) / r.width, y = 1 - (p.y - r.minY) / r.height
            guard (0...1).contains(x), (0...1).contains(y) else { return }
            LiSendMousePositionEvent(Int16(x * 4096), Int16(y * 4096), 4096, 4096)
        }
    }

    func mouseButton(_ e: NSEvent, down: Bool) {
        guard state.connected else { return }
        if profile.input.mouse == .capture, !state.captured {
            // The first click into the window takes the pointer, and isn't sent.
            if down { captureMouse() }
            return
        }
        let b = StreamMouseButtons.from(mac: e.buttonNumber)
        guard b != 0 else { return }
        LiSendMouseButtonEvent(CChar(down ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), b)
    }

    func scroll(_ e: NSEvent) {
        guard state.connected else { return }
        let flip: CGFloat = profile.input.reverseScroll ? -1 : 1
        // GameStream's wheel unit is 120 per notch; a trackpad's precise deltas are points (about 10 per notch).
        let scale: CGFloat = e.hasPreciseScrollingDeltas ? 12 : 120
        let y = e.scrollingDeltaY * scale * flip, x = e.scrollingDeltaX * scale * flip
        if abs(y) >= 1 { LiSendHighResScrollEvent(Int16(max(-32768, min(32767, y.rounded())))) }
        if abs(x) >= 1 { LiSendHighResHScrollEvent(Int16(max(-32768, min(32767, (-x).rounded())))) }
    }

    // MARK: StreamPadRoute (a Nokcandu profile's output)

    func padButton(_ b: Int, _ down: Bool) { gamepads.profileButton(b, down) }
    func padAxis(_ a: Int, _ v: Int) { gamepads.profileAxis(a, v) }
    func key(_ mac: Int, _ down: Bool) { keyboard.profileKey(mac, down) }
    func mouseButton(_ b: Int, _ down: Bool) {
        LiSendMouseButtonEvent(CChar(down ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), StreamMouseButtons.from(engine: b))
    }
    func mouseMove(_ dx: Int, _ dy: Int) { LiSendMouseMoveEvent(Int16(clamping: dx), Int16(clamping: dy)) }
    func wheel(_ clicks: Int) { LiSendHighResScrollEvent(Int16(clamping: clicks * 120)) }
    func text(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { b in
            b.baseAddress.map { p in p.withMemoryRebound(to: CChar.self, capacity: b.count) { _ = LiSendUtf8TextEvent($0, UInt32(b.count)) } }
        }
    }
}

/// Hosts the video layer and passes input to the controller.
final class StreamView: NSView {
    weak var controller: StreamWindowController?
    var videoLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let v = videoLayer { layer?.addSublayer(v); needsLayout = true }
        }
    }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }

    /// Where the picture is inside the view (letterboxed to the stream's shape).
    var videoRect: CGRect {
        guard let c = controller, c.connection.video.width > 0 else { return bounds }
        return AVMakeRect(aspectRatio: CGSize(width: c.connection.video.width, height: c.connection.video.height), insideRect: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func keyDown(with e: NSEvent) { controller?.keyEvent(e, down: true) }
    override func keyUp(with e: NSEvent) { controller?.keyEvent(e, down: false) }
    override func flagsChanged(with e: NSEvent) { controller?.flagsEvent(e) }
    /// ⌘ shortcuts go to the host too while streaming (except the ⌃⌥⇧ ones and ⌘Q).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard let c = controller, c.state.connected, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: e) }
        if c.handleShortcut(e) { return true }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q", !c.profile.input.commandAsWindowsKey { return super.performKeyEquivalent(with: e) }
        if e.type == .keyDown { c.keyEvent(e, down: true) }
        return true
    }

    override func mouseMoved(with e: NSEvent) { controller?.mouseMoved(e, in: self) }
    override func mouseDragged(with e: NSEvent) { controller?.mouseMoved(e, in: self) }
    override func rightMouseDragged(with e: NSEvent) { controller?.mouseMoved(e, in: self) }
    override func otherMouseDragged(with e: NSEvent) { controller?.mouseMoved(e, in: self) }
    override func mouseDown(with e: NSEvent) { controller?.mouseButton(e, down: true) }
    override func mouseUp(with e: NSEvent) { controller?.mouseButton(e, down: false) }
    override func rightMouseDown(with e: NSEvent) { controller?.mouseButton(e, down: true) }
    override func rightMouseUp(with e: NSEvent) { controller?.mouseButton(e, down: false) }
    override func otherMouseDown(with e: NSEvent) { controller?.mouseButton(e, down: true) }
    override func otherMouseUp(with e: NSEvent) { controller?.mouseButton(e, down: false) }
    override func scrollWheel(with e: NSEvent) { controller?.scroll(e) }
}

/// Connecting, errors, the statistics and hints, drawn over the picture.
struct StreamOverlay: View {
    @ObservedObject var state: StreamWindowState
    var quit: () -> Void

    var body: some View {
        ZStack {
            if !state.connected {
                VStack(spacing: 14) {
                    if let error = state.error {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                        Text(error).multilineTextAlignment(.center).frame(maxWidth: 460)
                        Button("Close", action: quit).keyboardShortcut(.cancelAction)
                    } else {
                        ProgressView().controlSize(.large)
                        Text(state.stage).foregroundStyle(.secondary)
                        Button("Cancel", action: quit).keyboardShortcut(.cancelAction)
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            VStack {
                HStack(alignment: .top) {
                    if !state.statsText.isEmpty {
                        Text(state.statsText).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Spacer()
                    if state.poorConnection {
                        Label("Slow connection", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.white)
                            .padding(6).background(.orange.opacity(0.8), in: Capsule())
                    }
                }
                Spacer()
                if let hint = state.hint {
                    Text(hint).font(.callout).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.6), in: Capsule()).transition(.opacity)
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: state.hint)
    }
}

/// The overlay takes clicks only while it shows its Cancel/Close button; during the stream they reach the picture.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var passThrough: () -> Bool = { false }
    override func hitTest(_ point: NSPoint) -> NSView? { passThrough() ? nil : super.hitTest(point) }
}
