import SwiftUI

import AppKit
import ApplicationServices
import NokcanduCore

/// Foreground-process routing of mapped movement; never changes global cursor association.
@MainActor
final class PadCapture: ObservableObject {
    static let shared = PadCapture()
    private static let key = "padAppCaptureModesV1"
    @Published var modes: [String: String] = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(modes, forKey: Self.key); refresh() }
    }
    @Published var selectedPaths: [String: String] = UserDefaults.standard.dictionary(forKey: "padAppCapturePathsV1") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(selectedPaths, forKey: "padAppCapturePathsV1"); refresh() }
    }
    @Published private(set) var status = "Disabled"
    private var policy = PadCapturePolicy()
    private var anchor: CGPoint = .zero
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var timer: Timer?
    var releaseOutputs: (() -> Void)?
    private var suspended = false
    var targetPID: pid_t? { policy.targetPID }

    func start() {
        guard timer == nil else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if n.name == NSWorkspace.willSleepNotification || n.name == NSWorkspace.screensDidSleepNotification {
                        self.suspended = true; self.release()
                    } else if n.name == NSWorkspace.activeSpaceDidChangeNotification { self.release() }
                    self.refresh()
                }
            })
        }
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = false; self?.refresh() }
        })
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common); timer = t
        refresh()
    }

    private func refreshKeyboardMonitors() {
        let configured = modes.values.contains { $0 == "manual" || $0 == "automatic" }
        guard configured else {
            monitors.forEach(NSEvent.removeMonitor); monitors = []
            return
        }
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Bool = { [weak self] e in
            MainActor.assumeIsolated {
                guard !e.isARepeat, [53, 8].contains(e.keyCode),
                      e.modifierFlags.intersection([.control, .option, .command, .shift]) == [.control, .option] else { return false }
                if e.keyCode == 53 { self?.release() } else { self?.toggle() }; return true
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handler($0) }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0) ? nil : $0 }) { monitors.append(m) }
    }

    func refresh() {
        refreshKeyboardMonitors()
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier
        let mode = PadApplicationTarget.mode(bundleID: app?.bundleIdentifier, application: app?.bundleURL,
                                              modes: modes, selectedPaths: selectedPaths)
        let frame = mode == .disabled ? nil : pid.flatMap(window)
        let old = policy.targetPID
        policy.update(pid: pid, mode: mode, permitted: AXIsProcessTrusted() && !suspended, windowAvailable: frame != nil)
        if old != policy.targetPID { releaseOutputs?() }
        if let frame { anchor = CGPoint(x: frame.midX, y: frame.midY) }
        let next = policy.targetPID == nil ? (mode == .disabled ? "Disabled" : "Released or unavailable") : "Routing controller pointer to \(app?.localizedName ?? "selected app")"
        if status != next { status = next }
    }
    func toggle() {
        refresh()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        policy.toggleManual(pid: pid); refresh()
    }
    func release() {
        releaseOutputs?(); policy.release()
        status = "Released — Control–Option–Escape"
    }
    func stop() {
        release(); policy.reset(); timer?.invalidate(); timer = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }; observers = []
        monitors.forEach(NSEvent.removeMonitor); monitors = []
    }

    /// Verify focus and permissions for every output, not merely at polling boundaries.
    func point(for pid: pid_t) -> CGPoint? {
        guard policy.targetPID == pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              AXIsProcessTrusted(), !suspended else { return nil }
        return anchor
    }
    private func window(_ pid: pid_t) -> CGRect? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return rows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .filter { $0.width > 40 && $0.height > 40 }.max { $0.width * $0.height < $1.width * $1.height }
    }
}

struct PadCaptureSettings: View {
    @ObservedObject private var capture = PadCapture.shared
    var body: some View {
        Section("Controller pointer capture") {
            Text("Keep controller-generated aiming inside a selected app without moving the desktop pointer. Apps must accept injected relative events. Selecting a Nokcandu wrapper also covers its direct game helper apps. This does not capture your physical mouse.").font(.caption).foregroundStyle(.secondary)
            ForEach(capture.modes.keys.sorted(), id: \.self) { id in
                HStack {
                    Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                    Spacer()
                    Picker("Capture", selection: Binding(get: { capture.modes[id] ?? "disabled" }, set: { capture.modes[id] = $0 })) {
                        Text("Disabled").tag("disabled"); Text("Manual").tag("manual"); Text("Automatic").tag("automatic")
                    }.frame(width: 170)
                    Button { capture.modes[id] = nil; capture.selectedPaths[id] = nil } label: { Image(systemName: "minus.circle") }
                }
            }
            HStack {
                Button("Add an Application…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
                    if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { capture.selectedPaths[id] = url.path; if capture.modes[id] == nil { capture.modes[id] = "disabled" } }
                }
                Button("Release Capture") { capture.release() }
            }
            Text("Control–Option–Escape releases capture until you switch apps. Control–Option–C toggles capture for a configured foreground app. Manual capture releases when you change apps.").font(.caption).foregroundStyle(.secondary)
            Text(capture.status).font(.caption)
        }.onAppear { capture.start() }
    }
}
