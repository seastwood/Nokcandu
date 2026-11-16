import Foundation

/// The original controller's connections: USB cable, 2.4 GHz receiver, and Bluetooth LE (whose packets come in
/// segments: SteamControllerBLE).
public enum SteamControllerTransport: String, Sendable {
    case cable, receiver, bluetooth
    public static func identify(vendor: Int, product: Int, page: Int, usage: Int, interface: Int) -> Self? {
        // Bluetooth: one HID device for the controller, its keyboard and mouse reports and Valve's report 3 together.
        if vendor == 0x28de, SteamControllerBLE.products.contains(product) { return .bluetooth }
        guard vendor == 0x28de, page == 0xff00, usage == 1 else { return nil }
        if product == 0x1102 && interface == 2 { return .cable }
        if product == 0x1142 && (1...4).contains(interface) { return .receiver }
        return nil
    }
    public var title: String { switch self { case .cable: "USB"; case .receiver: "Wireless receiver"; case .bluetooth: "Bluetooth" } }
    /// Valve's receiver can return failure while a radio transaction is pending.
    /// Only retry the same bounded request; never substitute reset/pairing commands.
    public func transfer(attempt: () -> Bool, pause: () -> Void) -> Bool {
        // Bluetooth: a few tries, for a radio that's briefly busy (SDL sends once; an untested guess).
        let tries = self == .receiver ? 50 : self == .bluetooth ? 5 : 1
        for index in 0..<tries {
            if attempt() { return true }
            if index < tries - 1 { pause() }
        }
        return false
    }
    public enum Event: Equatable { case disconnected, connected }
    public static func event(_ bytes: [UInt8]) -> Event? {
        guard bytes.count >= 5, bytes[0] == 1, bytes[1] == 0, bytes[2] == 3,
              bytes[3] >= 1, Int(bytes[3]) + 4 <= bytes.count else { return nil }
        switch bytes[4] {
        case 1: return .disconnected
        case 2, 3: return .connected
        default: return nil
        }
    }
}

/// Cancels queued receiver feedback when the remote controller's radio session ends.
public final class SteamControllerOutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    public init() {}
    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    public func cancel() { lock.lock(); active = false; lock.unlock() }
}
