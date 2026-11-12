// One bounded original wired-controller haptic burst. No settings/mapping changes.
import Foundation
import IOKit.hid
@main struct HapticProbe {
 static func main() {
  let side=CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1
  guard var bytes=SteamControllerHaptics.pulse(side:side,strength:0.35) else {return}
  let manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
  IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x28de,kIOHIDProductIDKey:0x1102,kIOHIDDeviceUsagePageKey:0xff00,kIOHIDDeviceUsageKey:1] as CFDictionary)
  guard IOHIDManagerOpen(manager,0)==kIOReturnSuccess else {print("Cannot inspect original wired controller");return}
  defer{IOHIDManagerClose(manager,0)}
  guard let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,devices.count==1,let device=devices.first else {print("Requires exactly one original wired controller");return}
  let start=ProcessInfo.processInfo.systemUptime
  let result=IOHIDDeviceSetReport(device,kIOHIDReportTypeFeature,0,&bytes,bytes.count)
  print(String(format:"Short haptic burst side=%d result=%08X elapsed=%.3f ms",side,result,(ProcessInfo.processInfo.systemUptime-start)*1000))
 }
}
