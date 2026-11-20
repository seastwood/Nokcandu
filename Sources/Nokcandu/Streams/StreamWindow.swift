// SPDX-License-Identifier: GPL-3.0-only
// The stream's window: the host's picture, its sound, and this Mac's keyboard, mouse and controllers going back.
import AppKit
import Combine
import AVFoundation
import GameController
import NokcanduCore
import NokcanduStreamCore
import SwiftUI
import Charts

/// What the overlay shows.
@MainActor final class StreamWindowState: ObservableObject {
    @Published var stage = "Connecting…"
    @Published var connected = false
    @Published var error: String?
    @Published var poorConnection = false
    @Published var statistics: StreamProfile.Window.Statistics = .off
    @Published var graphs = false
    @Published var statsText = ""
    /// The part of `statsText` with this Mac's total, drawn in colour so it's easy to glance at.
    @Published var totalText = ""
    @Published var totalMs: Double?
    @Published var statsHistory = StreamTelemetryHistory()
    @Published var captured = false
    @Published var hint: String?
    /// Holding Esc to free the pointer: 0…1, shown from the first second on; nil when not held.
    @Published var escapeProgress: Double?
}

@MainActor final class StreamWindowController: NSWindowController, NSWindowDelegate, StreamConnectionDelegate, StreamPadRoute {
    let connection: StreamConnection
    let state = StreamWindowState()
    private(set) var gamepads: StreamGamepads
    let keyboard: StreamKeyboard
    /// The stream profile as it is now: settings changed during the stream that can apply, apply (see apply(_:)).
    private(set) var profile: StreamProfile
    /// The profile as it was when this stream started: what the host was asked for.
    let startProfile: StreamProfile
    private let identity: StreamIdentity
    private let streamView: StreamView
    private var statsTimer: Timer?
    private var displayLink: CADisplayLink?
    private var overlayView: NSView?
    private var overlayWatch: AnyCancellable?
    private let sessionActivity = StreamSessionActivity()
    private var ended = false
    /// Keeps this controller alive while its window still shows an error: StreamsModel lets go of it as soon as the
    /// stream ends, and the overlay's Close button (and the window's delegate) need it until the window closes.
    private var heldForError: StreamWindowController?
    private var vban: StreamVBANSender?
    private var vbanSettings: VBANSettings?

    /// Settings changed in the stream profile while the stream runs. Those the host fixes at the start (picture size,
    /// frame rate, bitrate, codec, HDR, colour, channels, sound on the host, the app, the route) wait for the next stream.
    func apply(_ next: StreamProfile) {
        let old = profile
        profile = next
        connection.video.pacing = next.video.pacing
        connection.video.frameBuffer = next.video.frameBuffer
        if next.video.renderer != old.video.renderer || next.video.vsync != old.video.vsync { applyRenderer() }
        connection.audio.volume = Float(next.audio.volume)
        connection.audio.outputDevice = next.audio.outputDevice
        keyboard.input = next.input
        if next.input.keyboardLayout != old.input.keyboardLayout || next.input.captureSystemShortcuts != old.input.captureSystemShortcuts
            || next.input.commandAsWindowsKey != old.input.commandAsWindowsKey { applyKeyboardLayout() }
        if next.window.statistics != old.window.statistics {
            state.statistics = next.window.statistics
            renderStats()
        }
        state.graphs = next.window.graphs
        if next.window.display != old.window.display, let target = StreamDisplays.screen(for: next.window.display) { move(to: target) }
        else if next.window.fullScreen != old.window.fullScreen { setFullScreen(next.window.fullScreen) }
        if next.input.mouse != old.input.mouse {
            if next.input.mouse == .capture { if window?.isKeyWindow == true { captureMouse() } } else { releaseMouse() }
        }
        if next.controller != old.controller, state.connected {
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

    var profileID: String? { gamepads.settings.profileID }
    @discardableResult func refreshControllerProfile(profiles: [PadProfiles.Profile]) -> Bool {
        guard state.connected, !ended else { return false }
        let next = StreamGamepads.routing(for: profile.controller, profiles: profiles)
        guard next != gamepads.routing else { return false }
        // Release the old profile's keyboard/mouse holds before replacing its controller output route.
        if DesktopPad.shared.stream === self { DesktopPad.shared.releaseStreamProfileOutputs() }
        gamepads.stop()
        gamepads = StreamGamepads(routing: next)
        gamepads.start()
        return true
    }
    var isFront: Bool { NSApp.isActive && window?.isKeyWindow == true && state.connected }

    init(host: StreamHost, profile: StreamProfile, address: String, identity: StreamIdentity) {
        connection = StreamConnection(host: host, profile: profile, address: address)
        self.profile = profile
        startProfile = profile
        gamepads = StreamGamepads(settings: profile.controller)
        keyboard = StreamKeyboard(input: profile.input)
        self.identity = identity
        streamView = StreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        let w = StreamNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(profile.name) — \(host.name)"
        w.collectionBehavior = [.fullScreenPrimary, .managed]
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.acceptsMouseMovedEvents = true
        super.init(window: w)
        state.statistics = profile.window.statistics
        state.graphs = profile.window.graphs
        w.delegate = self
        w.fullScreenRequested = { [weak self, weak w] in
            guard let self, let w, self.fillsPanel, !w.styleMask.contains(.fullScreen) else { return false }
            self.setFullScreen(self.covering == nil)
            return true
        }
        streamView.controller = self
        streamView.videoLayer = connection.video.layer
        let overlay = PassthroughHostingView(rootView: StreamOverlay(state: state, quit: { [weak self] in self?.endStream(quitApp: false) }))
        overlay.passThrough = { [weak self] in self?.state.connected ?? false }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        streamView.addSubview(overlay)
        overlayView = overlay
        // Nothing drawn over the picture while there's nothing to show, so macOS can send it straight to the
        // display instead of compositing it with the window (lower latency; Metal's V-sync off needs it).
        overlayWatch = state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateOverlayVisibility() } }
        applyRenderer()
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
        sessionActivity.start()
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

    /// Ends the stream; with `quitApp` the app on the host quits too. `completion` runs on the main thread once
    /// the host has been told (the connection is closed), for a caller that must wait for it: Nokcandu quitting.
    func endStream(quitApp: Bool, completion: (() -> Void)? = nil) {
        guard !ended else { window?.close(); completion?(); return }
        releaseMouse()
        // Let go of everything on the host first: keys still held (⌘Q arrives there as the Windows key going
        // down) and the controllers, or they stay pressed on the host after the stream is gone.
        keyboard.releaseAll()
        gamepads.stop()
        let c = connection, identity = self.identity
        DispatchQueue.global(qos: .userInitiated).async {
            usleep(120_000)                       // those releases are on their way before the connection closes
            if quitApp { c.stopAndQuit(identity: identity) } else { c.stop() }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
        finish(error: nil)
        window?.close()
    }

    private func finish(error: String?) {
        guard !ended else { return }
        if covering != nil { NSApp.presentationOptions = [] }
        ended = true
        sessionActivity.stop()
        statsTimer?.invalidate(); statsTimer = nil
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        if let m = pttMonitor { NSEvent.removeMonitor(m); pttMonitor = nil }
        displayLink?.invalidate(); displayLink = nil
        gamepads.stop()
        MacGameKeys.shared.streamFront(nil)
        StreamSystemShortcuts.capture(false)
        vban?.stop(); vban = nil
        releaseMouse()
        NSEvent.isMouseCoalescingEnabled = true
        if DesktopPad.shared.stream === self { DesktopPad.shared.stream = nil }
        if StreamConnection.current === connection { StreamConnection.current = nil }
        if error != nil, window?.isVisible == true { heldForError = self }
        onEnd?(error)
    }

    // MARK: StreamConnectionDelegate

    func streamStage(_ text: String) { state.stage = text }

    func streamStarted() {
        state.connected = true
        state.stage = ""
        // Use Everywhere may have changed while connecting to the host.
        gamepads = StreamGamepads(settings: profile.controller)
        gamepads.start()
        DesktopPad.shared.stream = self
        // Every mouse movement report, not the coalesced few per frame.
        NSEvent.isMouseCoalescingEnabled = false
        installEventMonitor()
        applyKeyboardLayout()
        applyVBAN(profile.audio.vban)
        window?.makeFirstResponder(streamView)
        let link = streamView.displayLink(target: self, selector: #selector(refresh(_:)))
        holdTopRefreshRate(link)
        link.add(to: .main, forMode: .common)
        displayLink = link
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateStats() } }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
        if profile.input.mouse == .capture, window?.isKeyWindow == true { captureMouse() }
        if profile.input.clipboard { sendClipboard(auto: true) }
        let hint = profile.input.mouse == .capture
            ? "Free the pointer: hold Esc for 5 seconds or press ⌃⌥⇧Z · End the stream: ⌃⌥⇧Q"
            : "End the stream: ⌃⌥⇧Q"
        state.hint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in if self?.state.hint == hint { self?.state.hint = nil } }
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
    func streamAdaptiveTriggers(controller: Int, flags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8]) {
        gamepads.adaptiveTriggers(controller, flags: flags, typeLeft: typeLeft, typeRight: typeRight, left: left, right: right)
    }
    func streamHDR(_ on: Bool) {
        StreamLog.shared.add("HDR \(on ? "on" : "off")")
        connection.video.layer.wantsExtendedDynamicRangeContent = on
        connection.video.setHDR(on)
    }

    @objc private func refresh(_ link: CADisplayLink) {
        connection.video.displayRefresh(timestamp: link.targetTimestamp, duration: link.targetTimestamp - link.timestamp)
    }

    /// Keeps a ProMotion display at its top refresh rate for the whole stream. Left alone, macOS lowers the rate to
    /// match the content (a game at 60 fps ran the panel at 60 Hz), and a frame then waits up to 16.7 ms for a
    /// refresh instead of 8.3 (measured November 19: ~9.7 ms decode → screen instead of ~5.3).
    private func holdTopRefreshRate(_ link: CADisplayLink) {
        let top = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: top, maximum: top, preferred: top)
        StreamLog.shared.add("Window: asking the display to stay at \(Int(top)) Hz")
    }

    // MARK: Renderer

    /// Shows the picture with the profile's renderer (and V-sync for Metal). Falls back to the display layer, with a
    /// message, when Metal isn't available or gives up during the stream.
    private func applyRenderer() {
        let r = connection.video.useRenderer(profile.video.renderer, vsync: profile.video.vsync) { [weak self] why in
            guard let self else { return }
            self.streamView.videoLayer = self.connection.video.layer
            self.flash("Metal couldn't show this stream (\(why)). Using the display layer.")
        }
        if streamView.videoLayer !== r.layer { streamView.videoLayer = r.layer }
        if let problem = r.problem { flash("Metal isn't available on this Mac (\(problem)). Using the display layer.") }
    }

    private func updateOverlayVisibility() {
        overlayView?.isHidden = state.connected && state.error == nil && state.statsText.isEmpty && !state.graphs
            && state.hint == nil && !state.poorConnection && state.escapeProgress == nil
    }

    private var statsTicks = 0
    private var latestStats = StreamTelemetry.Sample()
    private func updateStats() {
        var rtt: UInt32 = 0, variation: UInt32 = 0
        let hasNetwork = LiGetEstimatedRttInfo(&rtt, &variation)
        let v = connection.video.stats.telemetry.roll(at: CACurrentMediaTime(),
            networkMs: hasNetwork ? Double(rtt) : nil, variationMs: hasNetwork ? Double(variation) : nil)
        latestStats = v
        state.statsHistory.append(v)
        statsTicks += 1
        if statsTicks % 5 == 0 {
            StreamLog.shared.add(String(format: "Video stats: received %.0f fps, enqueued %.0f fps, decode avg/max %@/%@ ms, host %@ ms, RTT %@ ms (variation %@); %.1f Mbps; drops %d network, %d decode, %d pacing; max arrival/display/enqueue gaps %@/%@/%@ ms; presentation wait avg/max %@/%@ ms; decode→screen avg/max %@/%@ ms%@, this Mac (first packet→screen) avg/max %@/%@ ms; %@; sample %.2f s; stream activity active",
                v.receivedFPS, v.shownFPS, Self.ms(v.decodeMs), Self.ms(v.decodeMaxMs), Self.ms(v.hostMs), Self.ms(v.networkMs), Self.ms(v.networkVariationMs),
                v.bitrateMbps, v.networkDropped, v.dropped, v.pacedDrops, Self.ms(v.arrivalGapMaxMs), Self.ms(v.displayGapMaxMs), Self.ms(v.enqueueGapMaxMs), Self.ms(v.presentationMs), Self.ms(v.presentationMaxMs),
                Self.ms(v.screenMs), Self.ms(v.screenMaxMs), v.screenMeasured ? " measured" : " estimated", Self.ms(v.clientMs), Self.ms(v.clientMaxMs),
                Self.rendererName(profile.video, metal: connection.video.metalRenderer != nil), v.duration))
            StreamLog.shared.add("Video stats, \(Self.wholeLines(v.whole).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · "))")
        }
        renderStats()
    }
    /// The whole stream so far: averages, and the time 99% of frames stayed under (two lines, to keep the panel narrow).
    private static func wholeLines(_ w: StreamTelemetry.Whole) -> [String] {
        let t = Int(w.seconds), clock = t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
        return ["Stream average (\(clock)): \(w.shownFPS.map { String(format: "%.1f", $0) } ?? "N/A") fps · this Mac \(ms(w.clientMs)) ms (99% under \(ms(w.clientP99Ms)))",
                "    decode → screen \(ms(w.screenMs)) · decode \(ms(w.decodeMs)) · RTT \(ms(w.networkMs)) ms"]
    }
    private static func rendererName(_ v: StreamProfile.Video, metal: Bool) -> String {
        metal ? "Metal, V-sync \(v.vsync ? "on" : "off")" : "AVSampleBufferDisplayLayer"
    }
    private static func ms(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "N/A" }
    private func renderStats() {
        guard state.statistics != .off else { state.statsText = ""; state.totalText = ""; return }
        let v = latestStats, video = connection.video
        state.totalMs = v.clientMs
        if state.statistics == .minimal {
            // Just "frames shown per second/this Mac's total in ms", the total coloured.
            state.totalText = v.clientMs.map { String(format: "%.1f", $0) } ?? "–"
            state.statsText = "\(Int(v.shownFPS.rounded()))/\(state.totalText)"
            return
        }
        state.totalText = "this Mac total \(Self.ms(v.clientMs)) ms"
        var lines = [String(format: "%d×%d  %@ (%@ range)  %.1f fps enqueued", video.width, video.height,
            StreamConnection.formatName(connection.negotiatedFormat), startProfile.video.fullRange ? "full" : "limited", v.shownFPS) + " · " + Self.rendererName(profile.video, metal: video.metalRenderer != nil)]
        lines.append("Network RTT \(Self.ms(v.networkMs)) ms (variation \(Self.ms(v.networkVariationMs)))  Decode \(Self.ms(v.decodeMs)) ms")
        lines.append("Decode → screen \(Self.ms(v.screenMs)) ms\(v.screenMeasured || v.screenMs == nil ? "" : " (estimated)") · \(state.totalText)")
        lines.append(contentsOf: Self.wholeLines(v.whole))
        if state.statistics == .detailed {
            lines.append(String(format: "Video payload %.1f Mbps · peak %.1f · buffered %.1f frames", v.bitrateMbps, v.peakBitrateMbps, v.bufferedFrames))
            lines.append("Host min/avg/max \(Self.ms(v.hostMinMs))/\(Self.ms(v.hostMs))/\(Self.ms(v.hostMaxMs)) ms")
            lines.append("Decode min/avg/max \(Self.ms(v.decodeMinMs))/\(Self.ms(v.decodeMs))/\(Self.ms(v.decodeMaxMs)) ms")
            lines.append("Pacing \(profile.video.pacing.title) · display \(window?.screen?.maximumFramesPerSecond ?? 0) Hz · decode → screen max \(Self.ms(v.screenMaxMs)) · this Mac max \(Self.ms(v.clientMaxMs)) ms")
            if let host = v.hostMs, let rtt = v.networkMs, let client = v.clientMs {
                lines.append(String(format: "Estimated total (host + half the RTT + this Mac) %.1f ms", host + rtt / 2 + client))
            }
            lines.append(String(format: "Received/decoded %.1f/%.1f fps · core queue %d frames · audio %.0f ms", v.receivedFPS, v.decodedFPS, LiGetPendingVideoFrames(), connection.audio.queuedMs))
            lines.append("Frame assembly \(Self.ms(v.assemblyMs)) · decoder queue \(Self.ms(v.queueMs)) · presentation wait \(Self.ms(v.presentationMs)) ms")
            lines.append("Drops since start: network/pacing \(Self.ms(v.networkDropPercent))%/\(Self.ms(v.pacingDropPercent))% (\(v.networkDropped)/\(v.pacedDrops)) · decode \(v.dropped)")
            lines.append("Max arrival/display/enqueue gap \(Self.ms(v.arrivalGapMaxMs))/\(Self.ms(v.displayGapMaxMs))/\(Self.ms(v.enqueueGapMaxMs)) ms")
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
        stopEscapeHold()
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
        // With ⌘ kept on the Mac its shortcuts must keep working, so the Mac's shortcuts stay on too.
        StreamSystemShortcuts.capture(front && profile.input.captureSystemShortcuts && profile.input.commandAsWindowsKey)
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
        if covering != nil { uncover(); place(on: screen); cover(); return }
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
        connection.video.metalRenderer?.setDisplayColorSpace(s.colorSpace?.cgColorSpace)
        if let link = displayLink { holdTopRefreshRate(link) }
        // The host fixed the picture size at the start; say so when it no longer matches this display.
        let px = StreamDisplays.pixels(s, fullScreen: fillsPanel ? false : profile.window.fullScreen)
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
    /// Full screen now, either way (macOS's full screen, or the whole panel for a notch-area resolution).
    private var isFullScreenNow: Bool { covering != nil || window?.styleMask.contains(.fullScreen) == true }

    func setFullScreen(_ on: Bool) {
        // A picture with the whole panel's shape: leave macOS's full screen first if it's on, then cover the panel.
        if on, fillsPanel {
            if window?.styleMask.contains(.fullScreen) == true { coverAfterExit = true; setNativeFullScreen(false) } else { cover() }
            return
        }
        uncover()
        setNativeFullScreen(on)
    }

    // MARK: The whole panel (notch-area resolutions)

    /// The chosen size has the whole panel's shape (beside the camera too) on the display the stream plays on.
    private var fillsPanel: Bool {
        guard let s = window?.screen ?? StreamDisplays.screen(for: profile.window.display) ?? NSScreen.main else { return false }
        return StreamDisplays.fillsPanel(s, width: profile.video.width, height: profile.video.height)
    }

    /// The window's frame and style before covering the panel; set while covering.
    private var covering: (frame: NSRect, style: NSWindow.StyleMask)?
    private var coverAfterExit = false

    /// A borderless window over the whole screen, beside the camera housing too, with the menu bar and Dock hidden:
    /// macOS's own full screen keeps windows below the housing. Measured higher latency than macOS's full screen
    /// (~13.7 vs ~5.7 ms, November 19), which is why it's only used for the notch-area resolutions.
    private func cover() {
        guard let w = window, covering == nil, !ended, let s = w.screen ?? NSScreen.main else { return }
        covering = (w.frame, w.styleMask)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        w.styleMask = [.borderless]
        w.setFrame(s.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        StreamLog.shared.add("Window: covering the whole panel, notch area included (\(Int(s.frame.width))×\(Int(s.frame.height)) pt) on \(s.localizedName)")
    }

    private func uncover() {
        guard let c = covering, let w = window else { return }
        covering = nil
        NSApp.presentationOptions = []
        w.styleMask = c.style
        w.setFrame(c.frame, display: true)
        StreamLog.shared.add("Window: no longer covering the panel")
    }

    private func setNativeFullScreen(_ on: Bool) {
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
            if let s = w as? StreamNSWindow { s.toggleNativeFullScreen() } else { w.toggleFullScreen(nil) }
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
        if coverAfterExit, window?.styleMask.contains(.fullScreen) == false { coverAfterExit = false; cover() }
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
        StreamSystemShortcuts.capture(false)
        if state.connected, profile.input.clipboard { fetchClipboard(auto: true) }
        releaseMouse()
        keyboard.releaseAll()
        DesktopPad.shared.evaluate(force: true)
    }
    func windowWillClose(_ notification: Notification) {
        if covering != nil { covering = nil; NSApp.presentationOptions = [] }
        if !ended { endStream(quitApp: false) }
        // Let go after this call returns, not from inside it.
        if let held = heldForError { heldForError = nil; DispatchQueue.main.async { _ = held } }
    }

    // MARK: Clipboard (Apollo hosts)

    private func clipboardClient() -> StreamClient {
        let h = connection.host
        return StreamClient(address: connection.address, httpPort: h.httpPort, httpsPort: h.httpsPort, identity: identity,
                            serverCertificate: h.serverCertificate.flatMap { Data(base64Encoded: $0) },
                                  sunshine: h.capabilities.isSunshine)
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

    /// ⌃⌥⇧K (Moonlight PC's keyboard-grab combo): sends the Mac's own shortcuts (⌘Tab, ⌘Space, Mission Control…)
    /// to the host, or gives them back to the Mac, for this stream. Applies at once; the saved setting is unchanged.
    func toggleSystemShortcuts() {
        guard profile.input.commandAsWindowsKey else { flash("⌘ stays on the Mac for this stream, so its shortcuts do too."); return }
        profile.input.captureSystemShortcuts.toggle()
        applyKeyboardLayout()
        flash(profile.input.captureSystemShortcuts ? "Mac shortcuts go to the host" : "Mac shortcuts stay on the Mac")
    }

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
            watchEscape(e, down: down)
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
            renderStats()
        case "x": setFullScreen(!isFullScreenNow)
        case "d": uncover(); window?.miniaturize(nil)
        case "m": toggleMicMute()
        case "k": toggleSystemShortcuts()
        default: return false
        }
        return true
    }

    /// Holding Esc for `escapeHold` seconds frees a captured pointer (Esc still reaches the host meanwhile: a short
    /// press can't be told from a long one until the time is up).
    private var escapeTimer: Timer?
    static let escapeHold = 5.0, escapeShowAfter = 1.0

    private func stopEscapeHold() {
        escapeTimer?.invalidate(); escapeTimer = nil
        if state.escapeProgress != nil { state.escapeProgress = nil }
    }

    private func watchEscape(_ e: NSEvent, down: Bool) {
        guard e.keyCode == 0x35, !e.isARepeat else { return }
        stopEscapeHold()
        guard down, state.captured else { return }
        let started = CACurrentMediaTime()
        // A bar fills from the first second, so a normal press of Esc shows nothing.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = CACurrentMediaTime() - started
                guard self.state.captured else { self.stopEscapeHold(); return }
                if held >= Self.escapeHold {
                    self.stopEscapeHold()
                    self.releaseMouse()
                    self.flash("Pointer freed. Click the stream to capture it again.")
                } else if held >= Self.escapeShowAfter {
                    self.state.escapeProgress = held / Self.escapeHold
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        escapeTimer = t
    }

    func keyEvent(_ e: NSEvent, down: Bool) {
        guard state.connected else { return }
        if down, handleShortcut(e) { return }
        watchEscape(e, down: down)
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

    var otherControllersAsPlayers: Bool { gamepads.othersAsPlayers }
    func rearmOtherPlayers() { gamepads.rearm() }
    func padButton(_ b: Int, _ down: Bool) { gamepads.profileButton(b, down) }
    func padAxis(_ a: Int, _ v: Int) { gamepads.profileAxis(a, v) }
    func key(_ mac: Int, _ down: Bool) { keyboard.profileKey(mac, down) }
    func mouseButton(_ b: Int, _ down: Bool) {
        LiSendMouseButtonEvent(CChar(down ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), StreamMouseButtons.from(engine: b))
    }
    func absoluteMouse(_ point: CGPoint) {
        guard state.connected, point.x.isFinite, point.y.isFinite else { return }
        LiSendMousePositionEvent(Int16(max(0,min(1,point.x))*4096),Int16(max(0,min(1,point.y))*4096),4096,4096)
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
    /// The display layer or the Metal renderer's layer, below the overlay.
    var videoLayer: CALayer? {
        didSet {
            guard oldValue !== videoLayer else { return }
            oldValue?.removeFromSuperlayer()
            if let v = videoLayer { layer?.insertSublayer(v, at: 0); needsLayout = true; layoutVideo() }
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
        layoutVideo()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); layoutVideo() }

    /// Points at the top kept clear of the picture (none today; kept for a window that covers a notch).
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { layoutVideo() } } }
    /// Where the picture may go: the view below `topInset`.
    var pictureArea: CGRect { CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(1, bounds.height - topInset)) }

    private func layoutVideo() {
        if let m = controller?.connection.video.metalRenderer, m.layer === videoLayer {
            // The Metal layer fills the view (so it can fill the screen); the picture is placed below the inset.
            m.resize(bounds, scale: window?.backingScaleFactor ?? layer?.contentsScale ?? 2, topInset: topInset)
            m.setDisplayColorSpace(window?.screen?.colorSpace?.cgColorSpace)
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer?.frame = pictureArea
        CATransaction.commit()
    }

    /// Where the picture is inside the view (letterboxed to the stream's shape).
    var videoRect: CGRect {
        guard let c = controller, c.connection.video.width > 0 else { return bounds }
        return AVMakeRect(aspectRatio: CGSize(width: c.connection.video.width, height: c.connection.video.height), insideRect: pictureArea)
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
                    if state.connected && (!state.statsText.isEmpty || state.graphs) {
                        VStack(alignment: .leading, spacing: 3) {
                            if !state.statsText.isEmpty {
                                Text(StreamTotalLatency.highlight(state.statsText, state.totalText, ms: state.totalMs)).font(.system(size: 9, design: .monospaced)).lineSpacing(0).foregroundStyle(.white)
                            }
                            if state.graphs { StreamStatsGraphs(samples: state.statsHistory.samples) }
                        }
                        .padding(5).background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    if state.poorConnection {
                        Label("Slow connection", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.white)
                            .padding(6).background(.orange.opacity(0.8), in: Capsule())
                    }
                }
                Spacer()
                if let p = state.escapeProgress {
                    VStack(spacing: 6) {
                        Text("Keep holding Esc to free the pointer").font(.callout).foregroundStyle(.white)
                        ProgressView(value: min(1, p)).progressViewStyle(.linear).tint(.white).frame(width: 220)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
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

/// Two minutes of one-second aggregates, independent of per-frame rendering and input.
private struct StreamStatsGraphs: View {
    let samples: [StreamTelemetry.Sample]
    private var domain: ClosedRange<Double> {
        let end = samples.last?.time ?? 120
        return (end - 119)...end
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Network RTT and RTT variation · ms").font(.system(size: 9))
            Chart(samples) { s in
                if let y = s.networkMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "RTT")) }
                if let y = s.networkVariationMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "RTT variation")) }
            }
            .chartXScale(domain: domain).chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis(.hidden).frame(height: 50)
            Text("Decode, presentation wait and decode → screen · ms").font(.system(size: 9))
            Chart(samples) { s in
                if let y = s.decodeMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "Decode avg")) }
                if let y = s.decodeMaxMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "Decode max")) }
                if let y = s.presentationMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "Presentation wait")) }
                if let y = s.screenMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "Decode → screen")) }
            }
            .chartXScale(domain: domain).chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis(.hidden).frame(height: 50)
            Text("Largest arrival / display / enqueue gap · ms").font(.system(size: 9))
            Chart(samples) { s in
                if let y = s.arrivalGapMaxMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "Frame arrival")) }
                if let y = s.displayGapMaxMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "Display callback")) }
                if let y = s.enqueueGapMaxMs { LineMark(x: .value("Time", s.time), y: .value("ms", y)).foregroundStyle(by: .value("Signal", "Layer enqueue")) }
            }
            .chartXScale(domain: domain).chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis(.hidden).frame(height: 50)
            Text("Last 120 seconds · one-second samples · missing data stays N/A. RTT variation is a transport estimate; frame gaps also grow on a still desktop. Network drops are inferred from frame-number gaps.")
                .font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(width: 340).font(.system(size: 9)).foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
}

/// The overlay takes clicks only while it shows its Cancel/Close button; during the stream they reach the picture.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var passThrough: () -> Bool = { false }
    override func hitTest(_ point: NSPoint) -> NSView? { passThrough() ? nil : super.hitTest(point) }
}

/// This Mac's total in the statistics text, coloured by how good it is: green under 12 ms, yellow under 20, orange above.
enum StreamTotalLatency {
    static func highlight(_ text: String, _ total: String, ms: Double?) -> AttributedString {
        var a = AttributedString(text)
        guard !total.isEmpty, let ms, let r = a.range(of: total) else { return a }
        a[r].foregroundColor = ms < 12 ? .green : ms < 20 ? .yellow : .orange
        return a
    }
}

/// The stream's window. Borderless while covering the whole panel, and a borderless window can't take the keyboard
/// unless it says so.
final class StreamNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// The green button and View ▸ Enter Full Screen: the stream decides first (a picture with the whole panel's
    /// shape covers the screen beside the camera instead of using macOS's full screen, which stops below it).
    var fullScreenRequested: (() -> Bool)?
    override func toggleFullScreen(_ sender: Any?) {
        if fullScreenRequested?() == true { return }
        super.toggleFullScreen(sender)
    }
    /// macOS's own full screen, for the stream's own use.
    func toggleNativeFullScreen() { super.toggleFullScreen(nil) }
}
