// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import IOKit.hid
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
    private struct Pad { let device: IOHIDDevice; var decoder: TakeoverPadDecoder; let buffer: UnsafeMutablePointer<UInt8> }
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

    private func apply() {
        let on = wanted && Self.preference
        if on, manager == nil { open() } else if !on, manager != nil { close() }
    }

    private func open() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(m, TakeoverPad.matching.map {
            [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product] as CFDictionary } as CFArray)
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
        owned.insert(id)
        ownedKinds.formUnion(kind.gameControllerCategories)
        ControllerLog.add("Controller takeover: \(kind.name) (\(bluetooth ? "Bluetooth" : "USB")) taken from macOS")
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

    /// Whether a GameController controller is a copy of one taken over (ignored while it is).
    func isTakenOver(category: String?) -> Bool { category.map { ownedKinds.contains($0) } ?? false }
    var summary: [String] { pads.values.map { "\($0.decoder.kind.name) (\($0.decoder.bluetooth ? "Bluetooth" : "USB")): taken from macOS" }.sorted() }
}
