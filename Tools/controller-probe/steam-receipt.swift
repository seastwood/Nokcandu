// Bounded, nonexclusive vendor-interface receipt. No feature writes or mode changes.
import Foundation
import IOKit.hid
import NokcanduCore
final class Counts {
    var shapes: [String:Int] = [:]
    var decoder = SteamControllerReport()
    var seen = Set<PadProfiles.Input>()
    var leftTouches = 0, rightTouches = 0, decoded = 0
    var stickSeen = false
    var buttons = 0, pads = 0, sticks = 0, motion = 0
    func report(_ p: UnsafeMutablePointer<UInt8>, _ n: Int, _ id: UInt32) {
        guard n > 0 else { return }
        let type = n > 3 ? Int(p[2]) : -1
        let key = "id=\(id) length=\(n) type=\(type)"
        shapes[key,default:0] += 1
        if let state = decoder.decode(Array(UnsafeBufferPointer(start:p,count:n))) {
            decoded += 1
            let added=state.buttons.subtracting(seen)
            if !added.isEmpty { print("Observed controls: " + added.map(\.rawValue).sorted().joined(separator:",")) }
            seen.formUnion(state.buttons)
            if state.leftTouch { if leftTouches == 0 { print("Observed left trackpad touch") };leftTouches += 1 }
            if state.rightTouch { if rightTouches == 0 { print("Observed right trackpad touch") };rightTouches += 1 }
            if !stickSeen && (abs(state.stick.x)>0.2 || abs(state.stick.y)>0.2) { stickSeen=true;print("Observed joystick movement") }
        }
        if n == 64 && p[0] == 1 && p[1] == 0 && p[2] == 1 && p[3] == 60 {
            if p[8] != 0 || p[9] != 0 || p[10] != 0 { buttons += 1 }
            if p[10] & 0x18 != 0 { pads += 1 }
            if (16...19).contains(where: { p[$0] != 0 }) { sticks += 1 }
            if (34...39).contains(where: { p[$0] != 0 }) { motion += 1 }
        }
    }
}
let seconds = min(180, max(1, CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5))
setbuf(stdout,nil)
let observer = Counts()
let m=IOHIDManagerCreate(kCFAllocatorDefault,0)
IOHIDManagerSetDeviceMatching(m,[kIOHIDVendorIDKey:0x28de,kIOHIDProductIDKey:0x1102,kIOHIDDeviceUsagePageKey:0xff00,kIOHIDDeviceUsageKey:1] as CFDictionary)
IOHIDManagerRegisterInputReportCallback(m,{ctx,result,_,_,id,p,n in
    if result == kIOReturnSuccess,let ctx {Unmanaged<Counts>.fromOpaque(ctx).takeUnretainedValue().report(p,n,id)}
},Unmanaged.passUnretained(observer).toOpaque())
IOHIDManagerScheduleWithRunLoop(m,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
let result=IOHIDManagerOpen(m,0)
print(String(format:"Vendor interface nonexclusive open=%08X",result))
if result == kIOReturnSuccess {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
IOHIDManagerClose(m,0)
for key in observer.shapes.keys.sorted(){print("\(key) count=\(observer.shapes[key]!)")}
print("Nonzero-field packet counts: button/touch=\(observer.buttons), touched-pads=\(observer.pads), multiplexed-stick/pad=\(observer.sticks), gyro=\(observer.motion)")
print("No feature requests or commands sent; nonzero fields alone do not establish physical response or calibration.")

print("Validated full states=\(observer.decoded); observed buttons=\(observer.seen.map(\.rawValue).sorted().joined(separator:",")); left-pad packets=\(observer.leftTouches); right-pad packets=\(observer.rightTouches)")
