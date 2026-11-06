import Foundation

/// A game added "where it is" runs from your own folder. Nokcandu keeps that folder as it was: its own changes
/// (fixes that put files beside the program, display corrections, settings it edits) are refused there unless you
/// allow them, and after each session it checks whether the game itself changed anything, so you can stop before
/// files you care about are changed. Copies and games installed by Nokcandu aren't affected.
public enum OriginalFiles {
    static func markerURL(_ g: InstalledGame) -> URL { g.support.appendingPathComponent("referenced-game-folder.txt") }
    static func allowURL(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("original-folder-changes-allowed") }
    static func manifestURL(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("original-folder.tsv") }
    static func changesURL(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("original-folder-changes.json") }

    /// Your folder, when this game uses it where it is.
    public static func folder(_ g: InstalledGame) -> URL? {
        guard let p = (try? String(contentsOf: markerURL(g), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// Protected unless you've allowed changes (only games that use a folder where it is).
    public static func isProtected(_ g: InstalledGame) -> Bool {
        folder(g) != nil && !FileManager.default.fileExists(atPath: allowURL(g).path)
    }
    public static func setAllowChanges(_ on: Bool, for g: InstalledGame) {
        if on { try? NokPaths.ensure(g.nokcanduState); FileManager.default.createFile(atPath: allowURL(g).path, contents: Data()) }
        else { try? FileManager.default.removeItem(at: allowURL(g)); record(g) }
    }

    /// Refuses Nokcandu's own writes into the protected folder.
    public static func check(_ g: InstalledGame, writing urls: [URL], action: String) throws {
        guard isProtected(g), let f = folder(g)?.resolvingSymlinksInPath().standardizedFileURL.path else { return }
        let inside = urls.filter { u in
            let p = resolvedWithoutFile(u)
            return p == f || p.hasPrefix(f + "/")
        }
        guard !inside.isEmpty else { return }
        throw NokError("\(action) would change files in your folder “\(URL(fileURLWithPath: f).lastPathComponent)” (\(inside.prefix(2).map(\.lastPathComponent).joined(separator: ", "))\(inside.count > 2 ? "…" : "")), which \(g.name) uses where it is. Nothing was changed. To allow it, turn off “Keep my folder unchanged” on the game's Storage tab, or add the game again as a copy.")
    }
    /// For changes that always land in the game's folder (display corrections, settings files beside the program).
    public static func check(_ g: InstalledGame, action: String) throws {
        guard isProtected(g), let f = folder(g) else { return }
        try check(g, writing: [f.appendingPathComponent("x")], action: action)
    }
    /// The real path of a file that may not exist yet (its folder resolved).
    static func resolvedWithoutFile(_ u: URL) -> String {
        let dir = u.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return dir.appendingPathComponent(u.lastPathComponent).path
    }

    // MARK: Changes the game makes

    public struct Changes: Codable, Equatable, Sendable {
        public var changed: [String]
        public var added: [String]
        public var removed: [String]
        public var checkedAt: Date
        public var count: Int { changed.count + added.count + removed.count }
        public var summary: String {
            var parts: [String] = []
            if !changed.isEmpty { parts.append("changed \(changed.count) file\(changed.count == 1 ? "" : "s")") }
            if !added.isEmpty { parts.append("added \(added.count)") }
            if !removed.isEmpty { parts.append("removed \(removed.count)") }
            return parts.joined(separator: ", ")
        }
        public var examples: [String] { Array((changed + added + removed).prefix(3)) }
    }

    /// Every file's size and modification time (relative path, size, seconds).
    static func snapshot(_ folder: URL, limit: Int = 250_000) -> [String: (Int64, Int64)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [:] }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var out: [String: (Int64, Int64)] = [:]
        for case let u as URL in e {
            guard out.count < limit, let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let p = u.resolvingSymlinksInPath().standardizedFileURL.path
            let rel = p.hasPrefix(base + "/") ? String(p.dropFirst(base.count + 1)) : u.lastPathComponent
            out[rel] = (Int64(v.fileSize ?? 0), Int64(v.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return out
    }

    /// Remembers the folder as it is now (when the game is added, and when you accept its changes).
    public static func record(_ g: InstalledGame) {
        guard let f = folder(g), FileManager.default.fileExists(atPath: f.path) else { return }
        let text = snapshot(f).sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value.0)\t\($0.value.1)" }.joined(separator: "\n")
        try? NokPaths.ensure(g.nokcanduState)
        try? Data(text.utf8).write(to: manifestURL(g), options: .atomic)
        try? FileManager.default.removeItem(at: changesURL(g))
    }

    public static func hasRecord(_ g: InstalledGame) -> Bool { FileManager.default.fileExists(atPath: manifestURL(g).path) }

    static func recorded(_ g: InstalledGame) -> [String: (Int64, Int64)]? {
        guard let text = try? String(contentsOf: manifestURL(g), encoding: .utf8) else { return nil }
        var out: [String: (Int64, Int64)] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard p.count == 3, let s = Int64(p[1]), let m = Int64(p[2]) else { continue }
            out[String(p[0])] = (s, m)
        }
        return out
    }

    /// Compares the folder with how it was; saves and returns what changed (nil when nothing did, or the game
    /// doesn't use a folder where it is). Call off the main thread, after the game quits.
    @discardableResult
    public static func checkForChanges(_ g: InstalledGame, now: Date = Date()) -> Changes? {
        guard isProtected(g), let f = folder(g), FileManager.default.fileExists(atPath: f.path) else { return nil }
        guard let before = recorded(g) else { record(g); return nil }
        let after = snapshot(f)
        let changed = after.keys.filter { k in before[k].map { $0 != after[k]! } ?? false }.sorted()
        let added = after.keys.filter { before[$0] == nil }.sorted()
        let removed = before.keys.filter { after[$0] == nil }.sorted()
        guard !(changed.isEmpty && added.isEmpty && removed.isEmpty) else { try? FileManager.default.removeItem(at: changesURL(g)); return nil }
        let c = Changes(changed: changed, added: added, removed: removed, checkedAt: now)
        try? ChangeJournal.encoder.encode(c).write(to: changesURL(g), options: .atomic)
        return c
    }

    /// The last changes found (shown on the game's page until accepted).
    public static func lastChanges(_ g: InstalledGame) -> Changes? {
        (try? Data(contentsOf: changesURL(g))).flatMap { try? ChangeJournal.decoder.decode(Changes.self, from: $0) }
    }
}
