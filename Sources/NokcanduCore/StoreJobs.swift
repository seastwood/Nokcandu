import Foundation

/// Mac versions being downloaded from a store. Saved to disk when a download starts and cleared when it
/// finishes, so a download cut short (Nokcandu quit, Mac restarted) can be picked up again: legendary and
/// gogdl continue from the files already in the folder.
public struct StoreJob: Codable, Hashable, Sendable, Identifiable {
    public var game: StoreGame
    /// The folder the game's own folder goes into.
    public var folder: URL
    public var started: Date
    public var includeDLC: Bool? = nil
    public var id: String { StoreJobs.key(game.store, game.id) }
    public init(game: StoreGame, folder: URL, started: Date = Date()) { self.game = game; self.folder = folder; self.started = started }
}

public enum StoreJobs {
    static let lock = NSLock()
    public static var file: URL { NokPaths.support.appendingPathComponent("store-installs.json") }
    public static func key(_ s: Store, _ id: String) -> String { "\(s.rawValue)-\(id)" }

    public static func all() -> [StoreJob] {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([StoreJob].self, from: d)) ?? []
    }

    static func write(_ jobs: [StoreJob]) {
        try? NokPaths.ensure(NokPaths.support)
        if jobs.isEmpty { try? FileManager.default.removeItem(at: file); return }
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: file, options: .atomic) }
    }

    public static func add(_ job: StoreJob) {
        var j = all().filter { $0.id != job.id }
        j.append(job)
        lock.lock(); defer { lock.unlock() }
        write(j)
    }

    public static func remove(_ id: String) {
        let j = all().filter { $0.id != id }
        lock.lock(); defer { lock.unlock() }
        write(j)
    }

    /// The game's own folder for a job (where its files are).
    public static func gameFolder(_ job: StoreJob) -> URL {
        job.folder.appendingPathComponent(CustomGames.safeFolderName(job.game.title), isDirectory: true)
    }

    /// Give up on a download: forget it and move what was downloaded so far to the Trash.
    public static func discard(_ job: StoreJob) {
        remove(job.id)
        let dest = gameFolder(job)
        if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
    }
}
