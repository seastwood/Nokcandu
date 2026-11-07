import AppKit
import GameController
import ApplicationServices
import NokcanduCore
import NokcanduPadEngine

/// A controller profile on the Mac itself: the controller works the pointer, clicks and keys in any app, with a
/// profile per app if you like. It steps aside while a Nokcandu game that has a profile of its own is in front
/// (that game's profile applies inside it), and while an app set to "Off" is in front. Keys and mouse go to macOS
/// like a real keyboard and mouse (needs Accessibility permission); controller-button outputs don't apply here.
@MainActor
final class DesktopPad: ObservableObject {
    static let shared = DesktopPad()

    static let onKey = "desktopPadOn", profileKey = "desktopPadProfile", rulesKey = "desktopPadApps"
    @Published var on: Bool = UserDefaults.standard.bool(forKey: onKey) { didSet { UserDefaults.standard.set(on, forKey: Self.onKey); evaluate() } }
    @Published var profileID: String? = UserDefaults.standard.string(forKey: profileKey) { didSet { UserDefaults.standard.set(profileID, forKey: Self.profileKey); evaluate(force: true) } }
    /// App bundle id → profile id, or "off".
    @Published var rules: [String: String] = (UserDefaults.standard.dictionary(forKey: rulesKey) as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(rules, forKey: Self.rulesKey); evaluate(force: true) }
    }
    /// What's happening now, for the menu and Settings.
    @Published private(set) var status = "Off"
    @Published private(set) var trusted = AXIsProcessTrusted()

    private var engine: OpaquePointer?
    private var compiled = ""
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastButtons: [Int: Bool] = [:], lastAxes: [Int: Int] = [:]
    private var flags: CGEventFlags = []
    private var buttonsDown = Set<Int>()
    private var started = false
    /// A Nokcandu game in front whose own profile is running inside it (its process wrote pad-active).
    static func gameUsesOwnProfile(_ app: NSRunningApplication?) -> Bool {
        guard let app, let url = app.bundleURL?.resolvingSymlinksInPath() else { return false }
        let path = url.path
        let host: String
        if let r = path.range(of: "/Contents/SharedSupport/GameApp/") { host = String(path[..<r.lowerBound]) + "/Contents" }
        else { host = path + "/Contents" }
        guard let text = try? String(contentsOfFile: host + "/SharedSupport/nokcandu/pad-active", encoding: .utf8),
              let pid = Int32(text.split(separator: "\n").first ?? "") else { return false }
        return pid > 0 && pid == app.processIdentifier
    }

    func start() {
        guard !started else { return }
        started = true
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DesktopPad.shared.attach() } })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DesktopPad.shared.attach() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopPad.shared.evaluate() }
            // A game says it uses its own profile a moment after it comes to the front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { DesktopPad.shared.evaluate() }
        })
        observers.append(nc.addObserver(forName: .padProfilesChanged, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DesktopPad.shared.evaluate(force: true) } })
        attach()
        evaluate()
    }

    func askForAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Picks the profile for the app in front (or none) and (re)builds the engine when it changes.
    func evaluate(force: Bool = false) {
        trusted = AXIsProcessTrusted()
        let front = NSWorkspace.shared.frontmostApplication
        let id = front?.bundleIdentifier ?? ""
        var chosen: PadProfiles.Profile?
        let all = PadProfiles.profiles()
        if !on { status = "Off" }
        else if Self.gameUsesOwnProfile(front) { status = "Paused: \(front?.localizedName ?? "the game") uses its own profile" }
        else if let rule = rules[id], rule == "off" { status = "Paused for \(front?.localizedName ?? "this app")" }
        else if let p = (rules[id].flatMap { r in all.first { $0.id == r } }) ?? profileID.flatMap({ pid in all.first { $0.id == pid } }) {
            chosen = p
            status = "On: \(p.name)" + (rules[id] != nil ? " (for \(front?.localizedName ?? "this app"))" : "")
        } else { status = "On, but no profile chosen" }
        if on && chosen != nil && !trusted { status = "Needs Accessibility permission" }
        let text = (chosen != nil && trusted) ? PadProfiles.compile(chosen!, all: all) : ""
        if text == compiled && !force { return }
        compiled = text
        rebuild()
    }

    private func rebuild() {
        if let e = engine { pe_release_all(e, Self.now()); pe_destroy(e) }
        engine = nil
        timer?.invalidate(); timer = nil
        lastButtons = [:]; lastAxes = [:]
        guard !compiled.isEmpty else { return }
        var sink = pe_sink()
        sink.pad_button = { _, _, _ in }          // the real controller is still there for the app
        sink.pad_axis = { _, _, _ in }
        sink.key = { _, k, d in MainActor.assumeIsolated { DesktopPad.shared.key(Int(k), d) } }
        sink.mouse_button = { _, b, d in MainActor.assumeIsolated { DesktopPad.shared.mouse(Int(b), d) } }
        sink.mouse_move = { _, x, y in MainActor.assumeIsolated { DesktopPad.shared.move(Int(x), Int(y)) } }
        sink.wheel = { _, n in MainActor.assumeIsolated { DesktopPad.shared.wheel(Int(n)) } }
        engine = compiled.withCString { pe_create($0, sink) }
        let t = Timer(timeInterval: 0.002, repeats: true) { _ in MainActor.assumeIsolated { DesktopPad.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        attach()
    }

    private func tick() { if let e = engine { pe_tick(e, Self.now()) } }
    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// The profile editor's live test reads the controller while it's open; the Mac profile waits until it closes.
    static var testerOpen = false

    func attach() {
        guard !Self.testerOpen else { return }
        for c in GCController.controllers() {
            guard let gp = c.extendedGamepad else { continue }
            gp.valueChangedHandler = { pad, _ in MainActor.assumeIsolated { DesktopPad.shared.read(pad) } }
            if let m = c.motion {
                if m.sensorsRequireManualActivation { m.sensorsActive = true }
                m.valueChangedHandler = { motion in
                    let r = motion.rotationRate
                    MainActor.assumeIsolated { if let e = DesktopPad.shared.engine { pe_gyro(e, Float(r.x), Float(r.y), Float(r.z), DesktopPad.now()) } }
                }
            }
        }
    }

    private func read(_ g: GCExtendedGamepad) {
        guard let e = engine else { return }
        let (buttons, axes) = PadGC.state(g)
        let now = Self.now()
        for (i, down) in buttons {
            let n = Int(pe_input_named(i.rawValue))
            if lastButtons[n] != down { lastButtons[n] = down; pe_button(e, Int32(n), down, now) }
        }
        for (a, v) in axes {
            let iv = Int(max(-32768, min(32767, v * 32767)))
            if lastAxes[Int(a)] != iv { lastAxes[Int(a)] = iv; pe_axis(e, a, Int32(iv), now) }
        }
    }

    // MARK: Keys and mouse to macOS

    private func flag(for k: Int) -> CGEventFlags {
        switch k {
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 55, 54: return .maskCommand
        case 63: return .maskSecondaryFn
        default: return []
        }
    }
    private func key(_ k: Int, _ down: Bool) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(k), keyDown: down) else { return }
        let f = flag(for: k)
        if !f.isEmpty { if down { flags.insert(f) } else { flags.remove(f) }; ev.type = .flagsChanged }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }
    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }
    private func mouse(_ b: Int, _ down: Bool) {
        if down { buttonsDown.insert(b) } else { buttonsDown.remove(b) }
        let type: CGEventType = b == 0 ? (down ? .leftMouseDown : .leftMouseUp) : b == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
        let button: CGMouseButton = b == 0 ? .left : b == 1 ? .right : CGMouseButton(rawValue: UInt32(b == 2 ? 2 : b == 3 ? 3 : 4)) ?? .center
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: button) else { return }
        ev.flags = flags
        if b > 1 { ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b)) }
        ev.post(tap: .cghidEventTap)
    }
    private func move(_ dx: Int, _ dy: Int) {
        var p = cursor
        p.x += CGFloat(dx); p.y += CGFloat(dy)
        let bounds = NSScreen.screens.reduce(CGRect.null) { r, s in
            let f = s.frame, top = NSScreen.screens.first?.frame.maxY ?? f.maxY
            return r.union(CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height))
        }
        p.x = min(max(p.x, bounds.minX), bounds.maxX - 1); p.y = min(max(p.y, bounds.minY), bounds.maxY - 1)
        let type: CGEventType = buttonsDown.contains(0) ? .leftMouseDragged : buttonsDown.contains(1) ? .rightMouseDragged : .mouseMoved
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: buttonsDown.contains(1) ? .right : .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }
    private func wheel(_ n: Int) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(n), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}
