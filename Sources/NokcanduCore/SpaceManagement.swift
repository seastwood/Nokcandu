import Foundation
import Darwin

// Keeping Nokcandu's own bookkeeping in step with where apps really are, and keeping the space it uses
// for safety copies (restore points, engine roll-back copies, logs) bounded.

// MARK: - Saved install progress follows moved apps

public enum InstallRecords {
    static func stateFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: NokPaths.installs, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("state.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func rewrite(_ value: String, from old: String, to new: String) -> String {
        value == old ? new : value.hasPrefix(old + "/") ? new + value.dropFirst(old.count) : value
    }

    /// Points saved install progress for the app at `old` at its new place. Paths inside its inputs (the icon
    /// source, for example) follow too. Returns how many records changed.
    @discardableResult
    public static func relocate(from old: URL, to new: URL) -> Int {
        let oldPath = old.standardizedFileURL.path, newPath = new.standardizedFileURL.path
        guard oldPath != newPath else { return 0 }
        var changed = 0
        for file in stateFiles() {
            guard let data = try? Data(contentsOf: file),
                  var state = try? ChangeJournal.decoder.decode(InstallState.self, from: data),
                  URL(fileURLWithPath: state.targetApp).standardizedFileURL.path == oldPath else { continue }
            state.targetApp = newPath
            state.inputs = state.inputs.mapValues { rewrite($0, from: oldPath, to: newPath) }
            if (try? ChangeJournal.encoder.encode(state).write(to: file, options: .atomic)) != nil { changed += 1 }
        }
        return changed
    }

    /// Records left pointing at a place the app no longer is (moved by an older Nokcandu or in Finder): when
    /// exactly one game in the library has that app's file name and the old place holds no real app, follow it.
    @discardableResult
    public static func reconcile(library: [InstalledGame]) -> Int {
        var fixed = 0
        for file in stateFiles() {
            guard let data = try? Data(contentsOf: file),
                  let state = try? ChangeJournal.decoder.decode(InstallState.self, from: data) else { continue }
            let target = URL(fileURLWithPath: state.targetApp)
            guard !FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path) else { continue }
            let matches = library.filter {
                $0.native == nil && $0.appURL.lastPathComponent == target.lastPathComponent
                    && $0.appURL.standardizedFileURL.path != target.standardizedFileURL.path
            }
            guard matches.count == 1, let app = matches.first else { continue }
            fixed += relocate(from: target, to: app.appURL)
        }
        return fixed
    }
}

// MARK: - Ghost app folders

/// Small app folders that settings were written into after the game had moved away: no Info.plist and
/// nothing in them but Nokcandu's own generated files. They are not games and make the installer think an
/// installation is unfinished.
public enum GhostApps {
    static let generated: Set<String> = ["game-launcher"]
    /// `confirmedOnly`: only folders whose game is in the library somewhere else (safe to clean automatically).
    public static func find(library: [InstalledGame], confirmedOnly: Bool = false) -> [URL] {
        let fm = FileManager.default
        let real = Set(library.map { $0.appURL.lastPathComponent })
        var found: [URL] = []
        for folder in GameFolders.all where GameFolders.isAvailable(folder) {
            for app in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                where app.pathExtension == "app" {
                guard (try? fm.destinationOfSymbolicLink(atPath: app.path)) == nil,
                      !fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path),
                      real.contains(app.lastPathComponent) || (!confirmedOnly && fm.fileExists(atPath: app.appendingPathComponent("Contents/SharedSupport/nokcandu").path)),
                      onlyGeneratedFiles(app) else { continue }
                found.append(app)
            }
        }
        return found
    }
    static func onlyGeneratedFiles(_ app: URL) -> Bool {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return false }
        var total = 0, files = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { return false }
            guard v?.isRegularFile == true else { continue }
            files += 1; total += v?.fileSize ?? 0
            let rel = u.path.dropFirst(app.path.count + 1)
            let allowed = rel.hasPrefix("Contents/SharedSupport/nokcandu/") || rel.hasPrefix("Contents/SharedSupport/Logs/")
                || (rel.hasPrefix("Contents/MacOS/") && generated.contains(u.lastPathComponent))
            if !allowed || files > 64 || total > 2_000_000 { return false }
        }
        return true
    }
    /// Moves ghosts to the Trash. Returns how many.
    @discardableResult
    public static func clean(library: [InstalledGame]) -> Int {
        find(library: library, confirmedOnly: true).filter { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }.count
    }
}

/// True while the app is really there: settings must never recreate a folder for an app that moved.
public enum AppPresence {
    /// The app folder is still there (an app that moved away leaves nothing at its old path; writing there
    /// would create a ghost folder).
    public static func exists(_ contents: URL) -> Bool {
        FileManager.default.fileExists(atPath: contents.deletingLastPathComponent().path)
    }
}

// MARK: - Restore point housekeeping

extension RestorePoints {
    /// Automatic restore points older than this are removed (ones you took yourself are kept).
    public static let automaticMaxAge: TimeInterval = 30 * 24 * 3600

    /// Restore-point folders whose app is gone from that folder (moved to another drive or removed).
    public struct Orphan: Identifiable, Hashable, Sendable {
        public var id: String { folder.path }
        public var name: String
        public var folder: URL
        public var points: Int
        /// At least this much is freed (the newest point in full; older ones share most of its blocks).
        public var reclaimable: Int64
        public var movedTo: String?
    }

    public static func orphans(library: [InstalledGame]) -> [Orphan] {
        let fm = FileManager.default
        var out: [Orphan] = []
        var roots = Set(GameFolders.all.filter(GameFolders.isAvailable).map { $0.resolvingSymlinksInPath().path })
        roots.formUnion(library.map { $0.appURL.resolvingSymlinksInPath().deletingLastPathComponent().path })
        for root in roots {
            let base = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
            for d in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let app = URL(fileURLWithPath: root).appendingPathComponent(d.lastPathComponent + ".app")
                // Still here (a link to an app on another drive doesn't count: its points can't follow it).
                if (try? fm.destinationOfSymbolicLink(atPath: app.path)) == nil,
                   fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) { continue }
                let points = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let newest = points.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
                let moved = library.first { $0.appURL.lastPathComponent == app.lastPathComponent }
                out.append(Orphan(name: d.lastPathComponent, folder: d, points: points.count,
                                  reclaimable: newest.map { Storage.allocatedSize($0) } ?? 0,
                                  movedTo: moved.map { Storage.driveName($0.appURL) }))
            }
        }
        return out.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Permanently removes an orphaned restore-point folder (its app is gone, so it can't be restored anyway).
    public static func remove(_ orphan: Orphan) throws {
        let fm = FileManager.default
        guard orphan.folder.deletingLastPathComponent().lastPathComponent == folderName,
              (try? fm.destinationOfSymbolicLink(atPath: orphan.folder.path)) == nil else { throw NokError("That isn't a restore-point folder.") }
        try fm.removeItem(at: orphan.folder)
        let parent = orphan.folder.deletingLastPathComponent()
        if ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty { try? fm.removeItem(at: parent) }
    }

    /// Old automatic points beyond the age limit, for every app (yours are never touched).
    @discardableResult
    public static func pruneOld(library: [InstalledGame], now: Date = Date()) -> Int {
        var removed = 0
        var seen = Set<String>()
        for g in library {
            guard let app = hostApp(for: g), seen.insert(app.resolvingSymlinksInPath().path).inserted else { continue }
            let autos = list(app: app).filter(\.automatic)
            // Always keep the newest one, however old.
            for p in autos.dropFirst() where now.timeIntervalSince(p.created) > automaticMaxAge {
                if (try? FileManager.default.removeItem(at: p.folder)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// After an app moved: on the same drive its restore points move with it (instantly); on another drive they
    /// can't (they're clones of the old copy), so they're removed unless `keepOld`, and a fresh one is taken at
    /// the new place for free. Returns a short note for the user, or nil.
    @discardableResult
    public static func followMove(from old: URL, to new: URL, keepOld: Bool) -> String? {
        let fm = FileManager.default
        let oldRoot = root(for: old), newRoot = root(for: new)
        guard fm.fileExists(atPath: oldRoot.path), oldRoot.resolvingSymlinksInPath() != newRoot.resolvingSymlinksInPath() else { return nil }
        if GameMover.volumeID(old.deletingLastPathComponent()) == GameMover.volumeID(new.deletingLastPathComponent()) {
            try? fm.createDirectory(at: newRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: newRoot.path), (try? fm.moveItem(at: oldRoot, to: newRoot)) != nil { return nil }
            return nil
        }
        var note: String?
        if !keepOld {
            let bytes = (try? fm.contentsOfDirectory(at: oldRoot, includingPropertiesForKeys: nil))?.first.map { Storage.allocatedSize($0) } ?? 0
            if (try? fm.removeItem(at: oldRoot)) != nil { note = "Removed its old restore points from \(Storage.driveName(old)) (at least \(Storage.format(bytes)))." }
        }
        if automaticEnabled { _ = try? create(app: new, reason: "After moving to \(Storage.driveName(new))", automatic: true) }
        return note
    }
}

// MARK: - Engine roll-back copies

extension EngineUpdate {
    /// A new engine that has been played for a week is kept automatically: the copy of the old engine kept for
    /// rolling back is removed (a restore point taken before the change can still go back).
    public static let autoKeepAfter: TimeInterval = 7 * 24 * 3600

    public static func rollbackBytes(_ g: InstalledGame) -> Int64 {
        let rb = rollbackDir(g.contents)
        return FileManager.default.fileExists(atPath: rb.path) ? Storage.size(rb) : 0
    }
    public static func hasRollbackCopy(_ g: InstalledGame) -> Bool {
        FileManager.default.fileExists(atPath: rollbackDir(g.contents).path)
    }

    /// Keeps engines tried long enough and played since. Returns the names of the apps kept.
    public static func autoKeep(_ games: [InstalledGame], now: Date = Date()) -> [String] {
        var kept: [String] = []
        for g in hosts(in: games) {
            guard let st = state(for: g), st.status == .trying, now.timeIntervalSince(st.appliedAt) > autoKeepAfter,
                  let played = LibraryOrganizer.lastPlayed(g), played > st.appliedAt,
                  GameLauncher.runState(of: g) == .notRunning else { continue }
            if (try? keep(g)) != nil { kept.append(g.name) }
        }
        return kept
    }
}

// MARK: - Logs

/// Game logs are for troubleshooting, so only recent ones are kept: anything older than a month goes, each
/// game keeps at most 20 MB (oldest first), and all games together at most 150 MB.
public enum LogRetention {
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    public static let perGameBudget: Int64 = 20_000_000
    public static let totalBudget: Int64 = 150_000_000
    /// Files a running launcher may still be writing are never touched within this window.
    static let activeWindow: TimeInterval = 10 * 60
    static let extensions: Set<String> = ["log", "txt"]

    struct File { var url: URL; var size: Int64; var modified: Date; var current: Bool }

    static func files(in folder: URL) -> [File] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []).compactMap { u in
            guard extensions.contains(u.pathExtension.lowercased()),
                  let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true, v.isSymbolicLink != true else { return nil }
            // The current launch/Steam log is read back by Nokcandu (crash hints, diagnostics): kept unless too big.
            let current = ["launch.log", "steam.log"].contains(u.lastPathComponent)
            return File(url: u, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast, current: current)
        }
    }

    /// Returns bytes freed.
    @discardableResult
    public static func prune(_ games: [InstalledGame], now: Date = Date()) -> Int64 {
        var freed: Int64 = 0
        var survivors: [File] = []
        var seen = Set<String>()
        for g in games where g.native == nil {
            let folder = g.logs.resolvingSymlinksInPath()
            guard seen.insert(folder.path).inserted, AppPresence.exists(g.contents) else { continue }
            var list = files(in: folder).sorted { $0.modified < $1.modified }
            func remove(_ f: File) { if (try? FileManager.default.removeItem(at: f.url)) != nil { freed += f.size } }
            list = list.filter { f in
                guard now.timeIntervalSince(f.modified) > activeWindow else { return true }
                if !f.current, now.timeIntervalSince(f.modified) > maxAge { remove(f); return false }
                return true
            }
            var total = list.reduce(0) { $0 + $1.size }
            for f in list where total > perGameBudget && !f.current && now.timeIntervalSince(f.modified) > activeWindow {
                remove(f); total -= f.size
            }
            survivors += list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        var total = survivors.reduce(0) { $0 + $1.size }
        for f in survivors.sorted(by: { $0.modified < $1.modified }) where total > totalBudget && !f.current && now.timeIntervalSince(f.modified) > activeWindow {
            if (try? FileManager.default.removeItem(at: f.url)) != nil { freed += f.size; total -= f.size }
        }
        // Nokcandu's own diagnostics reports: the 10 newest.
        let reports = ((try? FileManager.default.contentsOfDirectory(at: NokPaths.diagnostics, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for r in reports.dropFirst(10) {
            let n = Storage.allocatedSize(r)
            if (try? FileManager.default.removeItem(at: r)) != nil { freed += n }
        }
        return freed
    }
}

// MARK: - Space suggestions

/// Things Nokcandu can safely free, with how much each frees. Nothing here is a game, a save or a setting.
public enum SpaceSaver {
    public enum Kind: String, Sendable { case orphanRestorePoints, ghostApp, rollbackCopy, downloads, logs, exfatOverhead }
    public struct Suggestion: Identifiable, Hashable, Sendable {
        public var id: String { kind.rawValue + ":" + url.path }
        public var kind: Kind
        public var title: String
        public var detail: String
        public var url: URL
        public var bytes: Int64
        /// Info only (e.g. ExFAT overhead): no one-click action.
        public var actionTitle: String?
        public var gameID: String?
    }

    public static func suggestions(library: [InstalledGame]) -> [Suggestion] {
        var out: [Suggestion] = []
        for o in RestorePoints.orphans(library: library) {
            let why = o.movedTo.map { "\(o.name) now lives on \($0); restore points can't follow it to another drive." } ?? "\(o.name) isn't in your library any more."
            out.append(Suggestion(kind: .orphanRestorePoints, title: "Restore points for \(o.name)",
                                  detail: "\(o.points) restore point\(o.points == 1 ? "" : "s") on \(Storage.driveName(o.folder)). \(why)",
                                  url: o.folder, bytes: o.reclaimable, actionTitle: "Delete"))
        }
        for g in GhostApps.find(library: library) {
            out.append(Suggestion(kind: .ghostApp, title: "Leftover \(g.lastPathComponent)",
                                  detail: "An empty app folder left behind when the game moved. It isn't a game; it can make Nokcandu think an install is unfinished.",
                                  url: g, bytes: Storage.allocatedSize(g), actionTitle: "Move to Trash"))
        }
        for g in EngineUpdate.hosts(in: library) where EngineUpdate.hasRollbackCopy(g) {
            let bytes = EngineUpdate.rollbackBytes(g)
            let since = EngineUpdate.state(for: g)?.appliedAt.formatted(date: .abbreviated, time: .omitted) ?? "a while"
            out.append(Suggestion(kind: .rollbackCopy, title: "Previous engine kept for \(g.name)",
                                  detail: "Trying \(g.wineVersion ?? "a new engine") since \(since). Keeping it removes the copy of the old engine" + (bytes < 50_000_000 ? " (shared with the engines cache here, so it costs little)." : "."),
                                  url: EngineUpdate.rollbackDir(g.contents), bytes: bytes, actionTitle: "Keep New Engine", gameID: g.id))
        }
        let downloads = Storage.size(NokPaths.downloads)
        if downloads > 50_000_000 {
            out.append(Suggestion(kind: .downloads, title: "Downloaded installers", detail: "Installers and engine downloads Nokcandu already used.",
                                  url: NokPaths.downloads, bytes: downloads, actionTitle: "Empty"))
        }
        for g in library where g.native == nil {
            guard let files = GameMover.externalFiles(g), FileManager.default.fileExists(atPath: files.path),
                  !GameFolders.holdsApps(files) else { continue }
            let (apparent, allocated) = Storage.apparentAndAllocated(files)
            let waste = allocated - apparent
            guard waste > 200_000_000, Double(waste) > Double(apparent) * 0.15 else { continue }
            out.append(Suggestion(kind: .exfatOverhead, title: "\(g.name)'s files waste space on \(Storage.driveName(files))",
                                  detail: "\(Storage.format(apparent)) of files take \(Storage.format(allocated)) there: the drive is formatted ExFAT, which stores each small file in a large block. On an APFS volume they would take about \(Storage.format(apparent)).",
                                  url: files, bytes: waste, actionTitle: "Move…", gameID: g.id))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }
}

extension Storage {
    /// (sum of file sizes, space they take on the drive). Links aren't followed.
    public static func apparentAndAllocated(_ url: URL) -> (Int64, Int64) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return (0, 0) }
        var apparent: Int64 = 0, allocated: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            apparent += Int64(v.fileSize ?? 0); allocated += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return (apparent, allocated)
    }
}
