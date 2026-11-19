import Foundation
import IOKit
import IOKit.hid
import IOUSBHost
import GameController
import NokcanduCore

/// Nintendo Switch 2 Pro and GameCube controllers by USB cable (Switch2Controller). They send nothing until
/// started over their second interface's bulk endpoints, which this does through macOS's USB host framework; their
/// reports then arrive as HID reports and are published as a controller (MappedGamepads). A controller macOS's
/// own controller support already reads is left to it.
@MainActor
final class Switch2USB {
    static let shared = Switch2USB()

    private final class Pad {
        let device: IOHIDDevice
        let product: Int
        let name: String
        var calibration = Switch2Controller.Calibration()
        var started = false
        var rumble = Switch2Controller.Rumble(), rumbleUntil = Date.distantPast, lastRumbleSent = Date.distantPast
        var last: Switch2Controller.State?
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        init(device: IOHIDDevice, product: Int, name: String) { self.device = device; self.product = product; self.name = name }
        deinit { buffer.deallocate() }
    }
    private var manager: IOHIDManager?
    private var pads: [UInt64: Pad] = [:]
    private let queue = DispatchQueue(label: "Nokcandu.Switch2USB")

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(m, Switch2Controller.products.map {
            [kIOHIDVendorIDKey: Switch2Controller.vendor, kIOHIDProductIDKey: $0] as [String: Any]
        } as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, d in MainActor.assumeIsolated { Switch2USB.shared.added(d) } }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { _, _, _, d in MainActor.assumeIsolated { Switch2USB.shared.removed(d) } }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(m, 0)
        manager = m
    }

    private static func id(_ d: IOHIDDevice) -> UInt64 { HIDRegistryID.of(d) }
    private static func number(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }

    private func added(_ d: IOHIDDevice) {
        let id = Self.id(d)
        guard pads[id] == nil else { return }
        let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? ""
        guard transport.uppercased() == "USB" else { return }      // Bluetooth isn't supported by this protocol
        let product = Self.number(d, kIOHIDProductIDKey)
        let fallback = [Switch2Controller.pro: "Switch 2 Pro Controller", Switch2Controller.gameCube: "GameCube Controller (Switch 2)",
                        Switch2Controller.joyConLeft: "Joy-Con 2 (L)", Switch2Controller.joyConRight: "Joy-Con 2 (R)"]
        let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? fallback[product] ?? "Switch 2 Controller"
        let location = Self.number(d, kIOHIDLocationIDKey)
        // macOS's own controller support reads it: leave it there.
        if GCController.controllers().contains(where: { $0.vendorName == name && $0.extendedGamepad != nil }) { return }
        let pad = Pad(device: d, product: product, name: name)
        pads[id] = pad
        IOHIDDeviceRegisterInputReportCallback(d, pad.buffer, 128, { ctx, result, _, _, _, bytes, count in
            guard result == kIOReturnSuccess, let ctx, count >= 64 else { return }
            let report = Array(UnsafeBufferPointer(start: bytes, count: count))
            let id = UInt64(UInt(bitPattern: ctx))
            ControllerReportDiagnostics.shared.record("switch2:\(id)", label: "Switch 2 · HID reports")
            MainActor.assumeIsolated { Switch2USB.shared.report(report, id: id) }
        }, UnsafeMutableRawPointer(bitPattern: UInt(id)))
        ControllerLog.add("Controller: \(name) found by USB (\(String(format: "%04X", product))); starting it")
        let vendor = Switch2Controller.vendor
        queue.async {
            let result = Self.startUp(vendor: vendor, product: product, location: location)
            Task { @MainActor in
                guard let pad = self.pads[id] else { return }
                if let result {
                    pad.calibration = result; pad.started = true
                    ControllerLog.add("Controller: \(name) started")
                } else {
                    ControllerLog.add("Controller: \(name) couldn't be started over USB (its second interface wasn't available)")
                }
            }
        }
    }
    private func removed(_ d: IOHIDDevice) {
        let id = Self.id(d)
        guard let pad = pads.removeValue(forKey: id) else { return }
        if Switch2Controller.isJoyCon(pad.product) { pad.last = nil; publishJoyCons() }
        else { MappedGamepads.shared.publish("switch2:\(id)", name: pad.name, buttons: nil, axes: [:]) }
        ControllerLog.add("Controller: \(pad.name) disconnected")
    }
    private func report(_ bytes: [UInt8], id: UInt64) {
        guard let pad = pads[id], let s = Switch2Controller.decode(bytes, product: pad.product, calibration: pad.calibration) else { return }
        sendRumble(pad)
        if Switch2Controller.isJoyCon(pad.product) { pad.last = s; publishJoyCons(); return }
        if s.gyro.contains(where: { $0 != 0 }) || s.acceleration.contains(where: { $0 != 0 }) {
            MappedGamepads.shared.publishMotion("switch2:\(id)", gyro: s.gyro, acceleration: s.acceleration)
        }
        MappedGamepads.shared.publish("switch2:\(id)", name: pad.name, buttons: s.buttons, axes: s.axes)
    }

    /// Joy-Con 2 are one controller between them (the first left and right connected), under the left one's
    /// name when there is one.
    private var joyConSource: String?
    private func publishJoyCons() {
        let left = pads.filter { $0.value.product == Switch2Controller.joyConLeft }.min { $0.key < $1.key }
        let right = pads.filter { $0.value.product == Switch2Controller.joyConRight }.min { $0.key < $1.key }
        let source = "switch2:\((left ?? right).map { String($0.key) } ?? "")"
        if let old = joyConSource, old != source { MappedGamepads.shared.publish(old, name: "", buttons: nil, axes: [:]) }
        guard let s = Switch2Controller.merge(left: left?.value.last, right: right?.value.last) else { joyConSource = nil; return }
        joyConSource = source
        let name = left != nil && right != nil ? "Joy-Con 2 (L/R)" : (left ?? right)!.value.name
        if s.gyro.contains(where: { $0 != 0 }) || s.acceleration.contains(where: { $0 != 0 }) {
            MappedGamepads.shared.publishMotion(source, gyro: s.gyro, acceleration: s.acceleration)
        }
        MappedGamepads.shared.publish(source, name: name, buttons: s.buttons, axes: s.axes)
    }

    /// Buzzes one controller (both Joy-Con for the pair's source) for `seconds`.
    func rumble(_ id: UInt64, strength: Double, seconds: Double) {
        guard let pad = pads[id], strength.isFinite, strength > 0 else { return }
        let targets = Switch2Controller.isJoyCon(pad.product) ? pads.values.filter { Switch2Controller.isJoyCon($0.product) } : [pad]
        let level = UInt16(max(0, min(1, strength)) * 65535)
        for p in targets {
            p.rumble.low = level; p.rumble.high = level
            p.rumbleUntil = Date().addingTimeInterval(max(0.05, min(1, seconds)))
            sendRumble(p)
        }
    }
    /// Rumble goes out with the input reports while it's on (at most every 12 ms), then once more to stop it.
    private func sendRumble(_ pad: Pad) {
        let now = Date()
        if pad.rumble.isOn, now >= pad.rumbleUntil { pad.rumble.low = 0; pad.rumble.high = 0 }
        else if !pad.rumble.isOn { return }
        guard now.timeIntervalSince(pad.lastRumbleSent) >= 0.012 || !pad.rumble.isOn else { return }
        pad.lastRumbleSent = now
        HIDOutput.send(pad.rumble.report(product: pad.product), to: pad.device)
        if !pad.rumble.isOn { pad.lastRumbleSent = .distantPast }
    }

    /// The start-up over interface 1's bulk endpoints, with the stick calibration read on the way. nil: no
    /// interface 1 to use (another program has it, or it isn't this kind of controller).
    nonisolated private static func startUp(vendor: Int, product: Int, location: Int) -> Switch2Controller.Calibration? {
        guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return nil }
        matching["idVendor"] = vendor; matching["idProduct"] = product; matching["bInterfaceNumber"] = 1
        // This controller's own interface, when several of the same kind are plugged in (else the first found).
        var service: io_service_t = 0
        if location != 0, let m = matching.mutableCopy() as? NSMutableDictionary {
            m["locationID"] = location
            service = IOServiceGetMatchingService(kIOMainPortDefault, m as CFDictionary)
        }
        if service == 0 { service = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary) }
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let iface = try? IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil) else { return nil }
        defer { iface.destroy() }
        var outAddress = 0, inAddress = 0
        var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
        while let ep = IOUSBGetNextEndpointDescriptor(iface.configurationDescriptor, iface.interfaceDescriptor, current) {
            let e = ep.pointee
            if e.bmAttributes & 0x03 == 2 {             // bulk
                if e.bEndpointAddress & 0x80 != 0 { inAddress = Int(e.bEndpointAddress) } else { outAddress = Int(e.bEndpointAddress) }
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard outAddress != 0, inAddress != 0,
              let outPipe = try? iface.copyPipe(withAddress: outAddress), let inPipe = try? iface.copyPipe(withAddress: inAddress) else { return nil }
        func send(_ bytes: [UInt8]) -> Bool {
            let data = NSMutableData(bytes: bytes, length: bytes.count)
            var n = 0
            return (try? outPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 1)) != nil
        }
        func receive(_ length: Int) -> [UInt8] {
            var out: [UInt8] = []
            while out.count < length {
                let data = NSMutableData(length: 64)!
                var n = 0
                guard (try? inPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 0.1)) != nil, n > 0 else { break }
                out += Array(UnsafeRawBufferPointer(start: data.bytes, count: n))
                if n < 64 { break }
            }
            return out
        }
        var c = Switch2Controller.Calibration()
        func flash(_ address: UInt32) -> [UInt8]? {
            guard send(Switch2Controller.flashRead(address)) else { return nil }
            return Switch2Controller.flashData(receive(0x50))
        }
        if let d = flash(Switch2Controller.factoryLeftStick), let s = Switch2Controller.stick(d[0x28...]) { c.left = s }
        if let d = flash(Switch2Controller.factoryRightStick), let s = Switch2Controller.stick(d[0x28...]) { c.right = s }
        if let d = flash(Switch2Controller.userLeftStick), d[0] == 0xb2, d[1] == 0xa1, let s = Switch2Controller.stick(d[2...]) { c.left = s }
        if let d = flash(Switch2Controller.userRightStick), d[0] == 0xb2, d[1] == 0xa1, let s = Switch2Controller.stick(d[2...]) { c.right = s }
        if product == Switch2Controller.gameCube, let d = flash(Switch2Controller.triggerZero) { c.leftTriggerZero = Int(d[0]); c.rightTriggerZero = Int(d[1]) }
        for command in Switch2Controller.startup {
            guard send(command) else { return nil }
            _ = receive(64)
        }
        if send(Switch2Controller.playerLight) { _ = receive(8) }
        return c
    }
}
