import Foundation

/// A failed/overlapping scan never becomes evidence that a process exited.
struct ProcessSnapshot {
    var rows: [(Int32, String)]
    var reliable: Bool
}
final class ProcessSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [(Int32, String)] = []
    private var attempted = Date.distantPast
    private var reliable = false
    private var scanning = false
    func read(now: Date? = nil, loader: () throws -> [(Int32, String)]) -> ProcessSnapshot {
        let moment = now ?? Date()
        lock.lock()
        if scanning || moment.timeIntervalSince(attempted) < (reliable ? 1 : 3) {
            let value = ProcessSnapshot(rows: rows, reliable: reliable && !scanning)
            lock.unlock(); return value
        }
        scanning = true
        lock.unlock()
        let loaded = Result { try loader() }
        lock.lock(); defer { lock.unlock() }
        if case .success(let new) = loaded { rows = new; reliable = true }
        else { reliable = false }
        attempted = now ?? Date(); scanning = false
        return ProcessSnapshot(rows: rows, reliable: reliable)
    }
}
