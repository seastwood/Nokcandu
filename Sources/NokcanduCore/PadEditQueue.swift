/// Serial-owner edit queue. Runtime reads pending values immediately; persistence is coalesced.
/// The scheduler returns cancellation, but generation checks also reject stale callbacks.
public final class PadEditQueue<Value> {
    public typealias Scheduler = (Double, @escaping () -> Void) -> (() -> Void)
    private struct Entry {
        var value: Value
        var generation: UInt64
        var save: (Value) -> Void
        var cancel: (() -> Void)?
    }
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private let schedule: Scheduler
    private let didChange: () -> Void
    public init(schedule: @escaping Scheduler, didChange: @escaping () -> Void) {
        self.schedule = schedule; self.didChange = didChange
    }
    public func value(scope: String) -> Value? { entries[scope]?.value }
    public func submit(_ value: Value, scope: String, persist: @escaping (Value) -> Void) {
        entries[scope]?.cancel?()
        generation &+= 1
        let token = generation
        entries[scope] = Entry(value: value, generation: token, save: persist)
        let cancel = schedule(0.25) { [weak self] in
            guard let self, self.entries[scope]?.generation == token else { return }
            self.flush(scope)
        }
        if entries[scope]?.generation == token { entries[scope]?.cancel = cancel }
        didChange()
    }
    public func flush(_ scope: String) {
        guard let entry = entries.removeValue(forKey: scope) else { return }
        entry.cancel?(); entry.save(entry.value); didChange()
    }
    public func flushAll() { for key in entries.keys.sorted() { flush(key) } }
}
