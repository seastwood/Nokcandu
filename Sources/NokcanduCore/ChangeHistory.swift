import Foundation

/// What Nokcandu changed for a game, newest first: fixes, settings, setups, engine, keys and controllers. Kept in
/// the game's state folder (newest 100). Each entry says how to go back: a fix has its own Undo; other changes point
/// at where they're changed again.
public enum ChangeHistory {
    public enum Undo: Codable, Equatable, Sendable {
        case fix(String)            // CompatibilityFix raw value
        case setting(String)        // the tab where it's changed again (GameDetailView.Tab raw value)
        case none
    }
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID = UUID()
        public var date: Date
        public var title: String
        public var undo: Undo
    }
    static let keep = 100
    static func url(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("change-history.json") }
    private static let lock = NSLock()

    public static func entries(_ g: InstalledGame) -> [Entry] {
        (try? Data(contentsOf: url(g))).flatMap { try? ChangeJournal.decoder.decode([Entry].self, from: $0) } ?? []
    }

    public static func note(_ g: InstalledGame, _ title: String, undo: Undo = .none, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var list = entries(g)
        list.insert(Entry(date: now, title: title, undo: undo), at: 0)
        if list.count > keep { list.removeLast(list.count - keep) }
        try? NokPaths.ensure(g.nokcanduState)
        try? ChangeJournal.encoder.encode(list).write(to: url(g), options: .atomic)
    }
}
