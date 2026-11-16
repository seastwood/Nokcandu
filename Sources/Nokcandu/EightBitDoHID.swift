import Foundation
import IOKit.hid
import NokcanduCore

/// 8BitDo controllers in D-input mode, read with their own full report (EightBitDoController) so their back
/// paddles, Share and gyro work. A controller is taken from the generic mapping only once a report of that kind
/// has arrived, so one in a mode that sends something else stays a mapped controller.
@MainActor
final class EightBitDoHID {
    static let shared = EightBitDoHID()
    private var manager: IOHIDManager?
    private var buffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var devices: [UInt64: (device: IOHIDDevice, name: String)] = [:]
    /// Devices read here, by macOS's id, so MappedGamepads leaves them.
    private(set) var claimed: Set<UInt64> = []

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(m, EightBitDoController.products.map {
            [kIOHIDVendorIDKey: EightBitDoController.vendor, kIOHIDProductIDKey: $0] as CFDictionary } as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, d in MainActor.assumeIsolated { EightBitDoHID.shared.added(d) } }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, d in MainActor.assumeIsolated { EightBitDoHID.shared.removed(d) } }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, 0)
        manager = m
    }
    private static func id(_ d: IOHIDDevice) -> UInt64 { var v: UInt64 = 0; IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &v); return v }
    private static func product(_ d: IOHIDDevice) -> Int { (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0 }

    private func added(_ d: IOHIDDevice) {
        let id = Self.id(d), product = Self.product(d)
        guard buffers[id] == nil else { return }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers[id] = buffer
        devices[id] = (d, EightBitDoController.names[product] ?? "8BitDo Controller")
        IOHIDDeviceRegisterInputReportCallback(d, buffer, 64, { ctx, result, _, _, _, bytes, count in
            guard result == kIOReturnSuccess, count >= 9 else { return }
            let report = Array(UnsafeBufferPointer(start: bytes, count: count))
            let id = UInt64(UInt(bitPattern: ctx))
            MainActor.assumeIsolated { EightBitDoHID.shared.report(report, id: id) }
        }, UnsafeMutableRawPointer(bitPattern: UInt(id)))
        // Reading this feature report is what switches the controller to its full report (as SDL does).
        if let feature = EightBitDoController.enableFeature(product: product) {
            var bytes = [UInt8](repeating: 0, count: 64); bytes[0] = feature
            var length = CFIndex(bytes.count)
            _ = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, CFIndex(feature), &bytes, &length)
        }
    }
    private func removed(_ d: IOHIDDevice) {
        let id = Self.id(d)
        if claimed.remove(id) != nil {
            MappedGamepads.shared.publish("8bitdo:\(id)", name: "", buttons: nil, axes: [:])
            ControllerLog.add("Controller: \(devices[id]?.name ?? "8BitDo controller") disconnected")
        }
        devices[id] = nil
        buffers.removeValue(forKey: id)?.deallocate()
        MappedGamepads.shared.refresh()
    }
    private func report(_ bytes: [UInt8], id: UInt64) {
        guard let s = EightBitDoController.decode(bytes), let dev = devices[id] else { return }
        if !claimed.contains(id) {
            // Left to macOS's own controller support, or to a profile that reads it as its own device.
            if let info = HIDDevices.shared.connected.first(where: { $0.id == id }),
               info.gamepad || MappedGamepads.shared.excluded.contains(where: { !$0.isGamepad && info.matches($0) }) { return }
            claimed.insert(id)
            ControllerLog.add("Controller: \(dev.name) read with its own report\(s.gyro == nil ? "" : " (gyro on)")")
            MappedGamepads.shared.refresh()
        }
        MappedGamepads.shared.publish("8bitdo:\(id)", name: dev.name, buttons: s.buttons, axes: s.axes)
        if let g = s.gyro, let a = s.acceleration { MappedGamepads.shared.publishMotion(gyro: g, acceleration: a) }
    }

    func rumble(strength: Double, seconds: Double) {
        guard !claimed.isEmpty, strength.isFinite, strength > 0 else { return }
        let level = UInt8(max(0, min(1, strength)) * 255)
        send(EightBitDoController.rumble(low: level, high: level))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, min(1, seconds))) { [self] in
            send(EightBitDoController.rumble(low: 0, high: 0))
        }
    }
    private func send(_ r: [UInt8]) {
        for id in claimed { guard let d = devices[id]?.device else { continue }
            var bytes = r; _ = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(r[0]), &bytes, bytes.count) }
    }
}
