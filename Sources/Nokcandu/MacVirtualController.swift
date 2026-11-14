// SPDX-License-Identifier: GPL-3.0-only
// A virtual Xbox, DualShock 4 or Switch Pro Controller that Mac apps and games see, fed by a Nokcandu profile's
// mapped controller. Built on CoreHID's HIDVirtualDevice (macOS 15 and later), which macOS only allows for an app
// signed with Apple's com.apple.developer.hid.virtual.device entitlement (see build-app.sh). Reports and replies
// come from the shared virtual-controller core (NokcanduPadEngine/virtualpad.c).
import AppKit
import CoreHID
import NokcanduCore
import NokcanduPadEngine
import os

@MainActor final class MacVirtualControllers: ObservableObject {
    static let shared = MacVirtualControllers()

    enum Status: Equatable {
        case off
        case running(PresentedController)
        /// macOS refused to create it.
        case refused(String)
    }
    @Published private(set) var status: Status = .off
    private var kind: PresentedController?
    private var pad: AnyObject?            // MacVirtualPad on macOS 15+
    private let shared = MacVirtualPadState()

    /// macOS allows virtual controllers for this app: the entitlement is in its signature.
    static var entitled: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return ents["com.apple.developer.hid.virtual.device"] as? Bool == true
    }

    static var unavailableReason: String? {
        if #unavailable(macOS 15) { return "Virtual controllers for Mac games need macOS 15 or later." }
        if !entitled { return "macOS only allows virtual controllers in apps Apple has granted its virtual-device entitlement. This build of Nokcandu doesn't have it yet, so Mac games see the real controller." }
        return nil
    }

    /// Creates, changes or removes the virtual controller. nil removes it.
    func configure(_ next: PresentedController?) {
        guard next != kind else { return }
        kind = next
        if #available(macOS 15, *) { (pad as? MacVirtualPad)?.stop() }
        pad = nil
        shared.reset()
        guard let next else { status = .off; return }
        if let why = Self.unavailableReason { status = .refused(why); return }
        if #available(macOS 15, *) {
            guard let p = MacVirtualPad(kind: next, state: shared, rumble: { strong, weak in
                Task { @MainActor in DesktopPad.shared.rumbleProfileController(strength: max(strong, weak), seconds: 0.25) }
            }) else {
                status = .refused("macOS didn't create the virtual \(next.title).")
                return
            }
            pad = p
            p.start()
            status = .running(next)
        }
    }

    var active: Bool { if case .running = status { return true }; return false }

    // The profile's controller output (SDL numbering, like the pad engine's sink).
    func button(_ b: Int, _ down: Bool) { if active { shared.button(b, down) } }
    func axis(_ a: Int, _ v: Int) { if active { shared.axis(a, v) } }
    func motion(gyro: (Double, Double, Double), accel: (Double, Double, Double)) { if active { shared.motion(gyro: gyro, accel: accel) } }
}

/// The mapped controller's latest state, shared with the report task.
final class MacVirtualPadState: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var state = vp_state()
    init() { reset() }
    func reset() { os_unfair_lock_lock(&lock); state = vp_state(); state.accel.1 = 9.80665; os_unfair_lock_unlock(&lock) }
    func button(_ b: Int, _ down: Bool) {
        guard (0..<32).contains(b) else { return }
        os_unfair_lock_lock(&lock)
        if down { state.buttons |= 1 << UInt32(b) } else { state.buttons &= ~(1 << UInt32(b)) }
        os_unfair_lock_unlock(&lock)
    }
    func axis(_ a: Int, _ v: Int) {
        guard (0..<6).contains(a) else { return }
        os_unfair_lock_lock(&lock)
        withUnsafeMutableBytes(of: &state.axes) { $0.bindMemory(to: Int16.self)[a] = Int16(clamping: v) }
        os_unfair_lock_unlock(&lock)
    }
    func motion(gyro: (Double, Double, Double), accel: (Double, Double, Double)) {
        os_unfair_lock_lock(&lock)
        state.gyro = (Float(gyro.0), Float(gyro.1), Float(gyro.2))
        state.accel = (Float(accel.0 * 9.80665), Float(accel.1 * 9.80665), Float(accel.2 * 9.80665))
        os_unfair_lock_unlock(&lock)
    }
    var snapshot: vp_state { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return state }
}

@available(macOS 15, *)
final class MacVirtualPad: HIDVirtualDeviceDelegate, @unchecked Sendable {
    let device: HIDVirtualDevice
    private let state: MacVirtualPadState
    private var core = vp_device()
    private let coreLock = NSLock()
    private var task: Task<Void, Never>?
    private let rumble: @Sendable (Double, Double) -> Void
    private let interval: Int

    init?(kind: PresentedController, state: MacVirtualPadState, rumble: @escaping @Sendable (Double, Double) -> Void) {
        let k: Int32 = switch kind { case .xbox: Int32(VP_XBOX); case .dualShock4: Int32(VP_DS4); case .switchPro: Int32(VP_SWITCH_PRO) }
        var length = 0
        guard let p = vp_descriptor(k, &length) else { return nil }
        let props = HIDVirtualDevice.Properties(descriptor: Data(bytes: p, count: length), vendorID: UInt32(vp_vendor(k)), productID: UInt32(vp_product(k)),
                                                transport: kind == .xbox ? .bluetooth : .usb, product: String(cString: vp_name(k)),
                                                manufacturer: String(cString: vp_manufacturer(k)), uniqueID: "nokcandu-virtual-\(kind.rawValue)")
        guard let d = HIDVirtualDevice(properties: props) else { return nil }
        device = d
        self.state = state
        self.rumble = rumble
        interval = Int(vp_report_interval_ms(k))
        vp_init(&core, k, 0x5a)
    }

    func start() {
        let device = self.device
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await device.activate(delegate: self!)
            while !Task.isCancelled, let self {
                var report = [UInt8](repeating: 0, count: 64)
                var s = self.state.snapshot
                let n = self.coreLock.withLock { vp_input_report(&self.core, &s, &report, 64) }
                if n > 0 { try? await device.dispatchInputReport(data: Data(report.prefix(n)), timestamp: .now) }
                try? await Task.sleep(for: .milliseconds(self.interval))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?, data: Data) async throws {
        var bytes = [UInt8](data)
        if let id, bytes.first != id.rawValue { bytes.insert(id.rawValue, at: 0) }
        final class Out { var reports: [[UInt8]] = [] }
        let out = Out()
        var s = state.snapshot
        let (changed, strong, weak): (Bool, Double, Double) = coreLock.withLock {
            vp_output(&core, &s, bytes, bytes.count, { ctx, p, n in
                Unmanaged<Out>.fromOpaque(ctx!).takeUnretainedValue().reports.append(Array(UnsafeBufferPointer(start: p, count: n)))
            }, Unmanaged.passUnretained(out).toOpaque())
            defer { core.rumble_changed = false }
            return (core.rumble_changed, Double(core.rumble_strong) / 65535, Double(core.rumble_weak) / 65535)
        }
        if changed { rumble(strong, weak) }
        for r in out.reports { try await device.dispatchInputReport(data: Data(r), timestamp: .now) }
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?, maxSize: Int) async throws -> Data {
        var out = [UInt8](repeating: 0, count: 64)
        let n = coreLock.withLock { vp_feature(&core, id?.rawValue ?? 0, &out, min(64, maxSize)) }
        return Data(out.prefix(n))
    }
}
