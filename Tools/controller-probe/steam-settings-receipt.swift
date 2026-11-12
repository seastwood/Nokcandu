// Original wired Steam Controller: queries selected settings by default.
// --test-mode performs a two-second volatile mode change, then verifies restoration.
// Never resets mappings, pairs devices or changes firmware. No identifiers logged.
import Foundation
import IOKit.hid
let manager = IOHIDManagerCreate(kCFAllocatorDefault,0)
IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x28de,kIOHIDProductIDKey:0x1102,kIOHIDDeviceUsagePageKey:0xff00,kIOHIDDeviceUsageKey:1] as CFDictionary)
guard IOHIDManagerOpen(manager,0) == kIOReturnSuccess else { fatalError("Cannot open controller inventory") }
defer { IOHIDManagerClose(manager,0) }
guard let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,devices.count==1,let device=devices.first else { print("Requires exactly one original wired Steam Controller"); exit(1) }
let tags: [UInt8] = [7,8,9,48,49] // trackpad modes, lizard mode, IMU, packet version
var request=[UInt8](repeating:0,count:64)
request[0]=0x89; request[1]=UInt8(tags.count*3)
for (index,tag) in tags.enumerated() { request[2+index*3]=tag }
let sent=IOHIDDeviceSetReport(device,kIOHIDReportTypeFeature,0,&request,request.count)
guard sent == kIOReturnSuccess else { print("Read-settings query failed: \(sent)");exit(2) }
for _ in 0..<10 {
 var response=[UInt8](repeating:0,count:64); var length=64
 let got=IOHIDDeviceGetReport(device,kIOHIDReportTypeFeature,0,&response,&length)
 if got == kIOReturnSuccess,length>=2,response[0]==0x89 {
  let payload=Int(response[1])
  guard payload>0,payload%3==0,payload+2<=length else { print("Read-settings reply has invalid bounds");exit(2) }
  var values: [UInt8:UInt16]=[:]
  for offset in stride(from:2,to:payload+2,by:3) {
   let tag=response[offset]
   guard tags.contains(tag),values[tag]==nil else { print("Unexpected or repeated setting tag");exit(2) }
   values[tag]=UInt16(response[offset+1])|UInt16(response[offset+2])<<8
  }
  for tag in tags { if let value=values[tag] { print("setting[\(tag)]=\(value)") } }
  guard values.count==tags.count else { exit(2) }
  if CommandLine.arguments.contains("--test-mode") {
   func write(_ settings: [UInt8:UInt16]) -> IOReturn {
    var bytes=[UInt8](repeating:0,count:64)
    bytes[0]=0x87; bytes[1]=UInt8(settings.count*3)
    for (i,tag) in settings.keys.sorted().enumerated() {
     let value=settings[tag]!; bytes[2+i*3]=tag; bytes[3+i*3]=UInt8(value&255);bytes[4+i*3]=UInt8(value>>8)
    }
    return IOHIDDeviceSetReport(device,kIOHIDReportTypeFeature,0,&bytes,bytes.count)
   }
   func readBack() -> [UInt8:UInt16]? {
    var request=[UInt8](repeating:0,count:64);request[0]=0x89;request[1]=UInt8(tags.count*3)
    for (i,t) in tags.enumerated(){request[2+i*3]=t}
    guard IOHIDDeviceSetReport(device,kIOHIDReportTypeFeature,0,&request,64)==kIOReturnSuccess else{return nil}
    for _ in 0..<10 {
     var bytes=[UInt8](repeating:0,count:64);var size=64
     if IOHIDDeviceGetReport(device,kIOHIDReportTypeFeature,0,&bytes,&size)==kIOReturnSuccess,size>=2,bytes[0]==0x89 {
      let count=Int(bytes[1]);guard count>0,count%3==0,count+2<=size else{return nil}
      var out:[UInt8:UInt16]=[:]
      for i in stride(from:2,to:count+2,by:3){guard tags.contains(bytes[i]),out[bytes[i]]==nil else{return nil};out[bytes[i]]=UInt16(bytes[i+1])|UInt16(bytes[i+2])<<8}
      return out.count==tags.count ? out:nil
     }
     Thread.sleep(forTimeInterval:0.01)
    }
    return nil
   }
   var applied=values;applied[7]=7;applied[8]=7;applied[9]=0;applied[48]=(values[48] ?? 0)|24
   // One bounded volatile mode test; no clear/default/reset commands.
   let changed=write(applied)
   let verified=readBack()==applied
   print("Temporary mode write success=\(changed==kIOReturnSuccess); read-back matches=\(verified)")
   Thread.sleep(forTimeInterval:2)
   let restored=write(values)
   let restoration=readBack()==values
   print("Original mode restore success=\(restored==kIOReturnSuccess); read-back matches=\(restoration)")
   exit(changed==kIOReturnSuccess && verified && restored==kIOReturnSuccess && restoration ? 0:2)
  }
  print("Selected settings query received; no setting values changed")
  exit(0)
 }
 Thread.sleep(forTimeInterval:0.01)
}
print("No matching bounded settings reply; no values changed")
exit(2)
