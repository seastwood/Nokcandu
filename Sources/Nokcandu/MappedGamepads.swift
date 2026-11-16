import Foundation
import NokcanduCore

/// Controllers macOS's own controller support doesn't know, made into standard controllers with SDL's community
/// mappings (`GamepadMapping`): many generic, older and third-party gamepads. They then work like any controller
/// in profiles. A device a profile already uses as one of its own devices ("Add Device") is left to that profile,
/// so nothing set up that way changes.
@MainActor
final class MappedGamepads {
    static let shared = MappedGamepads()

    struct Pad { let info: HIDDevices.Info; let mapping: GamepadMapping; var buttons: [Bool]; var axes: [Int]; var hat = 0 }
    private(set) var pads: [UInt64: Pad] = [:]
    /// Called with a pad's source name ("hidmap:<id>"), its held inputs and axes, whenever it changes; nil inputs:
    /// it went away.
    private var listeners: [UUID: (String, Set<PadProfiles.Input>?, [Int: Int]) -> Void] = [:]
    private var token: UUID?
    private var observer: NSObjectProtocol?
    /// Devices a profile reads as its own devices: not made into controllers.
    var excluded: [PadProfiles.Device] = [] { didSet { refresh() } }

    var sources: Set<String> { Set(pads.keys.map { "hidmap:\($0)" }).union(native.keys) }
    var names: [String] { (pads.values.map(\.info.name) + native.values.map(\.name)).sorted() }
    /// Controllers Nokcandu reads with a driver of its own (Switch2USB): their latest state, by source.
    struct Native { var name: String; var buttons: Set<PadProfiles.Input>; var axes: [Int: Int] }
    private(set) var native: [String: Native] = [:]
    private var motionListeners: [UUID: ([Float], [Float]) -> Void] = [:]
    var isEmpty: Bool { pads.isEmpty && native.isEmpty }

    /// A native driver's controller changed (nil buttons: it went away).
    func publish(_ source: String, name: String, buttons: Set<PadProfiles.Input>?, axes: [Int: Int]) {
        if let buttons { native[source] = Native(name: name, buttons: buttons, axes: axes) } else { native[source] = nil }
        for f in listeners.values { f(source, buttons, axes) }
    }
    /// Its motion: gyro in rad/s and acceleration in g, in Nokcandu's axes.
    func publishMotion(gyro: [Float], acceleration: [Float]) { for f in motionListeners.values { f(gyro, acceleration) } }
    func listenMotion(_ f: @escaping ([Float], [Float]) -> Void) -> UUID { let id = UUID(); motionListeners[id] = f; return id }

    func listen(_ f: @escaping (String, Set<PadProfiles.Input>?, [Int: Int]) -> Void) -> UUID {
        start()
        let id = UUID(); listeners[id] = f
        for (key, p) in pads { let s = p.mapping.state(buttons: p.buttons, axes: p.axes, hat: p.hat); f("hidmap:\(key)", s.buttons, s.axes) }
        for (key, n) in native { f(key, n.buttons, n.axes) }
        return id
    }
    func stopListening(_ id: UUID?) { if let id { listeners[id] = nil } }

    func start() {
        guard token == nil else { return }
        token = HIDDevices.shared.listen { [weak self] info, ev in self?.event(info, ev) }
        Switch2USB.shared.start()
        XInputUSB.shared.start()
        observer = NotificationCenter.default.addObserver(forName: .hidDevicesChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MappedGamepads.shared.refresh() }
        }
        refresh()
    }

    func refresh() {
        let now = HIDDevices.shared.connected.filter { info in
            !info.gamepad && !excluded.contains { !$0.isGamepad && info.matches($0) }
                && !(info.vendorID == Switch2Controller.vendor && Switch2Controller.products.contains(info.productID))
                && GamepadMapping.find(vendor: info.vendorID, product: info.productID) != nil
        }
        let ids = Set(now.map(\.id))
        for (id, p) in pads where !ids.contains(id) {
            pads[id] = nil
            ControllerLog.add("Controller: \(p.info.name) (mapped) disconnected")
            for f in listeners.values { f("hidmap:\(id)", nil, [:]) }
        }
        for info in now where pads[info.id] == nil {
            guard let m = GamepadMapping.find(vendor: info.vendorID, product: info.productID) else { continue }
            pads[info.id] = Pad(info: info, mapping: m, buttons: Array(repeating: false, count: max(32, info.buttonCount)), axes: Array(repeating: 0, count: max(8, info.axisNames.count)))
            ControllerLog.add("Controller: \(info.name) (\(String(format: "%04X:%04X", info.vendorID, info.productID))) read as a controller with the community mapping “\(m.name)”")
            // A PlayStation 3 controller by USB sends nothing until told to (SDL's PS3 driver, as every PS3 does).
            if info.vendorID == 0x054C, info.productID == 0x0268 {
                let ok = HIDDevices.shared.setFeature(info.id, [0xF4, 0x42, 0x0C, 0x00, 0x00])
                ControllerLog.add("Controller: PlayStation 3 controller \(ok ? "started" : "start-up command not accepted")")
            }
        }
    }

    private func event(_ info: HIDDevices.Info, _ ev: HIDDevices.Event) {
        guard var p = pads[info.id] else { return }
        switch ev {
        case .button(let n, let d): guard p.buttons.indices.contains(n), p.buttons[n] != d else { return }; p.buttons[n] = d
        case .hat(let b): guard p.hat != b else { return }; p.hat = b
        case .axis(let n, let v): guard p.axes.indices.contains(n), p.axes[n] != v else { return }; p.axes[n] = v
        }
        pads[info.id] = p
        let s = p.mapping.state(buttons: p.buttons, axes: p.axes, hat: p.hat)
        for f in listeners.values { f("hidmap:\(info.id)", s.buttons, s.axes) }
    }
}
