// Aggregate Pro Controller report IDs/lengths only. No raw payloads, commands,
// device-mode changes, input injection or keyboard/mouse interfaces.
import Foundation
import IOKit.hid
final class Shapes {
    var counts: [String: Int] = [:]
    var priorButtons: UInt32?
    var buttonChanges = 0
    var fullReports = 0
    func report(id: UInt32, length: CFIndex, bytes: UnsafeMutablePointer<UInt8>) {
        let key = String(format: "report %02X, length %ld", id, length)
        counts[key, default: 0] += 1
        // SDL's documented full-state framing: report byte, counter, battery, three button bytes.
        if id == 0x30 && length >= 13 && bytes[0] == 0x30 {
            let buttons = UInt32(bytes[3]) | UInt32(bytes[4]) << 8 | UInt32(bytes[5]) << 16
            if let priorButtons { buttonChanges += (priorButtons ^ buttons).nonzeroBitCount }
            priorButtons = buttons; fullReports += 1
        }
    }
}
let counts = Shapes()
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x057e, kIOHIDProductIDKey: 0x2009,
    kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 4] as CFDictionary)
if CommandLine.arguments.contains("--descriptor"),
   let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first,
   let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
    try descriptor.write(to: URL(fileURLWithPath: "/tmp/nokcandu-pro-report-descriptor.bin"))
    print("Static HID descriptor saved locally; no input payloads saved")
}
IOHIDManagerRegisterInputReportCallback(manager, { context, result, _, _, id, bytes, length in
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<Shapes>.fromOpaque(context).takeUnretainedValue().report(id: id, length: length, bytes: bytes)
}, Unmanaged.passUnretained(counts).toOpaque())
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print(String(format: "Description-limited Pro Controller observer open=%08X", result))
if result == kIOReturnSuccess { RunLoop.main.run(until: Date().addingTimeInterval(3)) }
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
for key in counts.counts.keys.sorted() { print("\(key): \(counts.counts[key] ?? 0)") }
print("Full-state reports: \(counts.fullReports); button-bit transitions: \(counts.buttonChanges)")
print("Aggregate receipt only; neither input validity nor Steam exclusivity is established by this observation.")
