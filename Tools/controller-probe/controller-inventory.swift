// Passive HID descriptions only. No device opens, reports, serials or commands.
import Foundation
import IOKit.hid
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil)
let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
func number(_ d: IOHIDDevice, _ key: String) -> Int { (IOHIDDeviceGetProperty(d,key as CFString) as? NSNumber)?.intValue ?? 0 }
for d in devices {
    let page=number(d,kIOHIDPrimaryUsagePageKey),usage=number(d,kIOHIDPrimaryUsageKey)
    let vid=number(d,kIOHIDVendorIDKey),pid=number(d,kIOHIDProductIDKey)
    guard (page==1 && [4,5].contains(usage)) || vid==0x28de else { continue }
    let name=IOHIDDeviceGetProperty(d,kIOHIDProductKey as CFString) as? String ?? "unknown"
    let transport=IOHIDDeviceGetProperty(d,kIOHIDTransportKey as CFString) as? String ?? "unknown"
    print(String(format:"%04X:%04X %@ transport=%@ usage=%04X:%04X inputBytes=%d",vid,pid,name,transport,page,usage,number(d,kIOHIDMaxInputReportSizeKey)))
    var service = IOHIDDeviceGetService(d)
    if service != 0 { IOObjectRetain(service) }
    for depth in 0..<5 where service != 0 {
        var cls=[CChar](repeating:0,count:128); IOObjectGetClass(service,&cls)
        print(" parent[\(depth)] class=\(String(cString:cls))")
        if depth == 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service,&props,kCFAllocatorDefault,0)==KERN_SUCCESS,
               let dict=props?.takeRetainedValue() as? [String:Any] {
                print(" description keys="+dict.keys.filter { k in ["Virtual","Physical","Transport","Provider","Product","Vendor","Usage"].contains { k.localizedCaseInsensitiveContains($0) } }.sorted().joined(separator:","))
            }
        }
        var parent:io_registry_entry_t=0
        let ok=IORegistryEntryGetParentEntry(service,kIOServicePlane,&parent)
        IOObjectRelease(service);service=ok==KERN_SUCCESS ? parent : 0
    }
    if service != 0 { IOObjectRelease(service) }
}
