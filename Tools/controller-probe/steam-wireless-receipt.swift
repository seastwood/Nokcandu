// Read-only receiver query + full-state receipt. --test-mode explicitly performs
// a two-second volatile capture and exact restoration on one responsive slot.
import Foundation
import IOKit.hid
final class WirelessCounts {
 var packets=0, events=0, gyro=0
 var seen=Set<String>()
 func accept(_ b:[UInt8]) {
  guard b.count==64 else{return}
  if SteamControllerTransport.event(b) != nil {events += 1}
  guard b[0]==1,b[1]==0,b[2]==1,(44...60).contains(b[3]) else{return}
  packets += 1
  if b[34..<40].contains(where:{$0 != 0}){gyro += 1}
  let flags=UInt32(b[8]) | UInt32(b[9])<<8 | UInt32(b[10])<<16
  for (bit,name) in [(7,"A"),(15,"left grip"),(16,"right grip"),(19,"left touch"),(20,"right touch")] where flags & (1<<bit) != 0 {seen.insert(name)}
 }
}
@main enum WirelessReceipt {
 static func main() {
  let manager = IOHIDManagerCreate(kCFAllocatorDefault,0)
  IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x28de,kIOHIDProductIDKey:0x1142,kIOHIDDeviceUsagePageKey:0xff00,kIOHIDDeviceUsageKey:1] as CFDictionary)
  guard IOHIDManagerOpen(manager,0) == kIOReturnSuccess else { print("Receiver open failed");return }
  defer { IOHIDManagerClose(manager,0) }
  let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
  func slot(_ d:IOHIDDevice)->Int { (IORegistryEntrySearchCFProperty(IOHIDDeviceGetService(d),kIOServicePlane,"bInterfaceNumber" as CFString,kCFAllocatorDefault,IOOptionBits(kIORegistryIterateRecursively|kIORegistryIterateParents)) as? NSNumber)?.intValue ?? -1 }
  func send(_ d:IOHIDDevice,_ data:[UInt8])->Bool {
   SteamControllerTransport.receiver.transfer(attempt:{var b=data;return IOHIDDeviceSetReport(d,kIOHIDReportTypeFeature,0,&b,b.count)==kIOReturnSuccess},pause:{Thread.sleep(forTimeInterval:0.0005)})
  }
  func read(_ d:IOHIDDevice)->SteamControllerMode.Settings? {
   guard send(d,SteamControllerMode.query) else{return nil}
   for _ in 0..<10 {
    var b=[UInt8](repeating:0,count:64),n=64
    let ok=SteamControllerTransport.receiver.transfer(attempt:{n=64;return IOHIDDeviceGetReport(d,kIOHIDReportTypeFeature,0,&b,&n)==kIOReturnSuccess},pause:{Thread.sleep(forTimeInterval:0.0005)})
    if ok,n>=0,n<=64,let value=SteamControllerMode.decode(Array(b.prefix(n))){return value}
    Thread.sleep(forTimeInterval:0.001)
   };return nil
  }
  print("Receiver vendor slots=\(devices.count)")
  for device in devices.sorted(by:{slot($0)<slot($1)}) {
   var identityRequest=SteamControllerIdentity.query
   if CommandLine.arguments.contains("--short-identity-query") { identityRequest[1]=1 }
   var fingerprints=[String]()
   for _ in 0..<2 {
    if send(device,identityRequest) {
     for _ in 0..<10 {
      Thread.sleep(forTimeInterval:0.003)
      var b=[UInt8](repeating:0,count:64),n=64
      let ok=SteamControllerTransport.receiver.transfer(attempt:{n=64;return IOHIDDeviceGetReport(device,kIOHIDReportTypeFeature,0,&b,&n)==kIOReturnSuccess},pause:{Thread.sleep(forTimeInterval:0.0005)})
      if ok,n>=0,n<=64,let id=SteamControllerIdentity.fingerprint(Array(b.prefix(n))){fingerprints.append(id);break}
     }
    }
   }
   print("slot \(slot(device)): stable remote identity=\(fingerprints.count==2 && fingerprints[0]==fingerprints[1])")
   guard let original=read(device) else {print("slot \(slot(device)): no complete controller settings reply");continue}
   print("slot \(slot(device)): selected settings \(SteamControllerMode.tags.map{String(original[$0] ?? 0)}.joined(separator:"/"))")
   if CommandLine.arguments.contains("--simulate-mode-loss"),fingerprints.count==2,fingerprints[0]==fingerprints[1] {
    let url=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nokcandu/steam-wireless-mode-"+fingerprints[0]+".json")
    guard let data=try? Data(contentsOf:url),let receipt=try? JSONDecoder().decode(SteamControllerIdentity.Recovery.self,from:data),
          receipt.recoveredOriginal(identity:fingerprints[0],current:original) != nil,
          let idle=SteamControllerMode.write(receipt.original),let undo=SteamControllerMode.write(original) else {print("Mode-loss trial refused: no matching active recovery receipt");return}
    let sent=send(device,idle)
    Thread.sleep(forTimeInterval:4)
    let recaptured=read(device)==receipt.applied
    print("Mode-loss trial sent=\(sent), app recaptured=\(recaptured)")
    if !recaptured {print("Trial cleanup restored pretrial capture=\(send(device,undo) && read(device)==original)")}
    return
   }
   if CommandLine.arguments.contains("--restore-observed-original"),fingerprints.count==2,fingerprints[0]==fingerprints[1] {
    // Repair only this session's measured known original, never a factory/default reset.
    let baseline:SteamControllerMode.Settings=[7:3,8:0,9:1,48:0,49:2]
    guard original==SteamControllerMode.captured(baseline),let bytes=SteamControllerMode.write(baseline) else {print("Repair refused: settings differ from observed capture");return}
    let sent=send(device,bytes),verified=read(device)==baseline
    print("Observed-original repair sent=\(sent), readback=\(verified)");return
   }
   guard CommandLine.arguments.contains("--test-mode"),let applied=SteamControllerMode.captured(original),let write=SteamControllerMode.write(applied),let undo=SteamControllerMode.write(original) else{continue}
   let counts=WirelessCounts()
   let context=Unmanaged.passUnretained(counts).toOpaque()
   let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:64)
   defer { IOHIDDeviceRegisterInputReportCallback(device,buffer,64,nil,nil);buffer.deallocate() }
   IOHIDDeviceRegisterInputReportCallback(device,buffer,64,{ctx,result,_,_,_,data,n in
    guard let ctx,result==kIOReturnSuccess else{return}
    Unmanaged<WirelessCounts>.fromOpaque(ctx).takeUnretainedValue().accept(Array(UnsafeBufferPointer(start:data,count:n)))
   },context)
   IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
   defer {IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)}
   let changed=send(device,write),verified=read(device)==applied
   print("slot \(slot(device)): mode write=\(changed), readback=\(verified)")
   if verified { RunLoop.main.run(until:Date().addingTimeInterval(CommandLine.arguments.contains("--observe") ? 180:2)) }
   print("slot \(slot(device)): full packets=\(counts.packets), nonzero gyro=\(counts.gyro), events=\(counts.events), controls=\(counts.seen.sorted())")
   let restored=send(device,undo),matches=read(device)==original
   print("slot \(slot(device)): restore=\(restored), readback=\(matches)")
   return
  }
 }
}
