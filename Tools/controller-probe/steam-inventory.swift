// Description-only Valve inventory. Does not open HID devices or read/write reports.
import Foundation
import IOKit.hid
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x28de] as CFDictionary)
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
func number(_ device: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
}
let rows = devices.map { d in
    let pid = number(d, kIOHIDProductIDKey)
    let page = number(d, kIOHIDPrimaryUsagePageKey), usage = number(d, kIOHIDPrimaryUsageKey)
    let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? "Unknown"
    let input = number(d, kIOHIDMaxInputReportSizeKey), output = number(d, kIOHIDMaxOutputReportSizeKey)
    let feature = number(d, kIOHIDMaxFeatureReportSizeKey)
    let interface = IORegistryEntrySearchCFProperty(IOHIDDeviceGetService(d), kIOServicePlane,
        "bInterfaceNumber" as CFString, kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? NSNumber
    return String(format: "Valve %04X:%04X usage=%04X:%04X transport=%@ report sizes input=%d output=%d feature=%d interface=%d", 0x28de, pid, page, usage, transport, input, output, feature, interface?.intValue ?? -1)
}.sorted()
print("Valve HID interfaces: \(rows.count)")
for row in rows { print(row) }
print("Receiver presence does not prove controller power, pairing or input. No serials, raw reports, feature requests, pairing or mode changes.")
