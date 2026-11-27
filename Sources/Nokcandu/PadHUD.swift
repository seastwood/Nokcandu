import AppKit
import SwiftUI
import NokcanduCore

/// A small note near the bottom of the screen when a controller layer or the gyro switches — over any app,
/// full-screen games included. It never takes clicks or the keyboard, and fades after a moment.
@MainActor
final class PadHUD {
    static let shared = PadHUD()
    static let key = "padHUDOff"
    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(!newValue, forKey: key) }
    }

    static var automaticCalibration: Bool {
        get { UserDefaults.standard.object(forKey: "padAutomaticCalibrationNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "padAutomaticCalibrationNotifications") }
    }
    static var gyroSwitches: Bool {
        get { PadNotificationPreferences.gyroSwitches() }
        set {
            PadNotificationPreferences.setGyroSwitches(newValue)
            if !newValue && shared.lastWasGyro { shared.hide?.cancel(); shared.panel?.orderOut(nil) }
        }
    }

    private var panel: NSPanel?
    private var host: NSHostingView<HUDView>?
    private var shownShape = ""
    private var hide: DispatchWorkItem?
    private var lastWasGyro = false
    func gyroChanged(_ on: Bool) {
        guard PadNotificationPreferences.shouldShowGyro() else { return }
        show(on ? "Gyro on" : "Gyro off", symbol: "gyroscope")
        lastWasGyro = true
    }

    /// Gyro calibration: a bar while it measures, then "Gyro calibrated" (or "Hold still…" when it was moved).
    func calibration(_ progress: Float, manual: Bool = false) {
        guard manual || Self.automaticCalibration else { return }
        if progress >= 1 { show("Gyro calibrated", symbol: "checkmark.circle", force: manual) }
        else if progress < 0 { show("Keep it still — starting over", symbol: "gyroscope", progress: 0, stay: 2.5, force: manual) }
        else { show("Calibrating the gyro…", symbol: "gyroscope", progress: Double(progress), stay: 2.5, force: manual) }
    }

    func show(_ text: String, symbol: String, progress: Double? = nil, stay: Double = 1.2, force: Bool = false) {
        guard force || Self.enabled else { return }
        // Over a full-screen stream the note is drawn into the stream's frames (like the controller overlay and the
        // statistics): no window over the stream, so nothing is composited and no delay is added.
        if showInStream(text, symbol: symbol, progress: progress, stay: stay) { return }
        // Over a game or stream, a note makes macOS compose the screen again (more delay): held, unless asked for.
        guard force || !(DesktopPad.shared.playing && PadNotificationPreferences.holdWhilePlaying()) else { return }
        lastWasGyro = false
        let p = panel ?? make()
        panel = p
        // A calibration bar updates twenty times in a second and a half, sometimes behind a game: only the
        // bar's value changes then, so the note is not rebuilt, measured, moved and re-ordered each time.
        let shape = text + "\u{1}" + symbol + (progress == nil ? "" : "\u{1}bar")
        let view = HUDView(text: text, symbol: symbol, progress: progress)
        if let host, shape == shownShape, p.isVisible, p.alphaValue == 1 {
            host.rootView = view
        } else {
            let h = host ?? NSHostingView(rootView: view)
            h.rootView = view
            if host == nil { host = h; p.contentView = h }
            shownShape = shape
            let size = h.fittingSize
            h.frame.size = size
            p.setContentSize(size)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 90))
            }
            p.alphaValue = 1
            p.orderFrontRegardless()
        }
        hide?.cancel()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.35; p?.animator().alphaValue = 0 }) { p?.orderOut(nil) }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stay, execute: work)
    }

    // MARK: Inside a full-screen stream

    private let streamImage = StreamImageDrawer()
    private weak var streamRenderer: StreamMetalRenderer?
    private var streamShown = "", streamSize = CGSize.zero, streamFade: Timer?, streamOpacity = 1.0

    /// The Metal renderer of a stream shown full screen, if there is one.
    private func fullScreenStream() -> (StreamMetalRenderer, NSScreen)? {
        guard let s = DesktopPad.shared.stream as? StreamWindowController, let w = s.window, w.isVisible, let screen = w.screen,
              w.styleMask.contains(.fullScreen) || w.frame.equalTo(screen.frame),
              let r = s.connection.video.metalRenderer else { return nil }
        return (r, screen)
    }

    private func showInStream(_ text: String, symbol: String, progress: Double?, stay: Double) -> Bool {
        guard let (r, screen) = fullScreenStream() else { leaveStream(); return false }
        panel?.orderOut(nil)
        if streamRenderer !== r {
            leaveStream()
            streamImage.use(r.metalDevice)
            let img = streamImage
            r.setOverlay({ enc, target in img.draw(enc, target) }, key: "notes")
            streamRenderer = r
        }
        // Drawn only when the note changes (a calibration bar: when its value does), never in a frame.
        let key = "\(text)|\(symbol)|\(progress.map { String(Int($0 * 100)) } ?? "")"
        if key != streamShown {
            let renderer = ImageRenderer(content: HUDView(text: text, symbol: symbol, progress: progress))
            renderer.scale = screen.backingScaleFactor
            if let image = renderer.cgImage {
                streamImage.set(image, device: r.metalDevice)
                streamSize = CGSize(width: CGFloat(image.width) / renderer.scale, height: CGFloat(image.height) / renderer.scale)
                streamShown = key
            }
        }
        // Where the window would be: centred, 90 points above the bottom (points from the screen's top left).
        let f = screen.frame
        let rect = CGRect(x: (f.width - streamSize.width) / 2, y: f.height - 90 - streamSize.height, width: streamSize.width, height: streamSize.height)
        streamFade?.invalidate(); streamOpacity = 1
        streamImage.place(rect, screenWidth: f.width, opacity: 1)
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeInStream() }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stay, execute: work)
        return true
    }

    /// Fades by its opacity alone (the picture isn't drawn again), then takes it off the frames.
    private func fadeInStream() {
        streamFade?.invalidate()
        let start = CACurrentMediaTime()
        streamFade = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let r = self.streamRenderer, let screen = self.fullScreenStream()?.1 else { t.invalidate(); self?.leaveStream(); return }
                _ = r
                let k = min(1, (CACurrentMediaTime() - start) / 0.35)
                self.streamOpacity = 1 - k
                let f = screen.frame
                self.streamImage.place(CGRect(x: (f.width - self.streamSize.width) / 2, y: f.height - 90 - self.streamSize.height,
                                              width: self.streamSize.width, height: self.streamSize.height), screenWidth: f.width, opacity: self.streamOpacity)
                if k >= 1 { t.invalidate(); self.streamImage.set(nil, device: nil); self.streamShown = "" }
            }
        }
    }

    private func leaveStream() {
        streamFade?.invalidate(); streamFade = nil
        streamRenderer?.setOverlay(nil, key: "notes"); streamRenderer = nil
        streamImage.set(nil, device: nil); streamShown = ""
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .screenSaver                      // above full-screen games
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        return p
    }
}

struct HUDView: View {
    let text: String
    let symbol: String
    var progress: Double? = nil
    var body: some View {
        VStack(spacing: 6) {
            Label(text, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            if let progress {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: max(4, 180 * progress))
                }
                .frame(width: 180, height: 5)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: progress == nil ? 22 : 16).fill(.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: progress == nil ? 22 : 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .padding(8)
        .fixedSize()
    }
}
