import Foundation
import IOKit.hid

/// Output reports to controllers, sent off the main thread and in order: a Bluetooth controller that's slow to
/// take one (macOS can wait seconds on some) never holds up the app.
enum HIDOutput {
    private static let queue = DispatchQueue(label: "Nokcandu.HIDOutput", qos: .userInteractive)
    /// `bytes` starts with the report ID; an ID of 0 means the device has none, so only the bytes after it are sent.
    static func send(_ bytes: [UInt8], to device: IOHIDDevice) {
        guard let id = bytes.first else { return }
        nonisolated(unsafe) let d = device
        queue.async {
            var b = id == 0 ? Array(bytes.dropFirst()) : bytes
            _ = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, CFIndex(id), &b, b.count)
        }
    }
}
