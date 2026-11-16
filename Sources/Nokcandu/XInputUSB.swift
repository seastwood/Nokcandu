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
    private var iterator: io_iterator_t = 0
    private let lock = NSLock()
    private var running: Set<UInt64> = []
    private var started = false

    @MainActor func start() {
        guard !started else { return }
        started = true
        guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return }
        matching["bInterfaceClass"] = XInputController.interfaceClass
        matching["bInterfaceSubClass"] = XInputController.interfaceSubclass
        matching["bInterfaceProtocol"] = XInputController.interfaceProtocol
        let p = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(p, DispatchQueue(label: "Nokcandu.XInputUSB.match"))
        port = p
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, matching as CFDictionary, { _, it in
            XInputUSB.shared.matched(it)
        }, nil, &iterator)
        matched(iterator)
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
        guard inAddress != 0, let inPipe = try? iface.copyPipe(withAddress: inAddress) else { return }
        if outAddress != 0, let outPipe = try? iface.copyPipe(withAddress: outAddress) {
            let data = NSMutableData(bytes: XInputController.playerLight, length: XInputController.playerLight.count)
            var n = 0
            _ = try? outPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 1)
        }
        let source = "xinput:\(id)"
        ControllerLog.add("Controller: \(product) read as an Xbox 360 (XInput) controller")
        var last: (Set<PadProfiles.Input>, [Int: Int])?
        while true {
            let data = NSMutableData(length: 32)!
            var n = 0
            do { try inPipe.__sendIORequest(with: data, bytesTransferred: &n, completionTimeout: 0) }
            catch { break }                              // unplugged
            let bytes = Array(UnsafeRawBufferPointer(start: data.bytes, count: n))
            guard let s = XInputController.decode(bytes) else { continue }
            if let last, last.0 == s.buttons, last.1 == s.axes { continue }
            last = (s.buttons, s.axes)
            DispatchQueue.main.async { MainActor.assumeIsolated { MappedGamepads.shared.publish(source, name: product, buttons: s.buttons, axes: s.axes) } }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { MappedGamepads.shared.publish(source, name: product, buttons: nil, axes: [:]) } }
        ControllerLog.add("Controller: \(product) (XInput) disconnected")
    }
}
