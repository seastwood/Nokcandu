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
    static let controllerRulesKey = "desktopPadControllers", calibrateKeyKey = "padCalibrateShortcut"
    /// Controller name → the profile the Mac uses while it's connected.
    @Published var controllerRules: [String: String] = (UserDefaults.standard.dictionary(forKey: controllerRulesKey) as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(controllerRules, forKey: Self.controllerRulesKey); evaluate(force: true) }
    }
    /// A keyboard shortcut that calibrates the gyro (key code and modifier flags), anywhere.
    @Published var calibrateShortcut: [Int]? = UserDefaults.standard.array(forKey: calibrateKeyKey) as? [Int] {
        didSet { UserDefaults.standard.set(calibrateShortcut, forKey: Self.calibrateKeyKey); if started { watchShortcut() } }
    }
    /// Windows games' controller drivers watch this file: touching it calibrates there too.
    static var calibrateFile: URL { NokPaths.support.appendingPathComponent("controller-calibrate") }
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

    @Published var diagnosticsEnabled = false { didSet { lastDiagnosticTick = nil } }
    private(set) var diagnosticTimings: [String: PadTimingStatistics] = [:]
    private var lastDiagnosticTick: Double?
    private(set) var diagnosticCounts: [String: Int] = [:]
    private(set) var lastGyroReceipt: TimeInterval?
    private func diagnostic(_ name: String) {
        if diagnosticsEnabled { diagnosticCounts[name, default: 0] += 1 }
    }

    func resetDiagnostics() {
        diagnosticCounts = [:]; diagnosticTimings = [:]
        lastGyroReceipt = nil; lastDiagnosticTick = nil
    }
    private func finishTiming(_ name: String, started: Double?) {
        guard diagnosticsEnabled, let started else { return }
        diagnosticTimings[name, default: PadTimingStatistics()].record(seconds: Self.now() - started)
    }

    private var engine: OpaquePointer?
    private var compiled = ""
    /// The profile's joysticks, pedals, other controllers… into the same engine.
    private lazy var feed = DeviceFeed { DesktopPad.shared.engine }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var hadMainController = false
    private var sourceState = PadSourceState()
    private var lastButtons: [Int: Bool] = [:], lastAxes: [Int: Int] = [:]
    private var flags: CGEventFlags = []
    private var keyboardState = PadKeyboardState()
    private var mouseState = PadMouseButtons()
    private var socketMouseState = PadMouseSocketRoute()
    private var buttonsDown: Set<Int> { mouseState.held.union(socketMouseState.held) }
    private var runtimePID: pid_t = 0
    private var lifecycleObservers: [NSObjectProtocol] = []
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
        Task.detached(priority: .background) { PadSocketLeftovers.remove() }
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DesktopPad.shared.attach(); DesktopPad.shared.evaluate() } })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DesktopPad.shared.attach(); DesktopPad.shared.evaluate() } })
        watchShortcut()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopPad.shared.frontCache.at = -1; DesktopPad.shared.evaluate() }
            // A game says it uses its own profile a moment after it comes to the front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { DesktopPad.shared.evaluate() }
        })
        observers.append(nc.addObserver(forName: .hidDevicesChanged, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DesktopPad.shared.attach() } })
        observers.append(nc.addObserver(forName: .padProfilesChanged, object: nil, queue: .main) { _ in MainActor.assumeIsolated { DesktopPad.shared.evaluate(force: true) } })
        attach()
        watchRealMouse()
        PadCapture.shared.releaseOutputs = { [weak self] in
            if let e = self?.engine { pe_release_all(e, Self.now()) }
        }
        PadCapture.shared.start()
        lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let e = DesktopPad.shared.engine { pe_release_all(e, Self.now()) } }
        })
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
        if let wrapper = PadApplicationTarget.helperHost(url) {
            let host = wrapper.appendingPathComponent("Contents").standardizedFileURL
            let name = url.deletingPathExtension().lastPathComponent
            return games.first { $0.name == name && WineTools.hostContents(for: $0)?.resolvingSymlinksInPath().standardizedFileURL == host }
        }
        return games.first { NokPaths.sameApp($0.appURL.path, url) || ($0.native.map { NokPaths.sameApp($0.appPath, url) } ?? false) }
    }

    /// The profile a game uses (nil: the controller as it is).
    static func profile(for g: InstalledGame, all: [PadProfiles.Profile]) -> PadProfiles.Profile? {
        guard let c = KeyRemap.gameContents(for: g) else { return nil }
        let shared = KeyRemap.isShared(g)
        if let owner = PadProfiles.ownSource(contents: c, shared: shared, inheritedHost: KeyRemap.contents(for: g)),
           let pending = PadProfileEdits.shared.own(contents: owner) { return pending }
        if shared, PadProfiles.choice(contents: c, shared: true) == .sameAsLauncher {
            return KeyRemap.contents(for: g).flatMap { PadProfiles.effective(contents: $0, all: all) }
        }
        return PadProfiles.effective(contents: c, shared: shared, all: all)
    }

    /// Picks the profile for the app in front (or none) and (re)builds the engine when it changes.
    private var steamSource = false
    var suppliesSteamHaptics: Bool { steamSource && engine != nil }
    private let steamReaderID = UUID()
    /// Each layer's pad settings, [left, right], by the engine's layer number (0: base).
    private var steamPads: [[PadSteamTrackpadSettings]] = [[PadSteamTrackpadSettings(), PadSteamTrackpadSettings()]]
    private var steamPadLayer = 0
    private var steamLeftSettings: PadSteamTrackpadSettings { steamPads[min(steamPadLayer, steamPads.count - 1)][0] }
    private var steamRightSettings: PadSteamTrackpadSettings { steamPads[min(steamPadLayer, steamPads.count - 1)][1] }
    /// A layer with pad settings of its own took over (or gave them back): start the pads afresh.
    private func steamPadLayerChanged(_ layer: Int) {
        let old = steamPads[min(steamPadLayer, steamPads.count - 1)]
        steamPadLayer = layer
        guard steamPads[min(layer, steamPads.count - 1)] != old else { return }
        if let e = engine {
            for side in 0..<2 { for input in steamZones[side].held { pe_pad_zone(e, pe_input_named(input.rawValue), false, Self.now()) } }
        }
        steamRightMotion.reset(); steamLeftMotion.reset(); steamZones[0].reset(); steamZones[1].reset()
    }
    private var steamRightMotion = PadSteamTrackpad()
    private var steamLeftMotion = PadSteamTrackpad()
    private var steamZones = [PadSteamPadZones(), PadSteamPadZones()]
    private var steamTaps = [PadSteamTap(), PadSteamTap()]
    private var steamDials = [PadSteamDial(), PadSteamDial()]
    /// What each pad's current tap pressed (its plain tap or a zone's), so the same one is let go.
    private var steamTapInputs: [PadProfiles.Input?] = [nil, nil]
    private var steamZoneClicks = [PadSteamZoneRouter(), PadSteamZoneRouter()]
    /// A pad's direction and edge inputs, held or let go as the finger moves.
    private func steamPadZones(_ side: Int, down: Bool, pad: SteamControllerReport.Point, settings: PadSteamTrackpadSettings, engine e: OpaquePointer, now: Double) {
        let before = steamZones[side].held
        let after = steamZones[side].update(side: side, down: down, x: Double(pad.x), y: Double(pad.y), settings: settings)
        for input in before.symmetricDifference(after) { pe_pad_zone(e, pe_input_named(input.rawValue), after.contains(input), now) }
    }
    private var headStickActive = false

    /// The app in front. Every controller report and tick checks it (hundreds of times a second) so output
    /// never goes to the wrong app, and asking macOS each time was the app's biggest cost while playing.
    /// The answer is kept: replaced when an app is activated, and re-asked at most four times a second.
    fileprivate(set) var frontCache: (pid: pid_t, at: Double) = (0, -1)
    var frontPID: pid_t {
        let now = Self.now()
        if now - frontCache.at > 0.25 || now < frontCache.at { frontCache = (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, now) }
        return frontCache.pid
    }

    func evaluate(force: Bool = false) {
        let timingStart = diagnosticsEnabled ? Self.now() : nil
        defer { finishTiming("Profile resolution", started: timingStart) }
        trusted = AXIsProcessTrusted()
        let front = NSWorkspace.shared.frontmostApplication
        frontCache = (front?.processIdentifier ?? 0, Self.now())
        let nextPID = front?.processIdentifier ?? 0
        let focusChanged = runtimePID != nextPID
        if focusChanged { steamRightMotion.reset(); steamLeftMotion.reset(); steamZones[0].reset(); steamZones[1].reset(); steamTaps = [PadSteamTap(), PadSteamTap()]; steamTapInputs = [nil, nil]; steamZoneClicks = [PadSteamZoneRouter(), PadSteamZoneRouter()] }
        if focusChanged, let e = engine { pe_release_all(e, Self.now()) }
        runtimePID = nextPID
        let id = front?.bundleIdentifier ?? ""
        var chosen: PadProfiles.Profile?
        let all = PadProfileEdits.shared.profiles(PadProfiles.profiles())
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
        } else if on, let linked = linkedProfile(all) {
            chosen = linked.1; status = "\(linked.0): \(linked.1.name)"
        } else if on, let p = profileID.flatMap({ pid in all.first { $0.id == pid } }) {
            chosen = p; status = "Mac: \(p.name)"
        } else { status = on ? "Mac: no profile chosen" : "Waiting for a game" }
        if chosen != nil && !trusted { status = "Needs Accessibility permission" }
        let wherePlaying: String = everywhereID != nil && chosen?.id == everywhereID ? "Everywhere" : g?.name ?? (rules[id] != nil ? (front?.localizedName ?? "") : "On the Mac")
        if activeID != chosen?.id { activeID = chosen?.id }
        if activeWhere != wherePlaying { activeWhere = wherePlaying }
        PadHeadTracking.shared.configure(profileID: trusted ? chosen?.id : nil,
            settings: chosen.flatMap { trusted ? PadProfiles.headMotion($0, all: all) : nil })
        let nextSteamSource = chosen.map { trusted && PadProfiles.top($0, all: all, \.controllerSource) == .steamUSB } ?? false
        let sourceChanged = nextSteamSource != steamSource
        let padLayers: [String?] = chosen.map { p in PadProfiles.merged(p, all: all).layers.enumerated().map { $0.offset == 0 ? nil : $0.element.name } } ?? [nil]
        let nextPads = padLayers.map { layer in (0..<2).map { side in chosen.map { PadProfiles.steamTrackpad(side, profile: $0, all: all, layer: layer) } ?? PadSteamTrackpadSettings() } }
        if sourceChanged || nextPads != steamPads || force { steamRightMotion.reset(); steamLeftMotion.reset() }
        steamPads = nextPads.isEmpty ? [[PadSteamTrackpadSettings(), PadSteamTrackpadSettings()]] : nextPads
        steamSource = nextSteamSource
        if !steamSource { SteamControllerUSB.shared.remove(steamReaderID) }
        let text = (chosen != nil && trusted) ? PadProfiles.compile(chosen!, all: all) : ""
        if text == compiled && !force && !sourceChanged {
            if focusChanged {
                // release_all above ends holds/toggles in the old application.
                // Keep this same profile's sensor calibration; destroying the
                // engine here made every window switch discard its gyro bias.
                // Clear source snapshots so the next hardware report can admit
                // physically held inputs to the new foreground application.
                sourceState = PadSourceState(); lastButtons = [:]; lastAxes = [:]
                headStickActive = false
                attach()
                if let e = engine { stateChanged(layer: Int(pe_active_layer(e)), gyro: Int(pe_active_gyro(e))) }
            }
            return
        }
        layerNames = chosen.map { PadProfiles.merged($0, all: all).layers.map(\.name) } ?? []
        let settings = chosen.map { PadProfiles.layerSettings($0, all: all) } ?? [:]
        layerColors = layerNames.enumerated().map { i, n in settings[i == 0 ? "base" : n.lowercased()]?.color }
        rumble = chosen.flatMap { PadProfiles.top($0, all: all, \.rumbleOnLayer) } ?? false
        layerRumble = (chosen.flatMap { PadProfiles.top($0, all: all, \.layerRumbleStrength) } ?? PadProfiles.Profile.defaultLayerRumble.strength,
                       chosen.flatMap { PadProfiles.top($0, all: all, \.layerRumbleLength) } ?? PadProfiles.Profile.defaultLayerRumble.length)
        menus = chosen.map { Array(PadProfiles.collected($0, all: all, \.menus).prefix(8)) } ?? []
        PadFeedback.shared.light(layerColors.first ?? nil, feed.mainControllers())
        shownLayer = 0; shownGyro = chosen.map { PadProfiles.merged($0, all: all).gyro.output == .off ? -1 : (PadProfiles.merged($0, all: all).gyro.startsOn ? 1 : 0) } ?? -1
        if !focusChanged && !sourceChanged, let e = engine, text.withCString({ pe_update_profile(e, $0) }) {
            compiled = text
            stateChanged(layer: Int(pe_active_layer(e)), gyro: Int(pe_active_gyro(e)))
            return
        }
        compiled = text
        feed.set(text.isEmpty ? [] : chosen.map { PadProfiles.devices($0, all: all) } ?? [])
        rebuild()
    }

    private func rebuild() {
        if let e = engine { pe_release_all(e, Self.now()); pe_destroy(e) }
        engine = nil
        timer?.invalidate(); timer = nil
        lastButtons = [:]; lastAxes = [:]; sourceState = PadSourceState(); headStickActive = false
        steamZones[0].reset(); steamZones[1].reset(); steamTaps = [PadSteamTap(), PadSteamTap()]; steamTapInputs = [nil, nil]; steamZoneClicks = [PadSteamZoneRouter(), PadSteamZoneRouter()]
        guard !compiled.isEmpty else { SteamControllerUSB.shared.remove(steamReaderID); return }
        var sink = pe_sink()
        sink.pad_button = { _, _, _ in }          // the real controller is still there for the app
        sink.pad_axis = { _, _, _ in }
        sink.key = { _, k, d in MainActor.assumeIsolated { DesktopPad.shared.key(Int(k), d) } }
        sink.mouse_button = { _, b, d in MainActor.assumeIsolated { DesktopPad.shared.mouse(Int(b), d) } }
        sink.mouse_move = { _, x, y in MainActor.assumeIsolated { DesktopPad.shared.move(Int(x), Int(y)) } }
        sink.wheel = { _, n in MainActor.assumeIsolated { DesktopPad.shared.wheel(Int(n)) } }
        sink.state = { _, l, g in MainActor.assumeIsolated { DesktopPad.shared.stateChanged(layer: Int(l), gyro: Int(g)) } }
        sink.text = { _, t in let s = t.map { String(cString: $0) } ?? ""; MainActor.assumeIsolated { DesktopPad.shared.typeText(s) } }
        sink.menu = { _, m, sl in MainActor.assumeIsolated { DesktopPad.shared.menuChanged(Int(m), Int(sl)) } }
        sink.calibration = { _, p in MainActor.assumeIsolated { PadHUD.shared.calibration(p, manual: pe_calibration_is_manual(DesktopPad.shared.engine)) } }
        engine = compiled.withCString { pe_create($0, sink) }
        if let e = engine { stateChanged(layer: Int(pe_active_layer(e)), gyro: Int(pe_active_gyro(e))) }
        attach()
    }

    /// Names of the active profile's layers (index = the engine's layer number).
    private var layerNames: [String] = []
    private var shownLayer = 0, shownGyro = -1
    private var layerColors: [String?] = []
    private var rumble = false
    private var menus: [PadProfiles.RadialMenu] = []
    func stateChanged(layer: Int, gyro: Int) {
        if layer != shownLayer {
            if rumble { rumbleMain(strength: layerRumble.strength, seconds: layerRumble.length) }
            PadFeedback.shared.light((layerColors.indices.contains(layer) ? layerColors[layer] : nil) ?? layerColors.first ?? nil, feed.mainControllers())
            let name = layerNames.indices.contains(layer) ? layerNames[layer] : "Layer \(layer)"
            PadHUD.shared.show(layer == 0 ? "Base layer" : name, symbol: layer == 0 ? "square.stack" : "square.stack.3d.up.fill")
        } else if gyro != shownGyro, gyro >= 0, shownGyro >= 0 {
            PadHUD.shared.gyroChanged(gyro == 1)
        }
        shownLayer = layer; shownGyro = gyro
        steamPadLayerChanged(layer)
        PadHeadTracking.shared.refreshActivation()
    }

    private func tick() {
        let timingStart = diagnosticsEnabled ? Self.now() : nil
        defer { finishTiming("Mapping tick", started: timingStart) }
        if let now = timingStart {
            if let previous = lastDiagnosticTick {
                diagnosticTimings["Tick interval", default: PadTimingStatistics(budgetSeconds: 0.008)].record(seconds: now - previous)
            }
            lastDiagnosticTick = now
        }
        guard runtimePID == frontPID else { evaluate(); return }
        if let e = engine { pe_tick(e, Self.now()) }
        if OnScreenKeyboard.shared.isOpen {
            steamRightMotion.reset(); steamLeftMotion.reset()
            return
        }
        if steamSource, let e = engine {
            for side in 0..<2 where steamTaps[side].tick(at: Self.now()) { releaseTap(side, engine: e, now: Self.now()) }
            let motion = steamRightMotion.tick(at: Self.now(), settings: steamRightSettings)
            steamPadMouse(motion, side: 1)
            let left = steamLeftMotion.tick(at: Self.now(), settings: steamLeftSettings)
            steamPadMouse(left, side: 0)
        }
    }

    // MARK: Macros' text, radial menus, the on-screen keyboard, calibration

    /// The profile's own controller: the Steam Controller when that is its source (it has no macOS rumble,
    /// so asking macOS buzzed whatever other controller was connected), otherwise the macOS controllers.
    private func rumbleMain(strong: Bool) { rumbleMain(strength: strong ? 1 : 0.6, seconds: strong ? 0.4 : 0.15) }
    private func rumbleMain(strength: Double, seconds: Double) {
        if steamSource { SteamControllerUSB.shared.rumble(strength: strength, seconds: seconds) }
        else { PadFeedback.shared.rumble(feed.mainControllers(), strength: strength, seconds: seconds) }
    }
    private var layerRumble = PadProfiles.Profile.defaultLayerRumble

    func typeText(_ s: String) {
        for ch in s {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: PadEventSource.source(), virtualKey: 0, keyDown: down) else { continue }
                ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                ev.post(tap: .cghidEventTap)
            }
        }
    }
    func tapKey(_ k: Int) { key(k, true); key(k, false) }
    func menuChanged(_ m: Int, _ slice: Int) {
        if m == Int(PE_RUMBLE_MENU) { rumbleMain(strong: true); return }
        if m == Int(PE_KEYBOARD_MENU) {
            let held = Set(lastButtons.filter(\.value).compactMap { PadProfiles.Input(rawValue: String(cString: pe_input_name(Int32($0.key)))) })
            OnScreenKeyboard.shared.type = { DesktopPad.shared.typeText($0) }
            OnScreenKeyboard.shared.key = { DesktopPad.shared.tapKey($0) }
            OnScreenKeyboard.shared.toggle(pressed: held)
            return
        }
        guard menus.indices.contains(m) else { return }
        if slice == -2 { RadialHUD.shared.close() }
        else if slice == -1 { RadialHUD.shared.open(menus[m]) }
        else { RadialHUD.shared.update(slice) }
    }
    /// Calibrates the gyro now: here, and inside running Windows games.
    func calibrate() {
        if let e = engine { pe_calibrate(e, Self.now()) } else { PadHUD.shared.show("No gyro profile running", symbol: "gyroscope", force: true) }
        try? NokPaths.ensure(NokPaths.support)
        try? Data(String(Date().timeIntervalSince1970).utf8).write(to: Self.calibrateFile, options: .atomic)
    }
    private var shortcutMonitors: [Any] = []
    func watchShortcut() {
        // Do not keep keyboard monitors alive for an unconfigured shortcut.
        shortcutMonitors.forEach(NSEvent.removeMonitor); shortcutMonitors = []
        guard let shortcut = calibrateShortcut, shortcut.count == 2,
              shortcut[1] != 0 else { return }
        let check: (NSEvent) -> Bool = { e in
            MainActor.assumeIsolated {
                guard let sc = DesktopPad.shared.calibrateShortcut, sc.count == 2, Int(e.keyCode) == sc[0],
                      Int(e.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue) == sc[1] else { return false }
                DesktopPad.shared.calibrate(); return true
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in _ = check(e) }) { shortcutMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in check(e) ? nil : e }) { shortcutMonitors.append(l) }
    }
    /// A profile linked to a connected controller.
    func linkedProfile(_ all: [PadProfiles.Profile]) -> (String, PadProfiles.Profile)? {
        for c in GCController.controllers() {
            guard let n = c.vendorName, let id = controllerRules[n], let p = all.first(where: { $0.id == id }) else { continue }
            return (n, p)
        }
        return nil
    }
    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private var napGuard: NSObjectProtocol?
    func attach() {
        // Timers only while a controller is connected and a profile applies.
        let any = steamSource || GCController.controllers().contains { $0.extendedGamepad != nil } || feed.anyConnected
        if !any, let e = engine { pe_release_all(e, Self.now()); sourceState = PadSourceState() }
        // While a profile is mapping a controller, macOS must not nap Nokcandu behind the game: App Nap
        // stretches timers and delays callbacks, which is felt as late or uneven input.
        let mapping = engine != nil && any
        if mapping, napGuard == nil {
            napGuard = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Mapping a controller for the app in front")
        } else if !mapping, let guardToken = napGuard { ProcessInfo.processInfo.endActivity(guardToken); napGuard = nil }
        if engine != nil && any && timer == nil {
            let t = Timer(timeInterval: 0.004, repeats: true) { _ in MainActor.assumeIsolated { DesktopPad.shared.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if (engine == nil || !any), let t = timer { t.invalidate(); timer = nil }
        feed.attachGamepads()
        if steamSource {
            SteamControllerUSB.shared.listen(steamReaderID) { [weak self] state in self?.readSteam(state) }
            return
        }
        SteamControllerUSB.shared.remove(steamReaderID)
        if hadMainController && feed.mainControllers().isEmpty, let e = engine {
            pe_release_main(e, Self.now()); sourceState = PadSourceState(); lastButtons = [:]; lastAxes = [:]
        }
        hadMainController = !feed.mainControllers().isEmpty
        consume(sourceState.retain(Set(feed.mainControllers().map { String(describing: ObjectIdentifier($0)) }).union(headStickActive ? ["head-motion"] : [])))
        for c in feed.mainControllers() {
            guard let gp = c.extendedGamepad else { continue }
            let sourceID = String(describing: ObjectIdentifier(c))
            gp.valueChangedHandler = { pad, _ in MainActor.assumeIsolated { DesktopPad.shared.read(pad, source: sourceID) } }
            if let m = c.motion {
                if m.sensorsRequireManualActivation { m.sensorsActive = true }
                m.valueChangedHandler = { motion in
                    let r = motion.rotationRate
                    let a = motion.hasGravityAndUserAcceleration ? motion.gravity : motion.acceleration
                    MainActor.assumeIsolated {
                        let runtime = DesktopPad.shared
                        let timingStart = runtime.diagnosticsEnabled ? DesktopPad.now() : nil
                        defer { runtime.finishTiming("Motion handling", started: timingStart) }
                        runtime.diagnostic("motion callbacks")
                        if runtime.diagnosticsEnabled {
                            runtime.lastGyroReceipt = DesktopPad.now()
                            if r.x.isFinite && r.y.isFinite && r.z.isFinite && (r.x != 0 || r.y != 0 || r.z != 0) {
                                runtime.diagnostic("nonzero rotation samples")
                            }
                        }
                        guard !runtime.steamSource, let e = runtime.engine else { return }
                        pe_gyro(e, Float(r.x), Float(r.y), Float(r.z), DesktopPad.now())
                        if pe_uses_tilt(e) { pe_accel(e, Float(a.x), Float(a.y), Float(a.z), DesktopPad.now()) }
                    }
                }
            }
            PadGC.watchTouchpads(c) { f, down, x, y in
                MainActor.assumeIsolated { if !DesktopPad.shared.steamSource, let e = DesktopPad.shared.engine { pe_touch(e, Int32(f), down, x, y, DesktopPad.now()) } }
            }
        }
    }

    private func read(_ g: GCExtendedGamepad, source: String) {
        let timingStart = diagnosticsEnabled ? Self.now() : nil
        defer { finishTiming("Controller handling", started: timingStart) }
        diagnostic("controller callbacks")
        guard engine != nil, !steamSource else { return }
        let (buttons, axes) = PadGC.state(g)
        if OnScreenKeyboard.shared.isOpen {
            OnScreenKeyboard.shared.handle(Set(buttons.filter(\.1).map(\.0)), stick: CGPoint(x: Double(g.leftThumbstick.xAxis.value), y: Double(g.leftThumbstick.yAxis.value)))
            return
        }
        let held = Set(buttons.filter(\.1).map { Int(pe_input_named($0.0.rawValue)) })
        let values = Dictionary(uniqueKeysWithValues: axes.map { (Int($0.0), Int(max(-32768, min(32767, $0.1 * 32767)))) })
        consume(sourceState.update(source: source, buttons: held, axes: values))
    }
    private func readSteam(_ state: SteamControllerReport.State?) {
        guard steamSource, let e = engine else { return }
        guard runtimePID == frontPID else { evaluate(); return }
        guard let state else {
            steamRightMotion.reset()
            steamLeftMotion.reset()
            steamZones[0].reset(); steamZones[1].reset(); steamTaps = [PadSteamTap(), PadSteamTap()]; steamTapInputs = [nil, nil]; steamZoneClicks = [PadSteamZoneRouter(), PadSteamZoneRouter()]
            pe_release_main(e, Self.now()); sourceState = PadSourceState(); lastButtons = [:]; lastAxes = [:]
            PadHeadTracking.shared.refreshActivation(); return
        }
        if OnScreenKeyboard.shared.isOpen {
            OnScreenKeyboard.shared.handle(state.buttons, stick: CGPoint(x: Double(state.stick.x), y: Double(state.stick.y)))
            return
        }
        let now = Self.now()
        for side in 0..<2 {
            let settings = side == 0 ? steamLeftSettings : steamRightSettings
            SteamControllerUSB.shared.touchFeedback(side: side, down: side == 0 ? state.leftTouch : state.rightTouch, strength: settings.touchFeedback ?? 0)
        }
        let touchRequired = steamLeftSettings.gyroWhileTouched == true || steamRightSettings.gyroWhileTouched == true
        let gyroTouch = (steamLeftSettings.gyroWhileTouched == true && state.leftTouch) || (steamRightSettings.gyroWhileTouched == true && state.rightTouch)
        pe_gyro_touch(e, touchRequired, gyroTouch)
        pe_touch(e,0,state.leftTouch && steamLeftSettings.mode == .existing,(state.leftPad.x+1)/2,(1-state.leftPad.y)/2,now)
        steamPadZones(0, down: state.leftTouch, pad: state.leftPad, settings: steamLeftSettings, engine: e, now: now)
        steamPadZones(1, down: state.rightTouch, pad: state.rightPad, settings: steamRightSettings, engine: e, now: now)
        if steamLeftSettings.mode != .existing {
            let motion = steamLeftMotion.touch(down: state.leftTouch, x: Double(state.leftPad.x+1)/2, y: Double(1-state.leftPad.y)/2, at: now, settings: steamLeftSettings)
            steamPadMouse(motion, side: 0)
        }
        let axes = state.mappingAxes(left: steamLeftSettings, right: steamRightSettings)
        var buttons = state.buttons
        for side in 0..<2 {
            let settings = side == 0 ? steamLeftSettings : steamRightSettings
            guard settings.mode == .dial else { steamDials[side].reset(); continue }
            let pad = side == 0 ? state.leftPad : state.rightPad
            let steps = steamDials[side].update(down: side == 0 ? state.leftTouch : state.rightTouch, x: Double(pad.x), y: Double(pad.y), settings: settings)
            guard steps != 0 else { continue }
            wheel(steps)
            if let strength = settings.dialHaptic, strength > 0 { SteamControllerUSB.shared.tick(side: side, strength: strength) }
        }
        for side in 0..<2 {
            let pad = side == 0 ? state.leftPad : state.rightPad, touching = side == 0 ? state.leftTouch : state.rightTouch
            let settings = side == 0 ? steamLeftSettings : steamRightSettings
            let bound: (PadProfiles.Input) -> Bool = { pe_input_bound(e, pe_input_named($0.rawValue)) }
            switch steamTaps[side].update(down: touching, x: Double(pad.x), y: Double(pad.y), at: now) {
            case .press:
                let input = PadSteamZoneRouter.tap(side: side, x: steamTaps[side].startX, y: steamTaps[side].startY, settings: settings, bound: bound)
                steamTapInputs[side] = input; pe_pad_zone(e, pe_input_named(input.rawValue), true, now)
            case .release: releaseTap(side, engine: e, now: now)
            case .none: break
            }
            // A click in a zone that has something set goes to that zone instead of the pad's own click.
            let clickButton: PadProfiles.Input = side == 0 ? .touchpad : .rs
            let routed = steamZoneClicks[side].click(side: side, down: state.buttons.contains(clickButton), touching: touching,
                                                    x: Double(pad.x), y: Double(pad.y), settings: settings, bound: bound)
            if let c = routed.change { pe_pad_zone(e, pe_input_named(c.input.rawValue), c.down, now) }
            if routed.suppress { buttons.remove(clickButton) }
        }
        if steamRightSettings.mode != .existing {
            let motion = steamRightMotion.touch(down: state.rightTouch, x: Double(state.rightPad.x+1)/2, y: Double(1-state.rightPad.y)/2, at: now, settings: steamRightSettings)
            steamPadMouse(motion, side: 1)
        }
        consume(sourceState.update(source: "steam-usb", buttons: Set(buttons.map { Int(pe_input_named($0.rawValue)) }), axes: axes))
        pe_gyro(e,state.gyro[0],state.gyro[1],state.gyro[2],now)
        if pe_uses_tilt(e) { pe_accel(e,state.acceleration[0],state.acceleration[1],state.acceleration[2],now) }
    }

    private func releaseTap(_ side: Int, engine e: OpaquePointer, now: Double) {
        let input = steamTapInputs[side] ?? .padTap(side)
        steamTapInputs[side] = nil
        pe_pad_zone(e, pe_input_named(input.rawValue), false, now)
    }

    private func steamPadMouse(_ motion: PadSteamTrackpad.Motion, side: Int) {
        guard !motion.isEmpty else { return }
        let settings = side == 0 ? steamLeftSettings : steamRightSettings
        if motion.x != 0 || motion.y != 0 {
            _ = SteamControllerUSB.shared.movementFeedback(side: side, dx: motion.x, dy: motion.y, strength: settings.movementFeedback ?? 0, rate: settings.hapticRate ?? 40, spacingMS: settings.hapticSpacingMS ?? 1, followsMovement: settings.hapticFollowsMovement ?? true)
        }
        move(motion.x, motion.y, fine: CGVector(dx: motion.fx, dy: motion.fy))
    }

    private func consume(_ changes: PadSourceState.Changes) {
        guard let e = engine else { return }
        let now = Self.now()
        for (i, down) in changes.buttons { lastButtons[i] = down; pe_button(e, Int32(i), down, now) }
        for (a, v) in changes.axes { lastAxes[a] = v; pe_axis(e, Int32(a), Int32(v), now) }
        PadHeadTracking.shared.refreshActivation()
    }

    // MARK: Keys and mouse to macOS

    private func key(_ k: Int, _ down: Bool) {
        guard let ev = CGEvent(keyboardEventSource: PadEventSource.source(), virtualKey: CGKeyCode(k), keyDown: down) else { return }
        diagnostic(down ? "key down" : "key up")
        flags = keyboardState.update(k, down: down)
        if !PadKeyboardState.modifier(k).isEmpty { ev.type = .flagsChanged }
        ev.flags = flags
        PadEventSource.mark(ev)
        ev.post(tap: .cghidEventTap)
    }
    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }
    private func mouse(_ b: Int, _ down: Bool) {
        let target = PadCapture.shared.targetPID ?? 0
        let wineTarget = target == 0 || target == gamePID ? gamePID : 0
        let capability = "/tmp/nokcandu-pad-\(getuid())-\(wineTarget).sock.buttons"
        let available = wineTarget > 0 && (try? String(contentsOfFile: capability, encoding: .utf8)) == "1\n"
        // Keep a CGEvent-delivered hold on its original route too.
        if !mouseState.held.contains(b), socketMouseState.route(button: b, down: down, target: wineTarget, available: available, send: { pid, button, pressed in
            sendToGame(kind: 2, code: Int16(button), dx: 0, dy: 0, down: pressed, target: pid)
        }) { diagnostic(down ? "Wine mouse button down" : "Wine mouse button up"); return }
        let point = target > 0 ? PadCapture.shared.point(for: target) : cursor
        if down && point == nil { return }
        guard let output = mouseState.event(button: b, down: down, target: target,
                                            point: point ?? cursor, flags: flags) else { return }
        diagnostic(down ? "mouse button down" : "mouse button up")
        if output.target > 0 { output.event.postToPid(output.target) }
        else { output.event.post(tap: .cghidEventTap) }
    }
    /// The real mouse or trackpad moved this recently (seconds of uptime): it takes priority over the controller.
    private var lastRealMouse: TimeInterval = 0
    private var mouseMonitor: Any?
    func watchRealMouse() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { e in
            // Our own posted movement carries no hardware source; real devices do.
            guard let event = e.cgEvent, !PadEventSource.isOwn(event, processID: getpid()) else { return }
            MainActor.assumeIsolated {
                let runtime = DesktopPad.shared
                runtime.lastRealMouse = ProcessInfo.processInfo.systemUptime
                if runtime.runtimePID == runtime.frontPID, let engine = runtime.engine {
                    _ = pe_menu_mouse(engine, e.deltaX, e.deltaY)
                }
            }
        }
    }

    // Explicit development opt-in; aggregate only, no device or application identifiers.
    private let traceMouse = ProcessInfo.processInfo.environment["NOKCANDU_TRACE_PAD_MOUSE"] == "1"
    private var traceCounts = [String: Int]()
    private var traceLast = 0.0
    private func traceMovement(_ route: String, dx: Int, dy: Int) {
        diagnostic("mouse: " + route)
        guard traceMouse else { return }
        traceCounts[route, default: 0] += 1
        let now = Self.now()
        guard now - traceLast >= 1 else { return }
        NSLog("Nokcandu pad mouse routes=%@ latestDelta=%d,%d held=%@", String(describing: traceCounts), dx, dy, String(describing: buttonsDown.sorted()))
        traceCounts.removeAll(keepingCapacity: true); traceLast = now
    }

    /// The pointer as Nokcandu last placed it (between pixels), so consecutive moves add up exactly instead
    /// of each starting from wherever macOS has got to; dropped when anything else moves the pointer.
    private var pointerPosition: CGPoint?
    private var pointerPositionAt = 0.0
    private var windowCache: (pid: pid_t, rect: CGRect?, at: Double) = (0, nil, -1)
    private var screenBounds: (rect: CGRect, at: Double) = (.null, -1)

    /// `fine`: the exact movement, when the source has it (trackpads); games still get whole pixels.
    private func move(_ dx: Int, _ dy: Int, fine: CGVector? = nil) {
        let fx = fine.map { Double($0.dx) } ?? Double(dx), fy = fine.map { Double($0.dy) } ?? Double(dy)
        // Headphone mouse output uses this same picker; engine-generated gyro,
        // stick and touchpad mouse output is intercepted before its output sink.
        if let engine, pe_menu_mouse(engine, fx, fy) { return }
        let whole = dx != 0 || dy != 0
        if let pid = PadCapture.shared.targetPID {
            // Wine's own helper can deliver explicit relative motion directly.
            // Posting a CGEvent instead can be swallowed by its raw-mouse hook.
            // code=1 requests capture; older helpers ignore it and retain their ordinary path.
            guard whole else { return }
            if pid == gamePID, sendToGame(kind: 3, code: 1, dx: dx, dy: dy) {
                traceMovement("captured-wine-socket", dx: dx, dy: dy); return
            }
            guard let point = PadCapture.shared.point(for: pid),
                  let event = PadMouseEvent.movement(at: point, dx: dx, dy: dy, heldButtons: buttonsDown, flags: flags) else { return }
            traceMovement("captured-process", dx: dx, dy: dy)
            event.postToPid(pid)
            return
        }
        if ProcessInfo.processInfo.systemUptime - lastRealMouse < 0.3 { traceMovement("hardware-priority", dx: dx, dy: dy); return }      // the real mouse is aiming
        if gamePID > 0 {
            if !whole { return }
            if sendToGame(kind: 3, code: 0, dx: dx, dy: dy) { traceMovement("wine-socket", dx: dx, dy: dy); return }
        }
        traceMovement("desktop-pointer", dx: dx, dy: dy)
        let now = Self.now(), actual = cursor
        // Continue from where Nokcandu put the pointer while macOS shows it there (it may not have caught up
        // with the last move yet); anything else moving it starts afresh from the real position.
        var p = actual
        if let last = pointerPosition, now - pointerPositionAt < 0.25,
           abs(last.x - actual.x) <= 2.5, abs(last.y - actual.y) <= 2.5, now - lastRealMouse > 0.3 { p = last }
        p.x += CGFloat(fx); p.y += CGFloat(fy)
        if gamePID > 0 {                                       // keep the pointer inside the game's window
            if windowCache.pid != gamePID || now - windowCache.at > 0.5 { windowCache = (gamePID, gameWindow(gamePID), now) }
            if let w = windowCache.rect { p.x = min(max(p.x, w.minX + 1), w.maxX - 2); p.y = min(max(p.y, w.minY + 28), w.maxY - 2) }
        }
        if now - screenBounds.at > 1 {
            screenBounds = (NSScreen.screens.reduce(CGRect.null) { r, s in
                let f = s.frame, top = NSScreen.screens.first?.frame.maxY ?? f.maxY
                return r.union(CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height))
            }, now)
        }
        let bounds = screenBounds.rect
        p.x = min(max(p.x, bounds.minX), bounds.maxX - 1); p.y = min(max(p.y, bounds.minY), bounds.maxY - 1)
        pointerPosition = p; pointerPositionAt = now
        guard let ev = PadMouseEvent.movement(at: p, dx: dx, dy: dy,
                                             heldButtons: buttonsDown, flags: flags) else { return }
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
    private func sendToGame(kind: UInt8, code: Int16, dx: Int, dy: Int, down: Bool = false, target: pid_t? = nil) -> Bool {
        if sock < 0 { sock = socket(AF_UNIX, SOCK_DGRAM, 0) }
        guard sock >= 0 else { return false }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = "/tmp/nokcandu-pad-\(getuid())-\(target ?? gamePID).sock"
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { src in memcpy(buf.baseAddress!, src.baseAddress!, min(buf.count - 1, src.count)) } }
        var msg: (UInt8, UInt8, Int16, Int32, Int32) = (kind, down ? 1 : 0, code, Int32(dx), Int32(dy))
        let sent = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                withUnsafeBytes(of: &msg) { m in sendto(sock, m.baseAddress, 12, MSG_DONTWAIT, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
        return sent == 12
    }

    var headMotionAllowed: Bool {
        guard enabled, trusted, activeID != nil, PadHeadTracking.shared.enabled, let engine,
              runtimePID == frontPID else { return false }
        return !pe_motion_paused(engine)
    }
    func headMotionAllowed(settings: PadHeadMotionSettings) -> Bool {
        guard headMotionAllowed, let engine else { return false }
        let layer = Int(pe_active_layer(engine))
        let name = layerNames.indices.contains(layer) ? layerNames[layer] : nil
        let held = Set(lastButtons.filter(\.value).compactMap { PadProfiles.Input(rawValue: String(cString: pe_input_name(Int32($0.key)))) })
        return settings.permitsMotion(held: held, layer: name)
    }
    func releaseHeadStick() {
        guard headStickActive else { return }
        headStickActive = false
        consume(sourceState.update(source: "head-motion", buttons: [], axes: [:]))
    }
    func headStick(_ x: Double, _ y: Double, right: Bool) {
        guard headMotionAllowed else { releaseHeadStick(); return }
        headStickActive = true
        let a = right ? 2 : 0
        consume(sourceState.update(source: "head-motion", buttons: [], axes: [a:Int(max(-1,min(1,x))*32767),a+1:Int(max(-1,min(1,y))*32767)]))
    }
    func headMovement(_ dx: Int, _ dy: Int) {
        guard headMotionAllowed else { return }
        move(dx, dy)
    }

    func stop() {
        SteamControllerUSB.shared.remove(steamReaderID)
        PadHeadTracking.shared.configure(profileID: nil, settings: nil)
        if let e = engine { pe_release_all(e, Self.now()); pe_destroy(e) }; engine = nil
        timer?.invalidate(); timer = nil; feed.stop()
        PadCapture.shared.stop()
    }

    private func wheel(_ n: Int) {
        CGEvent(scrollWheelEvent2Source: PadEventSource.source(), units: .line, wheelCount: 1, wheel1: Int32(n), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}

private extension String { var nilIfEmptyPad: String? { isEmpty ? nil : self } }
