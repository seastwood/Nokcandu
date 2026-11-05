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

/// A small thread-safe dictionary for hot caches. Clears itself when it reaches `limit` entries.
final class LockedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    subscript(key: Key) -> Value? {
        get { lock.lock(); defer { lock.unlock() }; return storage[key] }
        set {
            lock.lock(); defer { lock.unlock() }
            if newValue != nil, storage[key] == nil, storage.count >= limit { storage.removeAll(keepingCapacity: true) }
            storage[key] = newValue
        }
    }
    func removeAll() { lock.lock(); storage.removeAll(); lock.unlock() }
}

/// SHA-256 of a file, recomputed only when its size, modification time or inode changes.
enum FileHashCache {
    private struct Stamp: Hashable { var size: Int64; var mtime: Int; var mtimeNanos: Int; var inode: UInt64 }
    private static let cache = LockedCache<String, (Stamp, String)>(limit: 1024)
    static func sha256(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let stamp = Stamp(size: Int64(st.st_size), mtime: st.st_mtimespec.tv_sec, mtimeNanos: st.st_mtimespec.tv_nsec, inode: UInt64(st.st_ino))
        if let (old, hash) = cache[url.path], old == stamp { return hash }
        guard let hash = try? Hashing.sha256(file: url) else { return nil }
        cache[url.path] = (stamp, hash)
        return hash
    }
}

/// Results derived from a file (a Wine registry, a folder listing), kept until the file changes.
/// Reading and splitting a launcher's multi-megabyte system.reg for every game, every few minutes, was
/// a large part of Nokcandu's startup work.
enum FileDerivedCache {
    private struct Stamp: Hashable { var size: Int64; var mtime: Int; var nanos: Int }
    private static let cache = LockedCache<String, (Stamp, Any)>(limit: 256)
    static func value<T>(for file: URL, kind: String, compute: () -> T) -> T {
        var st = stat()
        guard stat(file.path, &st) == 0 else { return compute() }
        let stamp = Stamp(size: Int64(st.st_size), mtime: st.st_mtimespec.tv_sec, nanos: st.st_mtimespec.tv_nsec)
        let key = kind + "|" + file.path
        if let (old, value) = cache[key], old == stamp, let typed = value as? T { return typed }
        let value = compute()
        cache[key] = (stamp, value)
        return value
    }
}

/// Program names found in a game folder, remembered on disk by the folder's modification time (and for at most
/// a day): walking a large game folder on an external drive at every launch was slow.
enum ExeNameCache {
    struct Entry: Codable { var stamp: Double; var checked: Date; var names: [String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: Entry]?
    static func names(in folder: URL, compute: () -> [String]) -> [String] {
        let stamp = ((try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970) ?? -1
        lock.lock()
        if loaded == nil { loaded = ListCache.load("exe-names", as: [String: Entry].self)?.value ?? [:] }
        if let e = loaded?[folder.path], e.stamp == stamp, stamp >= 0, Date().timeIntervalSince(e.checked) < 86_400 {
            lock.unlock(); return e.names
        }
        lock.unlock()
        let names = compute()
        lock.lock()
        loaded?[folder.path] = Entry(stamp: stamp, checked: Date(), names: names)
        let snapshot = loaded ?? [:]
        lock.unlock()
        ListCache.save(snapshot, "exe-names")
        return names
    }
}
