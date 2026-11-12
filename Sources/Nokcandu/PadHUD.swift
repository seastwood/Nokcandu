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
        lastWasGyro = false
        let p = panel ?? make()
        panel = p
        let host = NSHostingView(rootView: HUDView(text: text, symbol: symbol, progress: progress))
        host.frame.size = host.fittingSize
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - host.fittingSize.width / 2, y: f.minY + 90))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.35; p?.animator().alphaValue = 0 }) { p?.orderOut(nil) }
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stay, execute: work)
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

private struct HUDView: View {
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
