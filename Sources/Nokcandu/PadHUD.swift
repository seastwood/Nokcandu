import AppKit
import SwiftUI

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

    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(_ text: String, symbol: String) {
        guard Self.enabled else { return }
        let p = panel ?? make()
        panel = p
        let host = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
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
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(.black.opacity(0.72)))
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .padding(8)
            .fixedSize()
    }
}
