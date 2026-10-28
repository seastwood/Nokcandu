import Foundation

/// Rollback journal. Every file Nokcandu changes is backed up first and recorded with its
/// before/after SHA-256. Reverting restores each file to the state it had *before Nokcandu
/// first touched it* — but only if nobody else changed it since (otherwise it is left alone
/// and reported), so a revert can never clobber a game update or the user's own edits.
public struct JournalEntry: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var date = Date()
    public var path: String
    public var backupPath: String?     // nil => the file did not exist before (Nokcandu created it)
    public var shaBefore: String?
    public var shaAfter: String?
    public var reason: String
    /// Nil = whole-file ownership; otherwise Undo restores only these setting commands.
    public var settingsKeys: [String]? = nil
}

public final class ChangeJournal {
    public let scope: String
    public private(set) var entries: [JournalEntry] = []
    private let journalURL: URL
    private let backupDir: URL
    private let portableRoot: URL?
    private let fm = FileManager.default

    public init(scope: String, root: URL = NokPaths.support, portableRoot: URL? = nil) {
        self.scope = scope
        self.portableRoot = portableRoot
        journalURL = root.appendingPathComponent("Journals/\(scope).json")
        backupDir = root.appendingPathComponent("Backups/\(scope)", isDirectory: true)
        if let data = try? Data(contentsOf: journalURL),
           let decoded = try? Self.decoder.decode([JournalEntry].self, from: data) {
            entries = decoded
        }
        if let portableRoot {
            let marker = journalURL.appendingPathExtension("root")
            let inferred = entries.compactMap { entry -> String? in
                guard let r = entry.path.range(of: ".app/Contents/") else { return nil }
                return String(entry.path[..<entry.path.index(r.lowerBound, offsetBy: 4)])
            }.first
            let old = (try? String(contentsOf: marker, encoding: .utf8)) ?? inferred
            if let old, old != portableRoot.path {
                func rebase(_ value: String) -> String {
                    value.hasPrefix(old + "/") ? portableRoot.path + value.dropFirst(old.count) : value
                }
                entries = entries.map { entry in
                    var e = entry; e.path = rebase(e.path); e.backupPath = e.backupPath.map(rebase); return e
                }
            }
        }
    }

    public var hasChanges: Bool { !entries.isEmpty }
    public var touchedPaths: [String] { Array(NSOrderedSet(array: entries.map(\.path))) as? [String] ?? [] }

    /// Replace a file's contents (atomically), backing up the current version first.
    public func write(_ data: Data, to url: URL, reason: String) throws {
        let existing = fm.fileExists(atPath: url.path)
        let before = existing ? try Hashing.sha256(file: url) : nil
        let after = Hashing.sha256(data: data)
        if before == after { return }                  // idempotent: nothing to do
        var backup: String?
        if existing {
            try NokPaths.ensure(backupDir)
            let b = backupDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            try fm.copyItem(at: url, to: b)
            backup = b.path
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let perms = existing ? (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) : nil
        try data.write(to: url, options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms as Any], ofItemAtPath: url.path) }
        try append(JournalEntry(path: url.path, backupPath: backup, shaBefore: before, shaAfter: after, reason: reason))
    }

    /// Adopt an older settings ledger without changing the file. Empty keys preserve routing
    /// files managed by the game. Executables and DLLs never use settings ownership.
    func manageSettings(_ url: URL, keys: [String]) throws {
        for i in entries.indices where entries[i].path == url.path { entries[i].settingsKeys = keys }
        try save()
    }
    func writeSettings(_ data: Data, to url: URL, keys: [String], reason: String) throws {
        try write(data, to: url, reason: reason)
        try manageSettings(url, keys: keys)
    }
    /// Verify before changing app settings. Text settings can evolve normally inside the game.
    func validateForUndo() throws {
        for path in touchedPaths {
            guard let last = entries.last(where: { $0.path == path }) else { continue }
            if let keys = last.settingsKeys {
                if keys.isEmpty { continue }
                let url = URL(fileURLWithPath: path)
                guard let text = try? TextSettings.read(url),
                      TextSettings.lines(text).contains(where: { keys.contains(TextSettings.key($0) ?? "") }) else {
                    throw NokError("\(url.lastPathComponent) no longer contains the expected settings. Open Settings Backups to restore a saved version.")
                }
            } else if let sha = last.shaAfter, (try? Hashing.sha256(file: URL(fileURLWithPath: path))) != sha {
                throw NokError("\((path as NSString).lastPathComponent) changed after installation. Its files were kept.")
            }
        }
    }

    /// Record something Nokcandu created that is not a single file write (a symlink, a folder, an app bundle).
    public func recordCreated(_ url: URL, reason: String) throws {
        try append(JournalEntry(path: url.path, backupPath: nil, shaBefore: nil, shaAfter: nil, reason: reason))
    }

    private func append(_ e: JournalEntry) throws {
        entries.append(e)
        try save()
    }

    private func save() throws {
        try NokPaths.ensure(journalURL.deletingLastPathComponent())
        try Self.encoder.encode(entries).write(to: journalURL, options: .atomic)
        if let portableRoot { try Data(portableRoot.path.utf8).write(to: journalURL.appendingPathExtension("root"), options: .atomic) }
    }

    public struct RevertReport {
        public var restored: [String] = []
        public var removed: [String] = []
        public var skipped: [(path: String, why: String)] = []
        public var summary: String {
            var lines: [String] = []
            if !restored.isEmpty { lines.append("Restored \(restored.count) file(s).") }
            if !removed.isEmpty { lines.append("Moved \(removed.count) Nokcandu-created item(s) to the Trash.") }
            for s in skipped { lines.append("Left \((s.path as NSString).lastPathComponent) alone: \(s.why)") }
            return lines.isEmpty ? "Nothing to undo." : lines.joined(separator: "\n")
        }
    }

    /// Undo every recorded change, newest file first. Files changed outside Nokcandu are skipped.
    @discardableResult
    public func revertAll() -> RevertReport {
        var report = RevertReport()
        var remaining: [JournalEntry] = []
        for path in touchedPaths.reversed() {
            let forPath = entries.filter { $0.path == path }
            guard let first = forPath.first, let last = forPath.last else { continue }
            let url = URL(fileURLWithPath: path)
            // Plain file writes are verified against the last hash Nokcandu wrote.
            if last.settingsKeys == nil, let expected = last.shaAfter {
                let current = fm.fileExists(atPath: path) ? (try? Hashing.sha256(file: url)) : nil
                if current != expected {
                    report.skipped.append((path, "it changed after Nokcandu edited it."))
                    remaining.append(contentsOf: forPath)
                    continue
                }
            }
            do {
                if let keys = last.settingsKeys {
                    if keys.isEmpty { continue } // Keep the game's current profile routing.
                    let bytes = try Data(contentsOf: url)
                    let current = try TextSettings.decode(bytes)
                    guard TextSettings.lines(current).contains(where: { keys.contains(TextSettings.key($0) ?? "") }) else {
                        throw NokError("The expected settings are missing. Restore a saved version with Settings Backups.")
                    }
                    let before = try first.backupPath.map { try TextSettings.read(URL(fileURLWithPath: $0)) } ?? ""
                    let merged = TextSettings.merge(current: current, valuesFrom: before, keys: keys)
                    // Preserve the complete current file as an accessible recovery version too.
                    let recovery = ChangeJournal(scope: "settings-recovery", root: backupDir.deletingLastPathComponent().deletingLastPathComponent(), portableRoot: portableRoot)
                    try recovery.write(try TextSettings.encode(merged, like: bytes), to: url, reason: "Before undoing settings")
                    report.restored.append(path)
                } else if let backup = first.backupPath {
                    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).nokcandu-restore")
                    try? fm.removeItem(at: tmp)
                    try fm.copyItem(at: URL(fileURLWithPath: backup), to: tmp)
                    _ = try fm.replaceItemAt(url, withItemAt: tmp)
                    report.restored.append(path)
                } else if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                    report.removed.append(path)
                }
            } catch {
                report.skipped.append((path, error.localizedDescription))
                remaining.append(contentsOf: forPath)
            }
        }
        entries = remaining.sorted { $0.date < $1.date }
        try? save()
        return report
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
