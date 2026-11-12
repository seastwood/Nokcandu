// Bounded passive right-pad lift diagnostic. No feature writes or injected input.
import Foundation
import IOKit.hid
final class PadTail {
 var head:[String]=[];var tail:[String]=[]; var wasDown=false; var counter:UInt32?;var lifts=0
 func receive(_ p:UnsafeMutablePointer<UInt8>,_ n:Int) {
  guard n==64,p[0]==1,p[2]==1 else{return}
  let c=(0..<4).reduce(UInt32(0)){$0|UInt32(p[4+$1])<<(8*$1)}
  guard counter != c else{return};counter=c
  let down=p[10]&0x10 != 0
  func axis(_ i:Int)->Int { Int(Int16(bitPattern:UInt16(p[i])|UInt16(p[i+1])<<8)) }
  let sample=String(format:"t=%.6f seq=%u touch=%d x=%d y=%d",ProcessInfo.processInfo.systemUptime,c,down ? 1:0,axis(20),axis(22))
  if down && CommandLine.arguments.contains("--all-samples") {print("SAMPLE "+sample)}
  if down {if !wasDown {head=[]};if head.count<12{head.append(sample)};tail.append(sample);if tail.count>12{tail.removeFirst()}}
  if wasDown && !down && lifts<20 { lifts+=1;print("LIFT \(lifts) START");for line in head{print(line)};print("TAIL");for line in tail{print(line)};print(sample);tail=[] }
  wasDown=down
 }
}
setbuf(stdout,nil)
let observer=PadTail(),manager=IOHIDManagerCreate(kCFAllocatorDefault,0)
IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x28de,kIOHIDProductIDKey:CommandLine.arguments.contains("--receiver") ? 0x1142 : 0x1102,kIOHIDDeviceUsagePageKey:0xff00,kIOHIDDeviceUsageKey:1] as CFDictionary)
IOHIDManagerRegisterInputReportCallback(manager,{ctx,r,_,_,_,p,n in if r==kIOReturnSuccess,let ctx {Unmanaged<PadTail>.fromOpaque(ctx).takeUnretainedValue().receive(p,n)}},Unmanaged.passUnretained(observer).toOpaque())
IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
let status=IOHIDManagerOpen(manager,0);print("READY: passive lift observer, open=\(status)")
if status==kIOReturnSuccess {RunLoop.main.run(until:Date().addingTimeInterval(180))}
IOHIDManagerClose(manager,0);print("Lift observations=\(observer.lifts)")
