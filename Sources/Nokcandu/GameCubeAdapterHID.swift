import Foundation
import IOKit.hid
import NokcanduCore

/// The GameCube controller adapter (GameCubeAdapter): each port's controller is published as a controller of its
/// own (MappedGamepads), so four players can use it.
@MainActor
final class GameCubeAdapterHID {
    static let shared = GameCubeAdapterHID()
    private var manager: IOHIDManager?
    private var buffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var ports: [UInt64: Set<Int>] = [:]
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var motors: [UInt64: [UInt8]] = [:]
    private var rumbleEnds: [String: Date] = [:]

    /// Buzzes one port's controller (its motor is on or off) for `seconds`. The adapter needs its second USB
    /// plug (power) for rumble.
    func rumble(_ id: UInt64, port: Int, strength: Double, seconds: Double) {
        guard devices[id] != nil, (0..<4).contains(port), strength.isFinite, strength > 0.1 else { return }
        set(id, port: port, on: true)
        let key = "\(id):\(port)", end = Date().addingTimeInterval(max(0.05, min(1, seconds)))
        rumbleEnds[key] = end
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, min(1, seconds)) + 0.01) { [self] in
            guard rumbleEnds[key] == end else { return }
            rumbleEnds[key] = nil
            set(id, port: port, on: false)
        }
    }
    private func set(_ id: UInt64, port: Int, on: Bool) {
        guard let d = devices[id] else { return }
        var m = motors[id] ?? [0, 0, 0, 0]
        m[port] = on ? 1 : 0
        motors[id] = m
        HIDOutput.send(GameCubeAdapter.rumble(m), to: d)
    }

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: GameCubeAdapter.vendor, kIOHIDProductIDKey: GameCubeAdapter.product] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, d in MainActor.assumeIsolated { GameCubeAdapterHID.shared.added(d) } }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, d in MainActor.assumeIsolated { GameCubeAdapterHID.shared.removed(d) } }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, 0)
        manager = m
    }
    private static func id(_ d: IOHIDDevice) -> UInt64 { var v: UInt64 = 0; IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &v); return v }

    private func added(_ d: IOHIDDevice) {
        let id = Self.id(d)
        guard buffers[id] == nil else { return }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers[id] = buffer
        devices[id] = d
        IOHIDDeviceRegisterInputReportCallback(d, buffer, 64, { ctx, result, _, _, _, bytes, count in
            guard result == kIOReturnSuccess, count >= 37 else { return }
            let report = Array(UnsafeBufferPointer(start: bytes, count: count))
            let id = UInt64(UInt(bitPattern: ctx))
            MainActor.assumeIsolated { GameCubeAdapterHID.shared.report(report, id: id) }
        }, UnsafeMutableRawPointer(bitPattern: UInt(id)))
        var start = GameCubeAdapter.start
        let ok = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(start[0]), &start, start.count) == kIOReturnSuccess
        ControllerLog.add("Controller: GameCube controller adapter found\(ok ? "" : " (its start command wasn't accepted)")")
    }
    private func removed(_ d: IOHIDDevice) {
        let id = Self.id(d)
        for port in ports[id] ?? [] { MappedGamepads.shared.publish("gamecube:\(id):\(port)", name: "", buttons: nil, axes: [:]) }
        ports[id] = nil
        devices[id] = nil; motors[id] = nil
        buffers.removeValue(forKey: id)?.deallocate()
    }
    private func report(_ bytes: [UInt8], id: UInt64) {
        guard let list = GameCubeAdapter.decode(bytes) else { return }
        for (port, c) in list.enumerated() {
            let source = "gamecube:\(id):\(port)", had = ports[id, default: []].contains(port)
            if let c {
                if !had { ports[id, default: []].insert(port); ControllerLog.add("Controller: GameCube controller in adapter port \(port + 1)") }
                MappedGamepads.shared.publish(source, name: "GameCube Controller (port \(port + 1))", buttons: c.buttons, axes: c.axes)
            } else if had {
                ports[id]?.remove(port)
                MappedGamepads.shared.publish(source, name: "", buttons: nil, axes: [:])
            }
        }
    }
}
