// Passive: the right pad's readings next to where the Mac pointer is, to compare what the thumb did with what
// the pointer did. Reads only (nonexclusive HID, the pointer's position); nothing is written or posted.
// Usage: swift Tools/controller-probe/steam-pad-cursor.swift [--receiver] [seconds] > file
import Foundation
import IOKit.hid
import CoreGraphics
final class Recorder {
 var counter: UInt32?
 func receive(_ p: UnsafeMutablePointer<UInt8>, _ n: Int) {
  guard n == 64, p[0] == 1, p[2] == 1 else { return }
  let c = (0..<4).reduce(UInt32(0)) { $0 | UInt32(p[4 + $1]) << (8 * $1) }
  guard counter != c else { return }; counter = c
  let down = p[10] & 0x10 != 0
  func axis(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8)) }
  let at = CGEvent(source: nil)?.location ?? .zero
  print(String(format: "SAMPLE t=%.6f seq=%u touch=%d x=%d y=%d cx=%.2f cy=%.2f", ProcessInfo.processInfo.systemUptime, c, down ? 1 : 0, axis(20), axis(22), at.x, at.y))
 }
}
setbuf(stdout, nil)
let seconds = CommandLine.arguments.dropFirst().compactMap { Double($0) }.first ?? 90
let recorder = Recorder(), manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x28de, kIOHIDProductIDKey: CommandLine.arguments.contains("--receiver") ? 0x1142 : 0x1102, kIOHIDDeviceUsagePageKey: 0xff00, kIOHIDDeviceUsageKey: 1] as CFDictionary)
IOHIDManagerRegisterInputReportCallback(manager, { ctx, r, _, _, _, p, n in if r == kIOReturnSuccess, let ctx { Unmanaged<Recorder>.fromOpaque(ctx).takeUnretainedValue().receive(p, n) } }, Unmanaged.passUnretained(recorder).toOpaque())
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let status = IOHIDManagerOpen(manager, 0); print("READY: pad and pointer recorder, open=\(status), \(Int(seconds)) s")
if status == kIOReturnSuccess { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
IOHIDManagerClose(manager, 0); print("DONE")
