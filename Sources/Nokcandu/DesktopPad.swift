import AppKit
import GameController
import ApplicationServices
import NokcanduCore
import NokcanduPadEngine

/// Nokcandu's controller remapping. Whatever app is in front gets its profile: a Nokcandu game uses the profile
/// chosen on its page ("Controller as it is" leaves the controller alone), any other app uses its own choice
/// (Settings), and everything else the Mac profile when that's on. Keys and clicks go to macOS like a real
/// keyboard and mouse (Accessibility permission); a Nokcandu game's mouse movement goes straight into the game,
/// the same way raw mouse capture works, so aiming stays exact. Controller-button outputs don't apply here (the
/// game sees the real controller, unless it's hidden from the game's Windows environment).
@MainActor
final class DesktopPad: ObservableObject {
    static let shared = DesktopPad()

    static let onKey = "desktopPadOn", profileKey = "desktopPadProfile", rulesKey = "desktopPadApps", masterKey = "padProfilesOff"
    @Published var on: Bool = UserDefaults.standard.bool(forKey: onKey) { didSet { UserDefaults.standard.set(on, forKey: Self.onKey); evaluate() } }
    @Published var profileID: String? = UserDefaults.standard.string(forKey: profileKey) { didSet { UserDefaults.standard.set(profileID, forKey: Self.profileKey); evaluate(force: true) } }
    /// App bundle id → profile id, or "off".
    @Published var rules: [String: String] = (UserDefaults.standard.dictionary(forKey: rulesKey) as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(rules, forKey: Self.rulesKey); evaluate(force: true) }
    }
    /// Every profile on or off (the quick switch in the menu bar, for playing something Nokcandu doesn't know).
    @Published var enabled: Bool = !FileManager.default.fileExists(atPath: DesktopPad.offFile.path) {
        didSet {
            // A file too, so the part inside each game (Wine's controller driver) stops as well.
            if enabled { try? FileManager.default.removeItem(at: Self.offFile) }
            else { try? NokPaths.ensure(NokPaths.support); FileManager.default.createFile(atPath: Self.offFile.path, contents: Data()) }
            evaluate(force: true)
        }
    }
    static var offFile: URL { NokPaths.support.appendingPathComponent("controller-profiles-off") }
    /// One profile for everything until it's switched off (streaming, say), whatever is in front — games included.
    @Published var everywhereID: String? = (try? String(contentsOf: DesktopPad.everywhereFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyPad {
        didSet {
            // A file too: games then leave their own profile out of Wine's controller driver.
            if let id = everywhereID {
                try? NokPaths.ensure(NokPaths.support); try? Data(id.utf8).write(to: Self.everywhereFile, options: .atomic)
                if let p = PadProfiles.profiles().first(where: { $0.id == id }) { PadHUD.shared.show("\(p.name) everywhere", symbol: "gamecontroller.fill") }
            } else {
                try? FileManager.default.removeItem(at: Self.everywhereFile)
                if oldValue != nil { PadHUD.shared.show("Profiles back to normal", symbol: "gamecontroller") }
            }
            evaluate(force: true)
        }
    }
    static var everywhereFile: URL { NokPaths.support.appendingPathComponent("controller-profiles-everywhere") }
    /// The library, to recognise Nokcandu games in front.
    var games: [InstalledGame] = [] { didSet { evaluate() } }
    /// The front app's Wine process when it's a Nokcandu game (its movement goes into the game).
    private var gamePID: pid_t = 0
    private var sock: Int32 = -1
    /// What's happening now, for the menu and Settings.
    @Published private(set) var status = "Off"
    /// The profile applying right now (nil: none), and where it applies.
    @Published private(set) var activeID: String?
    @Published private(set) var activeWhere = ""
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
        watchRealMouse()
        evaluate()
    }

    func askForAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// The Nokcandu game a running app belongs to: the game's app itself, its program inside a launcher
    /// (…/SharedSupport/GameApp/<Game>.app), or a Mac game.
    func game(for app: NSRunningApplication?) -> InstalledGame? {
        guard let url = app?.bundleURL?.resolvingSymlinksInPath() else { return nil }
        let path = url.path
        if let r = path.range(of: "/Contents/SharedSupport/GameApp/") {
            let host = URL(fileURLWithPath: String(path[..<r.lowerBound]) + "/Contents").standardizedFileURL
            let name = url.deletingPathExtension().lastPathComponent
            return games.first { $0.name == name && WineTools.hostContents(for: $0)?.resolvingSymlinksInPath().standardizedFileURL == host }
                ?? games.first { $0.name == name }
        }
        return games.first { NokPaths.sameApp($0.appURL.path, url) || ($0.native.map { NokPaths.sameApp($0.appPath, url) } ?? false) }
    }

    /// The profile a game uses (nil: the controller as it is).
    static func profile(for g: InstalledGame, all: [PadProfiles.Profile]) -> PadProfiles.Profile? {
        guard let c = KeyRemap.gameContents(for: g) else { return nil }
        let shared = KeyRemap.isShared(g)
        if shared, PadProfiles.choice(contents: c, shared: true) == .sameAsLauncher {
            return KeyRemap.contents(for: g).flatMap { PadProfiles.effective(contents: $0, all: all) }
        }
        return PadProfiles.effective(contents: c, shared: shared, all: all)
    }

    /// Picks the profile for the app in front (or none) and (re)builds the engine when it changes.
    func evaluate(force: Bool = false) {
        trusted = AXIsProcessTrusted()
        let front = NSWorkspace.shared.frontmostApplication
        let id = front?.bundleIdentifier ?? ""
        var chosen: PadProfiles.Profile?
        let all = PadProfiles.profiles()
        let g = game(for: front)
        gamePID = g != nil && g?.native == nil ? (front?.processIdentifier ?? 0) : 0
        if !enabled { status = "All profiles off" }
        else if let id = everywhereID, let p = all.first(where: { $0.id == id }) {
            chosen = p; status = "Everywhere: \(p.name)"
        } else if let g {
            chosen = Self.profile(for: g, all: all)
            status = chosen.map { "\(g.name): \($0.name)" } ?? "\(g.name): controller as it is"
        } else if let rule = rules[id] {
            if rule == "off" { status = "Off for \(front?.localizedName ?? "this app")" }
            else if let p = all.first(where: { $0.id == rule }) { chosen = p; status = "\(front?.localizedName ?? "This app"): \(p.name)" }
        } else if on, let p = profileID.flatMap({ pid in all.first { $0.id == pid } }) {
            chosen = p; status = "Mac: \(p.name)"
        } else { status = on ? "Mac: no profile chosen" : "Waiting for a game" }
        if chosen != nil && !trusted { status = "Needs Accessibility permission" }
        let wherePlaying: String = everywhereID != nil && chosen?.id == everywhereID ? "Everywhere" : g?.name ?? (rules[id] != nil ? (front?.localizedName ?? "") : "On the Mac")
        if activeID != chosen?.id { activeID = chosen?.id }
        if activeWhere != wherePlaying { activeWhere = wherePlaying }
        let text = (chosen != nil && trusted) ? PadProfiles.compile(chosen!, all: all) : ""
        if text == compiled && !force { return }
        layerNames = chosen.map { PadProfiles.merged($0, all: all).layers.map(\.name) } ?? []
        shownLayer = 0; shownGyro = chosen.map { PadProfiles.merged($0, all: all).gyro.output == .off ? -1 : (PadProfiles.merged($0, all: all).gyro.startsOn ? 1 : 0) } ?? -1
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
        sink.state = { _, l, g in MainActor.assumeIsolated { DesktopPad.shared.stateChanged(layer: Int(l), gyro: Int(g)) } }
        engine = compiled.withCString { pe_create($0, sink) }
        attach()
    }

    /// Names of the active profile's layers (index = the engine's layer number).
    private var layerNames: [String] = []
    private var shownLayer = 0, shownGyro = -1
    func stateChanged(layer: Int, gyro: Int) {
        if layer != shownLayer {
            let name = layerNames.indices.contains(layer) ? layerNames[layer] : "Layer \(layer)"
            PadHUD.shared.show(layer == 0 ? "Base layer" : name, symbol: layer == 0 ? "square.stack" : "square.stack.3d.up.fill")
        } else if gyro != shownGyro, gyro >= 0, shownGyro >= 0 {
            PadHUD.shared.show(gyro == 1 ? "Gyro on" : "Gyro off", symbol: gyro == 1 ? "gyroscope" : "gyroscope")
        }
        shownLayer = layer; shownGyro = gyro
    }

    private func tick() { if let e = engine { pe_tick(e, Self.now()) } }
    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// The profile editor's live test reads the controller while it's open; the Mac profile waits until it closes.
    static var testerOpen = false

    func attach() {
        // Timers only while a controller is connected and a profile applies.
        let any = GCController.controllers().contains { $0.extendedGamepad != nil }
        if engine != nil && any && timer == nil {
            let t = Timer(timeInterval: 0.004, repeats: true) { _ in MainActor.assumeIsolated { DesktopPad.shared.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if (engine == nil || !any), let t = timer { t.invalidate(); timer = nil }
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
    /// The real mouse or trackpad moved this recently (seconds of uptime): it takes priority over the controller.
    private var lastRealMouse: TimeInterval = 0
    private var mouseMonitor: Any?
    func watchRealMouse() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { e in
            // Our own posted movement carries no hardware source; real devices do.
            guard e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
            MainActor.assumeIsolated { DesktopPad.shared.lastRealMouse = ProcessInfo.processInfo.systemUptime }
        }
    }

    private func move(_ dx: Int, _ dy: Int) {
        if ProcessInfo.processInfo.systemUptime - lastRealMouse < 0.3 { return }      // the real mouse is aiming
        if gamePID > 0, sendToGame(kind: 3, code: 0, dx: dx, dy: dy) { return }
        var p = cursor
        p.x += CGFloat(dx); p.y += CGFloat(dy)
        if gamePID > 0, let w = gameWindow(gamePID) {          // keep the pointer inside the game's window
            p.x = min(max(p.x, w.minX + 1), w.maxX - 2); p.y = min(max(p.y, w.minY + 28), w.maxY - 2)
        }
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
    /// The game's biggest window on screen (Mac screen coordinates, y down).
    private func gameWindow(_ pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Movement straight into the front Nokcandu game (its helper listens while it's in front).
    private func sendToGame(kind: UInt8, code: Int16, dx: Int, dy: Int) -> Bool {
        if sock < 0 { sock = socket(AF_UNIX, SOCK_DGRAM, 0) }
        guard sock >= 0 else { return false }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/tmp/nokcandu-pad-\(getuid())-\(gamePID).sock"
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { src in memcpy(buf.baseAddress!, src.baseAddress!, min(buf.count - 1, src.count)) } }
        var msg: (UInt8, UInt8, Int16, Int32, Int32) = (kind, 0, code, Int32(dx), Int32(dy))
        let sent = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                withUnsafeBytes(of: &msg) { m in sendto(sock, m.baseAddress, 12, MSG_DONTWAIT, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
        return sent == 12
    }

    private func wheel(_ n: Int) {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(n), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}

private extension String { var nilIfEmptyPad: String? { isEmpty ? nil : self } }
