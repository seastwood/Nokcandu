import Foundation

/// Original USB cable and 2.4 GHz receiver only. BLE uses a different packet format.
public enum SteamControllerTransport: String, Sendable {
    case cable, receiver
    public static func identify(vendor: Int, product: Int, page: Int, usage: Int, interface: Int) -> Self? {
        guard vendor == 0x28de, page == 0xff00, usage == 1 else { return nil }
        if product == 0x1102 && interface == 2 { return .cable }
        if product == 0x1142 && (1...4).contains(interface) { return .receiver }
        return nil
    }
    public var title: String { self == .cable ? "USB" : "Wireless receiver" }
    /// Valve's receiver can return failure while a radio transaction is pending.
    /// Only retry the same bounded request; never substitute reset/pairing commands.
    public func transfer(attempt: () -> Bool, pause: () -> Void) -> Bool {
        for index in 0..<(self == .receiver ? 50 : 1) {
            if attempt() { return true }
            if self == .receiver && index < 49 { pause() }
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
