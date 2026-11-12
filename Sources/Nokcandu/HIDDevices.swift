import Foundation
import IOKit.hid
import GameController
import NokcanduCore
import NokcanduPadEngine

extension Notification.Name { static let hidDevicesChanged = Notification.Name("NokcanduHIDDevicesChanged") }

/// Joysticks, throttles, pedals, wheels, button boxes and controllers, read straight from macOS (no permission
/// needed). Buttons and axes are numbered exactly the way SDL numbers them — sorted by what each one is (its HID
/// usage) — because that's how Windows games in Wine see the device, so "Axis 3" means the same control in both.
@MainActor
final class HIDDevices: ObservableObject {
    static let shared = HIDDevices()

    struct Info: Identifiable, Hashable {
        let id: UInt64                  // macOS's id for this connection
        let name: String
        let vendorID: Int, productID: Int
        var nth: Int                    // among identical devices, in the order they were connected
        var gamepad: Bool               // macOS's controller support knows it (then it's read like the controller)
        let buttonCount: Int
        let axisNames: [String]
        let hasHat: Bool
        func matches(_ d: PadProfiles.Device) -> Bool { vendorID == d.vendorID && productID == d.productID && nth == (d.nth ?? 0) }
        var device: PadProfiles.Device {
            PadProfiles.Device(name: name, productName: name, vendorID: vendorID, productID: productID, nth: nth == 0 ? nil : nth,
                               gamepad: gamepad ? true : nil, buttonCount: buttonCount, axisNames: axisNames, hasHat: hasHat)
        }
    }
    enum Event { case button(Int, Bool), hat(Int), axis(Int, Int) }

    @Published private(set) var connected: [Info] = []

    private var manager: IOHIDManager?
    private struct Element { let kind: Int; let index: Int; let min: Int; let max: Int }   // kind 0 button, 1 hat, 2 axis
    private var elements: [UInt64: [UInt32: Element]] = [:]
    private var refs: [UInt64: IOHIDDevice] = [:]
    private var listeners: [UUID: (Info, Event) -> Void] = [:]
    private var hats: [UInt64: Int] = [:]

    func listen(_ f: @escaping (Info, Event) -> Void) -> UUID {
        start()
        let id = UUID(); listeners[id] = f; return id
    }
    func stopListening(_ id: UUID?) { if let id { listeners[id] = nil } }

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [[String: Int]] = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, device in
            MainActor.assumeIsolated { HIDDevices.shared.added(device) }
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, device in
            MainActor.assumeIsolated { HIDDevices.shared.removed(device) }
        }, nil)
        IOHIDManagerRegisterInputValueCallback(m, { _, _, _, value in
            MainActor.assumeIsolated { HIDDevices.shared.value(value) }
        }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        // A controller macOS supports is read through that instead (it may connect a moment after its device appears).
        for n in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { HIDDevices.shared.renumber() } }
        }
    }

    private static func registryID(_ d: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &id)
        return id
    }
    private static func int(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }

    private func added(_ d: IOHIDDevice) {
        let id = Self.registryID(d)
        let raw = (IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        let list = raw.map { e in HIDLayout.Element(type: Int(IOHIDElementGetType(e).rawValue), page: Int(IOHIDElementGetUsagePage(e)), usage: Int(IOHIDElementGetUsage(e)),
                                                    cookie: UInt32(IOHIDElementGetCookie(e)), min: IOHIDElementGetLogicalMin(e), max: IOHIDElementGetLogicalMax(e)) }
        let l = HIDLayout.layout(list)
        var map: [UInt32: Element] = [:]
        for (i, b) in l.buttons.enumerated() where i < PadProfiles.Device.maxButtons { map[b.cookie] = Element(kind: 0, index: i, min: b.min, max: b.max) }
        for (i, a) in l.axes.enumerated() where i < PadProfiles.Device.maxAxes { map[a.cookie] = Element(kind: 2, index: i, min: a.min, max: a.max) }
        if let h = l.hat { map[h.cookie] = Element(kind: 1, index: 0, min: h.min, max: h.max) }
        elements[id] = map; refs[id] = d
        let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "Device"
        let info = Info(id: id, name: name, vendorID: Self.int(d, kIOHIDVendorIDKey), productID: Self.int(d, kIOHIDProductIDKey), nth: 0,
                        gamepad: false, buttonCount: min(l.buttons.count, PadProfiles.Device.maxButtons),
                        axisNames: Array(l.axes.map(\.name).prefix(PadProfiles.Device.maxAxes)), hasHat: l.hat != nil)
        connected.removeAll { $0.id == id }
        connected.append(info)
        renumber()
    }
    private func removed(_ d: IOHIDDevice) {
        let id = Self.registryID(d)
        elements[id] = nil; refs[id] = nil; hats[id] = nil
        connected.removeAll { $0.id == id }
        renumber()
    }
    /// Identical devices are told apart by connection order; macOS's controller support decides which are controllers.
    func renumber() {
        var list = connected.sorted { $0.id < $1.id }
        let gcNames = GCController.controllers().filter { $0.extendedGamepad != nil }.compactMap(\.vendorName)
        for i in list.indices {
            list[i].nth = list[..<i].filter { $0.vendorID == list[i].vendorID && $0.productID == list[i].productID }.count
            list[i].gamepad = gcNames.contains(list[i].name)
        }
        connected = list
        NotificationCenter.default.post(name: .hidDevicesChanged, object: nil)
    }

    private func value(_ v: IOHIDValue) {
        let el = IOHIDValueGetElement(v)
        let d = IOHIDElementGetDevice(el)
        let id = Self.registryID(d)
        guard let e = elements[id]?[UInt32(IOHIDElementGetCookie(el))], let info = connected.first(where: { $0.id == id }), !info.gamepad else { return }
        let raw = IOHIDValueGetIntegerValue(v)
        let ev: Event
        switch e.kind {
        case 0: ev = .button(e.index, raw > e.min)
        case 1:
            let b = HIDLayout.hatBits(raw, min: e.min, max: e.max)
            if hats[id] == b { return }
            hats[id] = b; ev = .hat(b)
        default:
            ev = .axis(e.index, HIDLayout.axisValue(raw, min: e.min, max: e.max))
        }
        for f in listeners.values { f(info, ev) }
    }
}

/// Feeds a profile's devices into an engine: joysticks and the like from HIDDevices, other controllers from
/// macOS's controller support (read like the main controller). Used by Nokcandu's own remapping and the editor's test.
@MainActor
final class DeviceFeed {
    private(set) var devices: [PadProfiles.Device] = []
    private let engine: () -> OpaquePointer?
    private var token: UUID?
    /// Something on a device was pressed or moved (device id, input key: "b3", "hu", "a2p"…), for picking it by pressing.
    var onInput: ((String, String, Bool) -> Void)?
    var onAxis: ((String, Int, Double) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var connections = PadDeviceConnections()
    private var connectedIDs: [Int: String] = [:]
    var paused = false
    private var lastButtons: [String: Bool] = [:], lastAxes: [String: Int] = [:]

    init(engine: @escaping () -> OpaquePointer?) { self.engine = engine }

    func set(_ d: [PadProfiles.Device], always: Bool = false) {
        devices = Array(d.prefix(4))
        lastButtons = [:]; lastAxes = [:]
        if (!devices.isEmpty || always), token == nil {
            token = HIDDevices.shared.listen { [weak self] info, ev in self?.hid(info, ev) }
        } else if devices.isEmpty && !always, let t = token { HIDDevices.shared.stopListening(t); token = nil }
    }
    func stop() {
        for slot in connections.update([:]) {
            if let e = engine() { pe_release_device(e, Int32(slot), DesktopPad.now()) }
            if let id = connectedIDs[slot] { onDisconnect?(id) }
        }
        connectedIDs = [:]
        HIDDevices.shared.stopListening(token); token = nil
    }
    func reconcile() {
        var sources: [Int: String] = [:], ids: [Int: String] = [:]
        for (c, slot, d) in gamepadSlots() {
            sources[Int(slot)] = "gc:" + String(describing: ObjectIdentifier(c)); ids[Int(slot)] = d.id
        }
        for (i, d) in devices.enumerated() where !d.isGamepad {
            if let info = HIDDevices.shared.connected.first(where: { $0.matches(d) }) {
                sources[i + 1] = "hid:\(info.id)"; ids[i + 1] = d.id
            }
        }
        for slot in connections.update(sources) {
            if let e = engine() { pe_release_device(e, Int32(slot), DesktopPad.now()) }
            if let id = connectedIDs[slot] { onDisconnect?(id) }
            let prefix = "\(slot)."
            lastButtons = lastButtons.filter { !$0.key.hasPrefix(prefix) }
            lastAxes = lastAxes.filter { !$0.key.hasPrefix(prefix) }
        }
        connectedIDs = ids
    }

    private func slot(of info: HIDDevices.Info) -> (Int32, PadProfiles.Device)? {
        devices.enumerated().first { !$0.element.isGamepad && info.matches($0.element) }.map { (Int32($0.offset + 1), $0.element) }
    }
    private func hid(_ info: HIDDevices.Info, _ ev: HIDDevices.Event) {
        guard !paused else { return }
        let s = slot(of: info)
        let now = DesktopPad.now()
        switch ev {
        case .button(let n, let down):
            if let s, let e = engine() { pe_dev_button(e, s.0, Int32(n), down, now) }
            if let s { onInput?(s.1.id, "b\(n)", down) }
        case .hat(let bits):
            if let s, let e = engine() { pe_dev_hat(e, s.0, Int32(bits), now) }
            if let s { for (i, k) in PadProfiles.Device.hatKeys.enumerated() { onInput?(s.1.id, k, bits & [1, 2, 4, 8][i] != 0) } }
        case .axis(let n, let v):
            if let s, let e = engine() { pe_dev_axis(e, s.0, Int32(n), Int32(v), now) }
            if let s { onAxis?(s.1.id, n, Double(v) / 32767) }
        }
    }

    /// Other controllers that are this profile's devices, and their slots.
    func gamepadSlots() -> [(GCController, Int32, PadProfiles.Device)] {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        var out: [(GCController, Int32, PadProfiles.Device)] = []
        for (i, d) in devices.enumerated() where d.isGamepad {
            let same = pads.filter { ($0.vendorName ?? "") == d.productName }
            if same.indices.contains(d.nth ?? 0) { out.append((same[d.nth ?? 0], Int32(i + 1), d)) }
        }
        return out
    }
    /// The controllers that are the main controller (not one of the profile's devices).
    func mainControllers() -> [GCController] {
        let taken = Set(gamepadSlots().map { ObjectIdentifier($0.0) })
        return GCController.controllers().filter { $0.extendedGamepad != nil && !taken.contains(ObjectIdentifier($0)) }
    }
    func sampleGamepads() {
        reconcile()
        for (c, slot, d) in gamepadSlots() {
            if let pad = c.extendedGamepad { read(pad, slot: slot, id: d.id) }
        }
    }
    func attachGamepads() {
        reconcile()
        for (c, slot, d) in gamepadSlots() {
            c.motion?.valueChangedHandler = nil
            c.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in MainActor.assumeIsolated { self?.read(pad, slot: slot, id: d.id) } }
        }
    }
    private func read(_ g: GCExtendedGamepad, slot: Int32, id: String) {
        guard !paused else { return }
        let (buttons, axes) = PadGC.state(g)
        let now = DesktopPad.now()
        for (i, down) in buttons {
            let n = Int(pe_input_named(i.rawValue)), k = "\(slot).\(n)"
            if lastButtons[k] != down {
                lastButtons[k] = down
                if let e = engine() { pe_dev_button(e, slot, Int32(n), down, now) }
                onInput?(id, "b\(n)", down)
            }
        }
        for (a, v) in axes {
            let iv = Int(max(-32768, min(32767, v * 32767))), k = "\(slot).\(a)"
            if lastAxes[k] != iv {
                lastAxes[k] = iv
                if let e = engine() { pe_dev_axis(e, slot, a, Int32(iv), now) }
                onAxis?(id, Int(a), Double(v))
            }
        }
    }
    /// A device of the profile is connected now.
    var anyConnected: Bool {
        !gamepadSlots().isEmpty || HIDDevices.shared.connected.contains { i in devices.contains { !$0.isGamepad && i.matches($0) } }
    }
}
