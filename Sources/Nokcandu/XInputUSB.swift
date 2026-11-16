import Foundation
import IOKit
import IOUSBHost
import NokcanduCore

/// Wired Xbox 360 controllers and other XInput controllers (XInputController): macOS has no driver for them, so
/// their USB interface is free for Nokcandu to read. Each is read on a thread of its own and published as a
/// standard controller (MappedGamepads). A controller another driver has (an installed Xbox 360 driver, say) can't
/// be opened and is left to it.
final class XInputUSB: @unchecked Sendable {
    static let shared = XInputUSB()
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0, gipIterator: io_iterator_t = 0, wirelessIterator: io_iterator_t = 0
    private let lock = NSLock()
    private var running: Set<UInt64> = []
    private var started = false
    /// Each connected controller's way to send to it, and whether it speaks GIP.
    private enum Kind { case wired, gip, wireless }
    private var senders: [UInt64: (kind: Kind, send: ([UInt8]) -> Void)] = [:]
    private var gipSequence: UInt8 = 2

    /// Buzzes every controller read here for `seconds` (at most one), at `strength` (0…1).
    func rumble(strength: Double, seconds: Double) {
        lock.lock(); let list = Array(senders.values); lock.unlock()
        guard !list.isEmpty, strength.isFinite, strength > 0 else { return }
        let level = UInt8(max(0, min(1, strength)) * 255)
        for s in list { s.send(rumbleReport(s.kind, level)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.05, min(1, seconds))) { [self] in
            for s in list { s.send(rumbleReport(s.kind, 0)) }
        }
    }
    private func rumbleReport(_ kind: Kind, _ level: UInt8) -> [UInt8] {
        switch kind {
        case .gip: lock.lock(); gipSequence &+= 1; let q = gipSequence; lock.unlock(); return GIPController.rumble(strong: level, weak: level, sequence: q)
        case .wired: return XInputController.rumble(low: level, high: level)
        case .wireless: return XInputController.Wireless.rumble(low: level, high: level)
        }
    }

    @MainActor func start() {
        guard !started else { return }
        started = true
        func matching(_ c: Int, _ sub: Int, _ proto: Int) -> CFDictionary? {
            guard let m = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return nil }
            m["bInterfaceClass"] = c; m["bInterfaceSubClass"] = sub; m["bInterfaceProtocol"] = proto
            return m as CFDictionary
        }
        let p = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(p, DispatchQueue(label: "Nokcandu.XInputUSB.match"))
        port = p
        if let m = matching(XInputController.interfaceClass, XInputController.interfaceSubclass, XInputController.interfaceProtocol) {
            IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, m, { _, it in XInputUSB.shared.matched(it) }, nil, &iterator)
            matched(iterator)
        }
        // Xbox One and Series (GIP) — only when macOS doesn't drive them (then the interface can't be opened).
        if let m = matching(GIPController.interfaceClass, GIPController.interfaceSubclass, GIPController.interfaceProtocol) {
            IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, m, { _, it in XInputUSB.shared.matched(it) }, nil, &gipIterator)
            matched(gipIterator)
        }
        // The Xbox 360 Wireless Receiver: one interface per controller slot.
        if let m = matching(XInputController.interfaceClass, XInputController.interfaceSubclass, XInputController.Wireless.interfaceProtocol) {
            IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, m, { _, it in XInputUSB.shared.matched(it) }, nil, &wirelessIterator)
            matched(wirelessIterator)
        }
    }

    private func matched(_ it: io_iterator_t) {
        while case let service = IOIteratorNext(it), service != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            lock.lock(); let fresh = running.insert(id).inserted; lock.unlock()
            guard fresh else { IOObjectRelease(service); continue }
            Thread.detachNewThread { [self] in
                read(service, id: id)
                IOObjectRelease(service)
                lock.lock(); running.remove(id); lock.unlock()
            }
        }
    }

    private func read(_ service: io_service_t, id: UInt64) {
        let product = (IORegistryEntrySearchCFProperty(service, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault,
                                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String) ?? "Xbox 360 controller"
        guard let iface = try? IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil) else {
            ControllerLog.add("Controller: \(product) (XInput) is in use by another driver; left to it")
            return
        }
        defer { iface.destroy() }
        var inAddress = 0, outAddress = 0
        var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
        while let ep = IOUSBGetNextEndpointDescriptor(iface.configurationDescriptor, iface.interfaceDescriptor, current) {
            let e = ep.pointee
            if e.bmAttributes & 0x03 == 3 {             // interrupt
                if e.bEndpointAddress & 0x80 != 0 { if inAddress == 0 { inAddress = Int(e.bEndpointAddress) } } else if outAddress == 0 { outAddress = Int(e.bEndpointAddress) }
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        let proto = (IORegistryEntryCreateCFProperty(service, "bInterfaceProtocol" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        let kind: Kind = proto == GIPController.interfaceProtocol ? .gip : proto == XInputController.Wireless.interfaceProtocol ? .wireless : .wired
        let gip = kind == .gip
        guard inAddress != 0, let inPipe = try? iface.copyPipe(withAddress: inAddress) else { return }
        let outPipe = outAddress != 0 ? try? iface.copyPipe(withAddress: outAddress) : nil
        func send(_ bytes: [UInt8]) {
            guard let outPipe else { return }
            let data = NSMutableData(bytes: bytes, length: bytes.count)
            var n = 0
            _ = try? outPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 1)
        }
        let sendQueue = DispatchQueue(label: "Nokcandu.XInputUSB.send.\(id)")
        let source = "xinput:\(id)"
        if kind == .wireless {
            readWireless(iface, inPipe: inPipe, send: send, sendQueue: sendQueue, id: id, source: source)
            return
        }
        send(gip ? GIPController.powerOn : XInputController.playerLight)
        lock.lock(); senders[id] = (kind, { bytes in sendQueue.async { send(bytes) } }); lock.unlock()
        defer { lock.lock(); senders[id] = nil; lock.unlock() }
        ControllerLog.add("Controller: \(product) read as an \(gip ? "Xbox One/Series (GIP)" : "Xbox 360 (XInput)") controller")
        var gipDecoder = GIPController.Decoder()
        var last: (Set<PadProfiles.Input>, [Int: Int])?
        while true {
            let data = NSMutableData(length: 32)!
            var n = 0
            do { try inPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 0) }
            catch { break }                              // unplugged
            let bytes = Array(UnsafeRawBufferPointer(start: data.bytes, count: n))
            if gip, let ack = GIPController.acknowledge(bytes) { send(ack) }
            guard let s = gip ? gipDecoder.decode(bytes, last: last.map { ($0.0, $0.1) }) : XInputController.decode(bytes) else { continue }
            if let last, last.0 == s.buttons, last.1 == s.axes { continue }
            last = (s.buttons, s.axes)
            DispatchQueue.main.async { MainActor.assumeIsolated { MappedGamepads.shared.publish(source, name: product, buttons: s.buttons, axes: s.axes) } }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { MappedGamepads.shared.publish(source, name: product, buttons: nil, axes: [:]) } }
        ControllerLog.add("Controller: \(product) (XInput) disconnected")
    }

    /// One slot of the Xbox 360 Wireless Receiver: a controller comes and goes while the receiver stays.
    private func readWireless(_ iface: IOUSBHostInterface, inPipe: IOUSBHostPipe, send: @escaping ([UInt8]) -> Void,
                              sendQueue: DispatchQueue, id: UInt64, source: String) {
        let slot = Int(iface.interfaceDescriptor.pointee.bInterfaceNumber) / 2
        let name = "Xbox 360 Wireless Controller"
        var connected = false
        func drop() {
            guard connected else { return }
            connected = false
            lock.lock(); senders[id] = nil; lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { MappedGamepads.shared.publish(source, name: name, buttons: nil, axes: [:]) } }
            ControllerLog.add("Controller: \(name) (receiver slot \(slot + 1)) disconnected")
        }
        defer { drop() }
        send(XInputController.Wireless.presence)
        var last: (Set<PadProfiles.Input>, [Int: Int])?
        while true {
            let data = NSMutableData(length: 32)!
            var n = 0
            do { try inPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 0) }
            catch { break }                              // receiver unplugged
            switch XInputController.Wireless.decode(Array(UnsafeRawBufferPointer(start: data.bytes, count: n))) {
            case .connected(true)?:
                guard !connected else { continue }
                connected = true; last = nil
                send(XInputController.Wireless.light(slot: slot))
                lock.lock(); senders[id] = (.wireless, { bytes in sendQueue.async { send(bytes) } }); lock.unlock()
                ControllerLog.add("Controller: \(name) connected to the receiver (slot \(slot + 1))")
            case .connected(false)?: drop()
            case .state(let buttons, let axes)?:
                if !connected {           // a state without the connect message: it's there all the same
                    connected = true
                    lock.lock(); senders[id] = (.wireless, { bytes in sendQueue.async { send(bytes) } }); lock.unlock()
                }
                if let last, last.0 == buttons, last.1 == axes { continue }
                last = (buttons, axes)
                DispatchQueue.main.async { MainActor.assumeIsolated { MappedGamepads.shared.publish(source, name: name, buttons: buttons, axes: axes) } }
            case nil: continue
            }
        }
    }
}
