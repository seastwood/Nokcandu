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
            ControllerReportDiagnostics.shared.record("report:\(id)", label: "Report controller · HID reports")
            MainActor.assumeIsolated { ReportPadsHID.shared.report(report, id: id) }
        }, UnsafeMutableRawPointer(bitPattern: UInt(id)))
        // Nothing is sent to a controller macOS's own support or a profile's own device reads: a mode switch
        // would take it from them. macOS's support can connect a controller a moment after its device appears, so
        // the start-up waits for that before it decides.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in startUp(id) }
    }
    /// macOS's own controller support reads it, or a profile reads it as its own device: it isn't read here.
    private func leftAlone(_ id: UInt64) -> Bool {
        guard let info = HIDDevices.shared.connected.first(where: { $0.id == id }) else { return false }
        return info.gamepad || MappedGamepads.shared.excluded.contains { !$0.isGamepad && info.matches($0) }
    }
    /// Devices found to be someone else's (leftAlone), so their reports are skipped without decoding them.
    private var left: Set<UInt64> = []
    /// The devices changed (MappedGamepads.refresh): macOS's support may have connected a controller after its
    /// first reports were read here, or a profile may have taken a device as its own. Those are given up.
    func recheck() {
        left = []
        for id in claimed.filter({ leftAlone($0) }) {
            claimed.remove(id)
            MappedGamepads.shared.publish("report:\(id)", name: "", buttons: nil, axes: [:])
            ControllerLog.add("Controller: \(pads[id]?.decoder.name ?? "controller") left to macOS's controller support or a profile")
        }
    }
    private func startUp(_ id: UInt64) {
        guard let d = pads[id]?.device, let driver = pads[id]?.decoder.driver, !leftAlone(id) else { return }
        if let out = driver.startOutput { HIDOutput.send(out, to: d) }
        for out in pads[id]?.decoder.start() ?? [] { Self.send(out, to: d) }
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
            ControllerLog.add("Controller: \(pads[id]?.decoder.name ?? "controller") disconnected")
        }
        pads[id] = nil; left.remove(id)
        buffers.removeValue(forKey: id)?.deallocate()
        MappedGamepads.shared.refresh()
    }
    private func report(_ bytes: [UInt8], id: UInt64) {
        guard !left.contains(id), var pad = pads[id] else { return }
        let s = pad.decoder.decode(bytes)
        let replies = pad.decoder.takeOutputs()
        pads[id] = pad
        for out in replies { Self.send(out, to: pad.device) }
        guard let s else { return }
        let name = pad.decoder.name
        if !claimed.contains(id) {
            // Left to macOS's own controller support, or to a profile that reads it as its own device.
            if leftAlone(id) { left.insert(id); return }
            claimed.insert(id)
            ControllerLog.add("Controller: \(name) read with its own report\(s.gyro == nil ? "" : " (gyro on)")")
            MappedGamepads.shared.refresh()
        }
        if let g = s.gyro, let a = s.acceleration { MappedGamepads.shared.publishMotion("report:\(id)", gyro: g, acceleration: a) }
        MappedGamepads.shared.publish("report:\(id)", name: name, buttons: s.buttons, axes: s.axes)
    }

    /// Buzzes one controller; a newer rumble replaces the stop of an older one.
    func rumble(_ id: UInt64, strength: Double, seconds: Double) {
        guard claimed.contains(id), strength.isFinite, strength > 0 else { return }
        send(id, low: strength, high: strength)
        rumbleEnds[id] = Date().addingTimeInterval(max(0.05, min(1, seconds)))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, min(1, seconds)) + 0.01) { [self] in
            guard let end = rumbleEnds[id], end <= Date() else { return }
            rumbleEnds[id] = nil
            send(id, low: 0, high: 0)
        }
    }
    private var rumbleEnds: [UInt64: Date] = [:]
    private func send(_ id: UInt64, low: Double, high: Double) {
        guard let p = pads[id], let r = p.decoder.driver.rumble(low: low, high: high) else { return }
        Self.send(r, to: p.device)
    }
    /// An output report; a first byte (report ID) of 0 means the device has none, so the bytes after it are sent.
    private static func send(_ r: [UInt8], to d: IOHIDDevice) { HIDOutput.send(r, to: d) }
}
