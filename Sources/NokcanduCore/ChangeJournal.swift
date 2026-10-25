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
}

public final class ChangeJournal {
    public let scope: String
    public private(set) var entries: [JournalEntry] = []
    private let journalURL: URL
    private let backupDir: URL
    private let fm = FileManager.default

    public init(scope: String, root: URL = NokPaths.support) {
        self.scope = scope
        journalURL = root.appendingPathComponent("Journals/\(scope).json")
        backupDir = root.appendingPathComponent("Backups/\(scope)", isDirectory: true)
        if let data = try? Data(contentsOf: journalURL),
           let decoded = try? Self.decoder.decode([JournalEntry].self, from: data) {
            entries = decoded
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
            if let expected = last.shaAfter {
                let current = fm.fileExists(atPath: path) ? (try? Hashing.sha256(file: url)) : nil
                if current != expected {
                    report.skipped.append((path, "it changed after Nokcandu edited it."))
                    remaining.append(contentsOf: forPath)
                    continue
                }
            }
            do {
                if let backup = first.backupPath {
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
