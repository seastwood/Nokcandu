// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GameController
import IOKit.hid
import NokcanduCore
import NokcanduPadEngine

/// Every controller connected now, joined with the ones Nokcandu remembers (ControllerRoster): which is which, what
/// each is pressing (while the Controllers panel watches), a soft buzz to find one, and the players file Windows
/// games' controller driver reads. A controller can reach Nokcandu several ways (macOS's controller support, a
/// community mapping, taken over from macOS, the Steam Controller reader, Nokcandu's own USB drivers); each way's
/// source name ("hidmap:<id>", a GameController's id, "steam") leads back to one remembered controller here.
@MainActor
final class ControllerDevices: ObservableObject {
    static let shared = ControllerDevices()

    @Published private(set) var roster = ControllerRoster.load()

    struct Connected: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let name: String
        let vendorID: Int, productID: Int
        let bluetooth: Bool?
        let registryID: UInt64?
        let serial: String?
        let nth: Int
        var location: Int? = nil
        /// The ways Nokcandu reads it now: Nokcandu's own drivers' sources ("hidmap:…", "owned:…", "steam"); a
        /// GameController controller is found from the registry id (gcLinks).
        let sources: [String]
        let family: Controllers.Family?
        let kind: Controllers.Kind
    }
    /// Connected controllers, in the order they connected.
    @Published private(set) var connected: [Connected] = []
    /// What each connected controller is pressing, by key, while watched.
    @Published private(set) var held: [String: [String]] = [:]
    /// When each last did anything (while watched), by key: the panel lights its row.
    @Published private(set) var lastInput: [String: Date] = [:]
    /// The player each controller became in the Windows games running now (their drivers report it).
    @Published private(set) var windowsPlayers: [String: Int] = [:]

    private var started = false
    private var watchers = 0
    private var mappedToken: UUID?
    private var hidToken: UUID?
    private let steamID = UUID()
    private var steamListening = false
    private var poll: Timer?
    private var gcState: [ObjectIdentifier: [String]] = [:]
    private var hidHeld: [UInt64: Set<String>] = [:]
    /// GameController controllers' HID devices, once told apart.
    private var gcLinks: [ObjectIdentifier: UInt64] = [:]

    func start() {
        guard !started else { return }
        started = true
        _ = HIDDevices.shared.listen { _, _ in }          // starts reading what's connected
        for n in [Notification.Name.hidDevicesChanged, .GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ControllerDevices.shared.refresh() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { ControllerDevices.shared.refresh(quiet: true) } }
        refresh()
    }

    // MARK: What's connected

    func refresh(quiet: Bool = false) {
        var list: [Connected] = []
        var roster = self.roster
        let owned = ControllerTakeover.shared.owned
        let mapped = MappedGamepads.shared.sources
        for d in HIDDevices.shared.connected.sorted(by: { $0.id < $1.id }) {
            let key = roster.saw(vendorID: d.vendorID, productID: d.productID, serial: d.serial, nth: d.nth, name: d.name)
            var sources: [String] = []
            for prefix in ["hidmap", "owned", "report"] where mapped.contains("\(prefix):\(d.id)") { sources.append("\(prefix):\(d.id)") }
            if owned.contains(d.id), !sources.contains("owned:\(d.id)") { sources.append("owned:\(d.id)") }
            list.append(Connected(key: key, name: d.name, vendorID: d.vendorID, productID: d.productID, bluetooth: d.bluetooth, registryID: d.id,
                                  serial: d.serial, nth: d.nth, location: d.location, sources: sources, family: Controllers.Family.of(vendorID: d.vendorID),
                                  kind: Controllers.kind(vendorID: d.vendorID, productID: d.productID, usagePage: 1, usage: d.isGamepadUsage ? kHIDUsage_GD_GamePad : kHIDUsage_GD_Joystick)))
        }
        if let s = SteamControllerUSB.shared.identity {
            // First seen while it wasn't being read (no serial then): that entry becomes this one.
            let exact = ControllerRoster.key(vendorID: s.vendorID, productID: s.productID, serial: s.serial, nth: 0)
            let same = roster.controllers.filter { $0.vendorID == s.vendorID && $0.productID == s.productID }
            if roster.controller(exact) == nil, same.count == 1, same[0].key.hasSuffix(":n:0"), exact != same[0].key {
                roster.update(same[0].key) { $0.key = exact; $0.byOrder = ControllerRoster.normalizedSerial(s.serial) == nil }
            }
            let key = roster.saw(vendorID: s.vendorID, productID: s.productID, serial: s.serial, nth: 0, name: s.name)
            list.append(Connected(key: key, name: s.name, vendorID: s.vendorID, productID: s.productID, bluetooth: s.bluetooth, registryID: s.registryID,
                                  serial: s.serial, nth: 0, sources: ["steam"], family: s.steam2026 ? .steam2026 : .valve, kind: .gamepad))
        } else {
            // Not being read: listed (its description only), never opened from here. Reading it would take it out of
            // its own keyboard-and-mouse mode, which someone may be using to click around.
            for c in Controllers.connected() where c.vendorID == Controllers.Family.valve.vendorID && !c.isSteamControllerReceiver && !list.contains(where: { $0.vendorID == c.vendorID }) {
                // The one remembered while it was read (with its serial), if there's just one of its model.
                let known = roster.controllers.filter { $0.vendorID == c.vendorID && $0.productID == c.productID }
                let key = known.count == 1 ? roster.saw(key: known[0].key, name: known[0].productName)
                    : roster.saw(vendorID: c.vendorID, productID: c.productID, serial: nil, nth: 0, name: c.displayName)
                list.append(Connected(key: key, name: c.displayName, vendorID: c.vendorID, productID: c.productID, bluetooth: c.bluetooth, registryID: nil,
                                      serial: nil, nth: 0, sources: [], family: .valve, kind: .gamepad))
            }
        }
        // Nokcandu's own USB drivers (Switch 2, Xbox 360 wired and wireless, the GameCube adapter): remembered by name
        // and place among those of the same name.
        var nthByName: [String: Int] = [:]
        for (source, n) in MappedGamepads.shared.native.sorted(by: { $0.key < $1.key }) where !source.hasPrefix("owned:") && !source.hasPrefix("report:") {
            let k = nthByName[n.name, default: 0]; nthByName[n.name] = k + 1
            let key = roster.saw(key: "usb:" + Self.slug(n.name) + ":n:\(k)", name: n.name)
            list.append(Connected(key: key, name: n.name, vendorID: 0, productID: 0, bluetooth: false, registryID: nil,
                                  serial: nil, nth: k, sources: [source], family: nil, kind: .gamepad))
        }
        migrateNameRules(&roster, list)
        // Controllers set to another player than 1 stay macOS's, for Mac games to get as they are.
        ControllerTakeover.shared.exclude(Set(list.compactMap { c -> Int? in
            guard let loc = c.location, TakeoverPad.find(vendor: c.vendorID, product: c.productID) != nil,
                  (roster.controller(c.key)?.seat.explicit ?? 1) > 1 else { return nil }
            return loc
        }))
        if roster != self.roster && !(quiet && Self.onlySeenChanged(self.roster, roster)) { self.roster = roster; roster.save() }
        else if roster != self.roster { self.roster = roster }
        if list != connected { connected = list; invalidate() }
        writePlayers()
        readWindowsPlayers()
        let links = gcLinks.filter { id, _ in GCController.controllers().contains { ObjectIdentifier($0) == id } }
        if links != gcLinks { gcLinks = links; invalidate() }
    }
    private static func onlySeenChanged(_ a: ControllerRoster, _ b: ControllerRoster) -> Bool {
        var x = a, y = b
        for i in x.controllers.indices { x.controllers[i].lastSeen = .distantPast }
        for i in y.controllers.indices { y.controllers[i].lastSeen = .distantPast }
        return x == y
    }
    private static func slug(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(24)) }

    /// "When this controller is connected, the Mac uses …" rules from before (by controller name) become the
    /// controllers' own profiles, once each controller of that name is seen.
    private func migrateNameRules(_ roster: inout ControllerRoster, _ list: [Connected]) {
        let rules = DesktopPad.shared.controllerRules
        guard !rules.isEmpty else { return }
        for c in list { if let id = rules[c.name], roster.controller(c.key)?.fallbackProfileID == nil { roster.update(c.key) { $0.fallbackProfileID = id } } }
    }

    func remembered(_ key: String) -> ControllerRoster.Remembered? { roster.controller(key) }
    /// A controller's own profile: chosen in the panel, or a rule by its name from before.
    func ownProfile(_ c: Connected) -> String? { roster.controller(c.key)?.fallbackProfileID ?? DesktopPad.shared.controllerRules[c.name] }

    // MARK: Changes from the panel

    func rename(_ key: String, _ name: String) { change(key) { $0.customName = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name } }
    func setSeat(_ key: String, _ seat: ControllerRoster.Seat) {
        change(key) { $0.seat = seat }
        refresh()
        DesktopPad.shared.controllersChanged()
    }
    func setFallback(_ key: String, _ id: String?) {
        change(key) { $0.fallbackProfileID = id }
        // The name rule this replaces, if any, goes: the controller's own choice is the one that counts now.
        if let c = remembered(key), DesktopPad.shared.controllerRules[c.productName] != nil { DesktopPad.shared.controllerRules[c.productName] = nil }
        DesktopPad.shared.controllersChanged()
    }
    func forget(_ key: String) {
        var r = roster; r.forget(key); roster = r; r.save(); invalidate(); writePlayers()
        DesktopPad.shared.controllersChanged()
    }
    private func change(_ key: String, _ f: (inout ControllerRoster.Remembered) -> Void) {
        var r = roster; r.update(key, f); roster = r; r.save(); invalidate(); writePlayers()
    }

    // MARK: Which controller a source is

    /// key(forSource:), remembered until what's connected, the links or the players change: the input path asks on
    /// every event, so this must cost no more than a dictionary lookup.
    private var keyCache: [String: String?] = [:]
    private func invalidate() { keyCache = [:] }
    func cachedKey(forSource source: String) -> String? {
        if let k = keyCache[source] { return k }
        let k = key(forSource: source)
        // Unknown for now (twins not told apart yet): not remembered, so a later press can tell.
        if k != nil { keyCache[source] = k }
        return k
    }
    /// The remembered controller behind one of the profile's input sources.
    func key(forSource source: String) -> String? {
        if source == "steam" { return connected.first { $0.sources.contains("steam") }?.key }
        if let c = connected.first(where: { $0.sources.contains(source) }) { return c.key }
        if let gc = GCController.controllers().first(where: { String(describing: ObjectIdentifier($0)) == source }), let reg = hidID(for: gc) {
            return connected.first { $0.registryID == reg }?.key
        }
        return nil
    }
    func seat(forSource source: String) -> ControllerRoster.Seat { key(forSource: source).flatMap { roster.controller($0)?.seat } ?? .auto }

    /// The HID device a GameController controller is: the only one of its name, or the one that moved when it did.
    func hidID(for c: GCController) -> UInt64? {
        let candidates = HIDDevices.shared.connected.filter { $0.name == c.vendorName && !ControllerTakeover.shared.owned.contains($0.id) }
        if candidates.count == 1 { return candidates[0].id }
        if let l = gcLinks[ObjectIdentifier(c)], candidates.contains(where: { $0.id == l }) { return l }
        return nil
    }
    /// A GameController controller changed: if it has twins, the device that sent something just now is it.
    func gameControllerMoved(_ c: GCController) {
        guard gcLinks[ObjectIdentifier(c)] == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let candidates = HIDDevices.shared.connected.filter { $0.name == c.vendorName && !ControllerTakeover.shared.owned.contains($0.id) }
        guard candidates.count > 1 else { return }
        let linked = Set(gcLinks.values)
        let moving = candidates.filter { !linked.contains($0.id) && now - (HIDDevices.shared.lastActivity[$0.id] ?? 0) < 0.08 }
        if moving.count == 1 { gcLinks[ObjectIdentifier(c)] = moving[0].id; invalidate(); objectWillChange.send() }
    }
    func gameController(for key: String) -> GCController? {
        guard let reg = connected.first(where: { $0.key == key })?.registryID else { return nil }
        return GCController.controllers().first { $0.extendedGamepad != nil && hidID(for: $0) == reg }
    }
    /// Identical controllers macOS reads, not yet told apart by a press.
    func needsPress(_ key: String) -> Bool {
        guard let c = connected.first(where: { $0.key == key }), c.sources.isEmpty, let reg = c.registryID else { return false }
        let twins = HIDDevices.shared.connected.filter { $0.name == c.name && $0.gamepad }
        return twins.count > 1 && !gcLinks.values.contains(reg)
    }

    // MARK: Ping

    /// A soft buzz on one controller. False: it can't buzz (or isn't told apart from its twins yet).
    @discardableResult
    func ping(_ key: String) -> Bool {
        guard let c = connected.first(where: { $0.key == key }) else { return false }
        if c.sources.contains("steam") { return SteamControllerUSB.shared.rumble(strength: 0.5, seconds: 0.25) }
        if let s = c.sources.first { MappedGamepads.shared.rumble([s], strength: 0.35, seconds: 0.25); return true }
        if let gc = gameController(for: key), gc.haptics != nil { PadFeedback.shared.rumble([gc], strength: 0.35, seconds: 0.25); return true }
        return false
    }
    func canPing(_ key: String) -> Bool {
        guard let c = connected.first(where: { $0.key == key }) else { return false }
        if c.sources.contains(where: { ["owned", "xinput", "report", "gamecube", "switch2", "steam"].contains(String($0.split(separator: ":").first ?? "")) }) { return true }
        return gameController(for: key)?.haptics != nil
    }

    // MARK: Watching (the panel is open)

    func watch(_ on: Bool) {
        watchers += on ? 1 : -1
        if watchers == 1 && on { startWatching() } else if watchers == 0 { stopWatching() }
    }
    private func startWatching() {
        start()
        mappedToken = MappedGamepads.shared.listen { source, buttons, axes in
            MainActor.assumeIsolated { ControllerDevices.shared.sourceChanged(source, buttons.map { Self.shown($0, axes: axes, family: nil) } ?? ([], [])) }
        }
        hidToken = HIDDevices.shared.listen { info, ev in MainActor.assumeIsolated { ControllerDevices.shared.hidEvent(info, ev) } }
        steamListening = SteamControllerUSB.shared.isReading
        if steamListening { SteamControllerUSB.shared.listen(steamID) { state in
            MainActor.assumeIsolated {
                guard let state else { ControllerDevices.shared.sourceChanged("steam", ([], [])); return }
                ControllerDevices.shared.sourceChanged("steam", Self.shown(state.buttons, axes: state.axes, family: state.kind == .steam2026 ? .steam2026 : .valve))
            }
        } }
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { ControllerDevices.shared.pollGameControllers() } }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }
    private func stopWatching() {
        MappedGamepads.shared.stopListening(mappedToken); mappedToken = nil
        HIDDevices.shared.stopListening(hidToken); hidToken = nil
        if steamListening { SteamControllerUSB.shared.remove(steamID); steamListening = false }
        poll?.invalidate(); poll = nil
        held = [:]; heldInputs = [:]; gcState = [:]; hidHeld = [:]
    }
    private func pollGameControllers() {
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            let (buttons, axes) = PadGC.state(g)
            let pressed = Set(buttons.filter(\.1).map(\.0))
            let values = Dictionary(uniqueKeysWithValues: axes.map { (Int($0.0), Int(max(-32768, min(32767, $0.1 * 32767)))) })
            let id = ObjectIdentifier(c)
            let entry = hidID(for: c).flatMap { reg in connected.first { $0.registryID == reg } }
            let shown = Self.shown(pressed, axes: values, family: entry?.family)
            guard gcState[id] != shown.labels else { continue }
            gcState[id] = shown.labels
            gameControllerMoved(c)
            if let key = (entry ?? hidID(for: c).flatMap { reg in connected.first { $0.registryID == reg } })?.key { show(key, shown) }
        }
    }
    private func sourceChanged(_ source: String, _ shown: Shown) {
        guard let key = key(forSource: source) else { return }
        show(key, shown)
    }
    private func hidEvent(_ info: HIDDevices.Info, _ ev: HIDDevices.Event) {
        // Devices read some other way show what that way makes of them.
        guard let c = connected.first(where: { $0.registryID == info.id }), c.sources.isEmpty, !info.gamepad else { return }
        var set = hidHeld[info.id] ?? []
        switch ev {
        case .button(let n, let down): if down { set.insert("Button \(n + 1)") } else { set.remove("Button \(n + 1)") }
        case .hat(let bits): set = set.filter { !$0.hasPrefix("Hat") }; if bits != 0 { set.insert("Hat") }
        case .axis(let n, let v):
            let name = "Axis \(n + 1)"
            if abs(v) > 20000 { set.insert(name) } else { set.remove(name) }
        }
        hidHeld[info.id] = set
        show(c.key, (set.sorted(), []))
    }
    private func show(_ key: String, _ shown: Shown) {
        let (labels, inputs) = shown
        if heldInputs[key] != inputs { heldInputs[key] = inputs }
        if held[key] != labels { held[key] = labels }
        if !labels.isEmpty { lastInput[key] = Date() }
    }
    /// The inputs held (by key), for the panel's picture: buttons, and a stick that's moved as its click.
    @Published private(set) var heldInputs: [String: Set<PadProfiles.Input>] = [:]
    typealias Shown = (labels: [String], inputs: Set<PadProfiles.Input>)

    /// What a controller is doing, in its own buttons' names: "A", "RT", "Left stick".
    static func shown(_ buttons: Set<PadProfiles.Input>, axes: [Int: Int], family: Controllers.Family?) -> Shown {
        var lit = buttons.subtracting([.ltfull, .rtfull])
        var l = PadProfiles.Input.allCases.filter { lit.contains($0) }.map { $0.title(family) }
        func far(_ x: Int, _ y: Int) -> Bool { let a = Double(axes[x] ?? 0) / 32767, b = Double(axes[y] ?? 0) / 32767; return a * a + b * b > 0.25 }
        if far(0, 1) { l.append("Left stick"); lit.insert(.ls) }
        if far(2, 3) { l.append("Right stick"); lit.insert(.rs) }
        let lt = PadProfiles.Input.lt.title(family), rt = PadProfiles.Input.rt.title(family)
        if (axes[4] ?? 0) > 6000, !l.contains(lt) { l.append(lt); lit.insert(.lt) }
        if (axes[5] ?? 0) > 6000, !l.contains(rt) { l.append(rt); lit.insert(.rt) }
        return (l, lit)
    }

    // MARK: Windows games

    /// The players file Windows games' controller driver reads (controller-players).
    private var lastPlayersText = ""
    private func writePlayers() {
        let list = connected.compactMap { c -> ControllerRoster.Connected? in
            guard c.vendorID != 0, let reg = c.registryID else { return nil }
            return .init(key: c.key, registryID: reg, vendorID: c.vendorID, productID: c.productID, serial: c.serial, nth: c.nth)
        }
        let text = roster.playersText(connected: list)
        guard text != lastPlayersText else { return }
        lastPlayersText = text
        try? NokPaths.ensure(ControllerRoster.playersFile.deletingLastPathComponent())
        try? Data(text.utf8).write(to: ControllerRoster.playersFile, options: .atomic)
    }
    /// What the Windows games running now report: the player each controller became.
    private func readWindowsPlayers() {
        var seen: [String: Int] = [:]
        let hosts = Set(DesktopPad.shared.games.compactMap { WineTools.hostContents(for: $0)?.standardizedFileURL })
        for host in hosts {
            let f = host.appendingPathComponent("SharedSupport/nokcandu/pad-players-seen")
            guard let t = try? String(contentsOf: f, encoding: .utf8), let pid = ControllerRoster.seenProcess(t), kill(pid_t(pid), 0) == 0 else { continue }
            seen.merge(ControllerRoster.parseSeen(t)) { a, _ in a }
        }
        if seen != windowsPlayers { windowsPlayers = seen; invalidate() }
    }

    /// The player a controller is in Windows games: what a running game reported, or else what it would be.
    func windowsPlayer(_ key: String) -> (player: Int, reported: Bool) {
        if let n = windowsPlayers[key] { return (n, true) }
        let gamepads = connected.filter { $0.kind == .gamepad && $0.vendorID != 0 }.map(\.key)
        return (roster.players(connected: gamepads)[key] ?? 1, false)
    }
}
