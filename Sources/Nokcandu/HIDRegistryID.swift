import Foundation
import IOKit.hid

/// A HID device's registry ID, remembered from when it was first seen.
///
/// When a device is unplugged (often several at once from a USB hub), IOKit can no longer look its
/// registry entry up and returns 0. Every removal handler that recomputed the ID then missed the device,
/// so its held buttons and sticks stayed pressed, and several departed devices all reported 0, which
/// crashed `Dictionary(uniqueKeysWithValues:)` in the Steam Controller reader (November 18, 2026).
/// Every reader asks here instead: the live ID while the device exists, the remembered one after.
enum HIDRegistryID {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var known: [ObjectIdentifier: UInt64] = [:]
    }
    private static let store = Store()

    static func of(_ device: IOHIDDevice) -> UInt64 {
        var live: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0 { IORegistryEntryGetRegistryEntryID(service, &live) }
        let key = ObjectIdentifier(device)
        store.lock.lock(); defer { store.lock.unlock() }
        if live != 0 { store.known[key] = live; return live }
        return store.known[key] ?? 0
    }

    /// Call once a removed device has been fully handled, so a later object at the same address starts fresh.
    static func forget(_ device: IOHIDDevice) {
        store.lock.lock(); store.known[ObjectIdentifier(device)] = nil; store.lock.unlock()
    }
}
