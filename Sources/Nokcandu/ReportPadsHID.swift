import Foundation
import IOKit.hid
import NokcanduCore

/// Controllers read with their own full reports (ReportPadDriver: 8BitDo in D-input mode, Stadia, Luna) so their
/// extra buttons, gyro and rumble work. A controller is taken from the generic mapping only once a report it
/// understands has arrived, so one in a mode that sends something else stays a mapped controller.
@MainActor
final class ReportPadsHID {
    static let shared = ReportPadsHID()
    private var manager: IOHIDManager?
    private var buffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private struct Pad { let device: IOHIDDevice; var decoder: ReportPadDecoder }
    private var pads: [UInt64: Pad] = [:]
    /// Devices read here, by macOS's id, so MappedGamepads leaves them.
    private(set) var claimed: Set<UInt64> = []

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(m, ReportPadDriver.matching.map {
            [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product] as CFDictionary } as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, d in MainActor.assumeIsolated { ReportPadsHID.shared.added(d) } }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, d in MainActor.assumeIsolated { ReportPadsHID.shared.removed(d) } }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, 0)
        manager = m
    }
    private static func id(_ d: IOHIDDevice) -> UInt64 { var v: UInt64 = 0; IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(d), &v); return v }
    private static func int(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? Int) ?? 0 }

    private func added(_ d: IOHIDDevice) {
        let id = Self.id(d)
        guard buffers[id] == nil, let driver = ReportPadDriver.find(vendor: Self.int(d, kIOHIDVendorIDKey), product: Self.int(d, kIOHIDProductIDKey)) else { return }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers[id] = buffer
        pads[id] = Pad(device: d, decoder: ReportPadDecoder(driver))
        IOHIDDeviceRegisterInputReportCallback(d, buffer, 64, { ctx, result, _, _, _, bytes, count in
            guard result == kIOReturnSuccess, count >= 2 else { return }
            let report = Array(UnsafeBufferPointer(start: bytes, count: count))
            let id = UInt64(UInt(bitPattern: ctx))
            MainActor.assumeIsolated { ReportPadsHID.shared.report(report, id: id) }
        }, UnsafeMutableRawPointer(bitPattern: UInt(id)))
        if var out = driver.startOutput {
            _ = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(out[0]), &out, out.count)
        }
        // Reading this feature report is what switches some controllers to their full report (as SDL does).
        if let feature = driver.enableFeature {
            var bytes = [UInt8](repeating: 0, count: 64); bytes[0] = feature
            var length = CFIndex(bytes.count)
            _ = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, CFIndex(feature), &bytes, &length)
        }
    }
    private func removed(_ d: IOHIDDevice) {
        let id = Self.id(d)
        if claimed.remove(id) != nil {
            MappedGamepads.shared.publish("report:\(id)", name: "", buttons: nil, axes: [:])
            ControllerLog.add("Controller: \(pads[id]?.decoder.driver.name ?? "controller") disconnected")
        }
        pads[id] = nil
        buffers.removeValue(forKey: id)?.deallocate()
        MappedGamepads.shared.refresh()
    }
    private func report(_ bytes: [UInt8], id: UInt64) {
        guard var pad = pads[id] else { return }
        let s = pad.decoder.decode(bytes)
        pads[id] = pad
        guard let s else { return }
        let name = pad.decoder.driver.name
        if !claimed.contains(id) {
            // Left to macOS's own controller support, or to a profile that reads it as its own device.
            if let info = HIDDevices.shared.connected.first(where: { $0.id == id }),
               info.gamepad || MappedGamepads.shared.excluded.contains(where: { !$0.isGamepad && info.matches($0) }) { return }
            claimed.insert(id)
            ControllerLog.add("Controller: \(name) read with its own report\(s.gyro == nil ? "" : " (gyro on)")")
            MappedGamepads.shared.refresh()
        }
        MappedGamepads.shared.publish("report:\(id)", name: name, buttons: s.buttons, axes: s.axes)
        if let g = s.gyro, let a = s.acceleration { MappedGamepads.shared.publishMotion(gyro: g, acceleration: a) }
    }

    func rumble(strength: Double, seconds: Double) {
        guard !claimed.isEmpty, strength.isFinite, strength > 0 else { return }
        send(low: strength, high: strength)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, min(1, seconds))) { [self] in send(low: 0, high: 0) }
    }
    private func send(low: Double, high: Double) {
        for id in claimed {
            guard let p = pads[id], let r = p.decoder.driver.rumble(low: low, high: high) else { continue }
            // Report ID 0 means the device has none: the bytes after it are the report.
            var bytes = r[0] == 0 ? Array(r.dropFirst()) : r
            _ = IOHIDDeviceSetReport(p.device, kIOHIDReportTypeOutput, CFIndex(r[0]), &bytes, bytes.count)
        }
    }
}
