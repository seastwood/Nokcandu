// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import IOKit.hid
import AppKit
import NokcanduCore

/// Takes DualShock 4, DualSense, Xbox Wireless (Bluetooth) and Switch Pro controllers from macOS while a profile
/// maps them for a Mac app, so the app sees only what the profile sends (its keys and mouse, or Nokcandu's virtual
/// controller) and not the real controller as well. macOS has nothing like Windows' HidHide; the controller is
/// opened exclusively (kIOHIDOptionsTypeSeizeDevice), which stops other apps' reads, and Nokcandu reads its reports
/// itself (TakeoverPadDecoder). Released the moment the profile stops applying, so the controller is macOS's again.
@MainActor
final class ControllerTakeover {
    static let shared = ControllerTakeover()
    static let preferenceKey = "controllerTakeover"
    /// On unless turned off in Controller Settings.
    static var preference: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey); shared.apply() }
    }

    private var manager: IOHIDManager?
    private struct Pad { let device: IOHIDDevice; var decoder: TakeoverPadDecoder; let buffer: UnsafeMutablePointer<UInt8>; var reports = 0 }
    private var pads: [UInt64: Pad] = [:]
    /// Devices taken over, by macOS's id: the rest of Nokcandu leaves them (and their GameController copies) alone.
    private(set) var owned: Set<UInt64> = []
    /// The kinds taken over right now, for ignoring their GameController copies.
    private(set) var ownedKinds: Set<String> = []
    private(set) var wanted = false
    private(set) var status = "Off"

    /// Whether the profile in front wants its controllers taken from macOS.
    func want(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        apply()
    }

    /// Opening or closing happens on the next turn of the run loop, never right away: a layer change that asks for
    /// it arrives from inside one of these controllers' own report callbacks, and closing a device while macOS is
    /// delivering its report aborts the app (IOHIDDeviceClass unlocks a lock the close already released).
    private func apply() {
        guard !applyQueued else { return }
        applyQueued = true
        DispatchQueue.main.async { [self] in
            applyQueued = false
            let on = wanted && Self.preference
            let plan = on ? matching() : []
            if manager != nil, !on || plan != opened { close() }
            if on, manager == nil, !plan.isEmpty { open(plan) }
        }
    }
    private var applyQueued = false

    /// Controllers set to a player other than 1 (by connection location): never taken, so Mac games get them as
    /// they are. Set by the Controllers panel's choices.
    private(set) var excluded: Set<Int> = []
    func exclude(_ locations: Set<Int>) {
        guard locations != excluded || (!locations.isEmpty && manager != nil) else { return }
        excluded = locations
        apply()
    }
    private var opened: [[String: Int]] = []
    /// What to take: every controller of the kinds taken, or with some left out, each of the others by location.
    private func matching() -> [[String: Int]] {
        let all = TakeoverPad.matching.map { [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product] }
        guard !excluded.isEmpty else { return all }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(m, all as CFArray)
        let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
        return devices.compactMap { d -> [String: Int]? in
            let location = Self.int(d, kIOHIDLocationIDKey)
            guard !excluded.contains(location) else { return nil }
            return [kIOHIDVendorIDKey: Self.int(d, kIOHIDVendorIDKey), kIOHIDProductIDKey: Self.int(d, kIOHIDProductIDKey), kIOHIDLocationIDKey: location]
        }.sorted { ($0[kIOHIDLocationIDKey] ?? 0) < ($1[kIOHIDLocationIDKey] ?? 0) }
    }

    private func open(_ plan: [[String: Int]]) {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        opened = plan
        IOHIDManagerSetDeviceMatchingMultiple(m, plan as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, d in MainActor.assumeIsolated { ControllerTakeover.shared.added(d) } }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, d in MainActor.assumeIsolated { ControllerTakeover.shared.removed(d) } }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        manager = m
        status = r == kIOReturnSuccess ? "Taking controllers from macOS while a profile maps them"
            : String(format: "macOS refused exclusive access (0x%08x); controllers stay shared", r)
        ControllerLog.add("Controller takeover: \(status)")
    }

    private func close() {
        for id in Array(pads.keys) { drop(id) }
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        manager = nil
        opened = []
        status = "Off"
        ControllerLog.add("Controller takeover: controllers given back to macOS")
        MappedGamepads.shared.refresh()
        DesktopPad.shared.attach()
    }

    private static func int(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? Int) ?? 0 }

    private func added(_ d: IOHIDDevice) {
        let id = HIDRegistryID.of(d)
        guard pads[id] == nil, let kind = TakeoverPad.find(vendor: Self.int(d, kIOHIDVendorIDKey), product: Self.int(d, kIOHIDProductIDKey)) else { return }
        let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? ""
        let bluetooth = transport.localizedCaseInsensitiveContains("bluetooth")
        let size = max(64, Self.int(d, kIOHIDMaxInputReportSizeKey))
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        var decoder = TakeoverPadDecoder(kind, bluetooth: bluetooth)
        pads[id] = Pad(device: d, decoder: decoder, buffer: buffer)
        IOHIDDeviceRegisterInputReportCallback(d, buffer, size, { ctx, result, _, _, _, bytes, count in
            guard result == kIOReturnSuccess, count >= 2 else { return }
            let report = Array(UnsafeBufferPointer(start: bytes, count: count))
            let id = UInt64(UInt(bitPattern: ctx))
            ControllerReportDiagnostics.shared.record("owned:\(id)", label: "Taken-over controller · HID reports")
            MainActor.assumeIsolated { ControllerTakeover.shared.report(report, id: id) }
        }, UnsafeMutableRawPointer(bitPattern: UInt(id)))
        if let feature = kind.enableFeature {
            nonisolated(unsafe) let device = d
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes = [UInt8](repeating: 0, count: 64); bytes[0] = feature
                var length = CFIndex(bytes.count)
                _ = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(feature), &bytes, &length)
            }
        }
        // The Switch Pro takes its set-up one command at a time.
        for (n, out) in decoder.start().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                guard let p = self?.pads[id] else { return }
                HIDOutput.send(out, to: p.device)
            }
        }
        pads[id]?.decoder = decoder
        // A controller that sends nothing after its start-up gets it once more, and the log says so either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, var p = self.pads[id], p.reports == 0 else { return }
            ControllerLog.add("Controller takeover: \(kind.name) sent nothing for 2 s after being taken; starting it again")
            nonisolated(unsafe) let device = p.device
            for (n, out) in p.decoder.start().enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { HIDOutput.send(out, to: device) }
            }
            self.pads[id] = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let p = self?.pads[id] else { return }
                ControllerLog.add("Controller takeover: \(kind.name) " + (p.reports == 0 ? "still sends nothing; unplug and reconnect it, or turn off taking controllers in Controller Settings" : "is sending again"))
            }
        }
        owned.insert(id)
        ownedKinds.formUnion(kind.gameControllerCategories)
        ControllerLog.add("Controller takeover: \(kind.name) (\(bluetooth ? "Bluetooth" : "USB")) taken from macOS")
        if let note = Self.steamInputNote(for: [kind]), !steamNoteLogged { steamNoteLogged = true; ControllerLog.add("Controller takeover: \(note)") }
        MappedGamepads.shared.refresh()
        DesktopPad.shared.attach()
    }

    private func removed(_ d: IOHIDDevice) {
        let id = HIDRegistryID.of(d)
        guard pads[id] != nil else { return }
        ControllerLog.add("Controller takeover: \(pads[id]?.decoder.kind.name ?? "controller") disconnected")
        drop(id)
        MappedGamepads.shared.refresh()
        DesktopPad.shared.attach()
    }

    private func drop(_ id: UInt64) {
        guard let p = pads.removeValue(forKey: id) else { return }
        IOHIDDeviceRegisterInputReportCallback(p.device, p.buffer, 0, nil, nil)
        p.buffer.deallocate()
        owned.remove(id)
        ownedKinds = Set(pads.values.flatMap(\.decoder.kind.gameControllerCategories))
        rumbleEnds[id] = nil
        MappedGamepads.shared.publish("owned:\(id)", name: "", buttons: nil, axes: [:])
    }

    private func report(_ bytes: [UInt8], id: UInt64) {
        guard var pad = pads[id] else { return }
        pad.reports += 1
        let s = pad.decoder.decode(bytes)
        let repairs = pad.decoder.repairs(after: bytes, at: ProcessInfo.processInfo.systemUptime)
        pads[id] = pad
        if !repairs.isEmpty {
            for (n, out) in repairs.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { HIDOutput.send(out, to: pad.device) }
            }
            repairCount += 1
            if repairCount <= 3 || repairCount % 20 == 0 {
                ControllerLog.add("Controller takeover: \(pad.decoder.kind.name) had its \(bytes.first == 0x3F ? "full reports" : "motion") switched off by another program; turned back on (\(repairCount) time\(repairCount == 1 ? "" : "s"))")
            }
        }
        guard let s else { return }
        if let g = s.gyro, let a = s.acceleration { MappedGamepads.shared.publishMotion("owned:\(id)", gyro: g, acceleration: a) }
        MappedGamepads.shared.publish("owned:\(id)", name: pad.decoder.kind.name, buttons: s.buttons, axes: s.axes)
    }

    /// Buzzes one controller; a newer rumble replaces the stop of an older one.
    func rumble(_ id: UInt64, strength: Double, seconds: Double) {
        guard pads[id] != nil, strength.isFinite, strength > 0 else { return }
        send(id, strength)
        let length = max(0.05, min(1, seconds))
        rumbleEnds[id] = Date().addingTimeInterval(length)
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.01) { [self] in
            guard let end = rumbleEnds[id], end <= Date() else { return }
            rumbleEnds[id] = nil
            send(id, 0)
        }
    }
    private var rumbleEnds: [UInt64: Date] = [:]
    private var repairCount = 0
    private func send(_ id: UInt64, _ strength: Double) {
        guard var p = pads[id] else { return }
        let r = p.decoder.rumble(low: strength, high: strength)
        pads[id] = p
        HIDOutput.send(r, to: p.device)
    }

    private var steamNoteLogged = false
    /// When Steam is running and its Steam Input reads one of these controllers: what to change, else nil.
    static func steamInputNote(for kinds: Set<TakeoverPad>) -> String? {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.valvesoftware.steam" }) else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/config/config.vdf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let both = SteamInputSupport.readsItself(configVDF: text).intersection(kinds)
        guard !both.isEmpty else { return nil }
        let names = both.map(\.name).sorted().joined(separator: ", ")
        return "Steam Input is set to read the \(names). If a Steam game doesn't see the controller in a layer that hands it over, that's why: Steam loses the controller when Nokcandu takes it and doesn't pick it back up. Turn Steam Input off for that game (Properties → Controller → Disable Steam Input) or for these controllers (Steam → Settings → Controller)."
    }
    var ownedKindsSet: Set<TakeoverPad> { Set(pads.values.map(\.decoder.kind)) }

    /// Whether a GameController controller is a copy of one taken over (ignored while it is).
    func isTakenOver(category: String?) -> Bool { category.map { ownedKinds.contains($0) } ?? false }
    var summary: [String] { pads.values.map { "\($0.decoder.kind.name) (\($0.decoder.bluetooth ? "Bluetooth" : "USB")): taken from macOS" }.sorted() }
}
