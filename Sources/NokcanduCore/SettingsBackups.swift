import Foundation

/// Settings-only recovery across built-in recipes and optional fixes. Restoring a saved version
/// first journals the current file, so the recovery itself also has a recoverable backup.
public enum SettingsBackups {
    public struct Item: Identifiable {
        public var id: UUID
        public var date: Date
        public var original: URL
        public var backup: URL
        public var reason: String
        var sha: String?
    }
    static let extensions: Set<String> = ["con", "ini", "cfg"]
    static func allowed(_ target: URL, game: InstalledGame) -> Bool {
        let path = target.resolvingSymlinksInPath().path
        if let spec = GameDataSpec.forGame(game), spec.essentials.contains(where: { spec.folder.appendingPathComponent($0).resolvingSymlinksInPath().path == path }) { return true }
        guard extensions.contains(target.pathExtension.lowercased()) else { return false }
        if path.hasPrefix(game.appURL.resolvingSymlinksInPath().path + "/") { return true }
        return GameMover.externalFiles(game).map { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") } ?? false
    }
    public static func list(for game: InstalledGame) -> [Item] {
        let root = game.nokcanduState, dir = root.appendingPathComponent("Journals")
        let scopes = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        var ledgers = scopes.map { (ChangeJournal(scope: $0.deletingPathExtension().lastPathComponent, root: root, portableRoot: game.appURL), root) }
        ledgers.append((ChangeJournal(scope: game.journalScope, portableRoot: game.appURL), NokPaths.support))
        var result: [Item] = []
        for (j, ledgerRoot) in ledgers {
            for entry in j.entries {
                guard let path = entry.backupPath else { continue }
                let target = URL(fileURLWithPath: entry.path), backup = URL(fileURLWithPath: path)
                guard allowed(target, game: game), backup.resolvingSymlinksInPath().path.hasPrefix(ledgerRoot.appendingPathComponent("Backups").resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: path) else { continue }
                result.append(Item(id: entry.id, date: entry.date, original: target, backup: backup, reason: entry.reason, sha: entry.shaBefore))
            }
        }
        return result.sorted { $0.date > $1.date }
    }
    public static func restore(_ item: Item, for game: InstalledGame) throws {
        try CompatibilityFixes.requireClosed(game)
        guard let current = list(for: game).first(where: { $0.id == item.id }), allowed(current.original, game: game) else { throw NokError("This backup no longer belongs to this game's settings.") }
        let data = try Data(contentsOf: current.backup)
        guard current.sha == Hashing.sha256(data: data) else { throw NokError("The backup changed or could not be verified. Your settings were kept.") }
        try ChangeJournal(scope: "settings-recovery", root: game.nokcanduState, portableRoot: game.appURL).write(data, to: current.original, reason: "Before restoring a settings backup")
    }
}
