import Foundation

/// One reader's access to one physical HID interface. A refused exclusive open never falls back to sharing.
/// The native adapter supplies IOHIDDeviceOpen/Close; tests exercise refusal/retry/release without hardware.
public final class ControllerDeviceAccess: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case unopened, exclusive, shared, refused(Int32), released
        public var usable: Bool { self == .exclusive || self == .shared }
    }
    public let requestsExclusive: Bool
    private let lock = NSLock()
    private let operation = NSLock()
    private var value: State = .unopened
    public init(exclusive: Bool) { requestsExclusive = exclusive }
    public var state: State { lock.lock(); defer { lock.unlock() }; return value }
    public var usable: Bool { state.usable }
    @discardableResult
    public func open(using open: (Bool) -> Int32) -> Bool {
        operation.lock(); defer { operation.unlock() }
        let before = state
        if before.usable { return true }
        guard before != .released else { return false }
        let result = open(requestsExclusive)
        lock.lock(); defer { lock.unlock() }
        value = result == 0 ? (requestsExclusive ? .exclusive : .shared) : .refused(result)
        return value.usable
    }
    /// Release exactly once, with the same access option used to acquire the interface.
    public func release(using close: (Bool) -> Void) {
        operation.lock(); defer { operation.unlock() }
        lock.lock()
        let owned = value.usable
        value = .released
        lock.unlock()
        if owned { close(requestsExclusive) }
    }
}

public enum ControllerOwnershipPreference {
    public static let key = "controllerExclusiveOwnership"
    /// An explicit Off survives upgrades. This policy is independent of profile assignments/enabled state.
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
