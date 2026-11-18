import Foundation

/// Serial, cancellable receiver discovery. Empty slots can take hundreds of milliseconds to answer;
/// the caller must never wait for them on the input/UI thread.
public final class SteamControllerDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let delivery: DispatchQueue
    private var generation: UInt64 = 0
    private var pending = false
    public init(queue: DispatchQueue, delivery: DispatchQueue = .main) {
        self.queue = queue; self.delivery = delivery
    }
    private func current(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == token && pending
    }
    @discardableResult
    public func scan(_ candidates: [UInt64], probe: @escaping @Sendable (UInt64) -> Bool,
                     completion: @escaping @Sendable (UInt64?) -> Void) -> Bool {
        lock.lock()
        guard !pending else { lock.unlock(); return false }
        generation &+= 1
        let token = generation; pending = true
        lock.unlock()
        queue.async { [self] in
            var found: UInt64?
            for id in candidates {
                guard current(token) else { return }
                if probe(id) { found = id; break }
            }
            let result = found
            delivery.async { [self] in
                lock.lock()
                guard generation == token && pending else { lock.unlock(); return }
                pending = false
                lock.unlock()
                completion(result)
            }
        }
        return true
    }
    /// Invalidate queued results. An in-progress HID transaction finishes on its worker, then stops.
    public func cancel() {
        lock.lock(); generation &+= 1; pending = false; lock.unlock()
    }
}
