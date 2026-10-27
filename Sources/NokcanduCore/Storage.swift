import Foundation

/// Where the space goes: each game app, Nokcandu's own caches, and free space on each drive.
public enum Storage {
    public struct Item: Identifiable, Hashable {
        public var id: String { url.path }
        public var title: String
        public var url: URL
        public var bytes: Int64
        public var detail: String
    }

    public struct VolumeInfo: Identifiable, Hashable {
        public var id: String { url.path }
        public var name: String
        public var url: URL
        public var free: Int64
        public var total: Int64
    }

    /// Allocated size of a folder (du), following nothing outside it. APFS clones count fully here even
    /// though they share space, so engine files can look bigger than they really are.
    public static func size(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let r = try? Shell.run("/usr/bin/du", ["-sk", url.path], timeout: 300), r.ok,
              let kb = Int64(r.stdout.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "") else { return 0 }
        return kb * 1024
    }

    public struct GameUsage: Equatable {
        public struct Part: Equatable {
            public var title: String
            public var url: URL
            public var bytes: Int64?
            public var drive: String
        }
        public var parts: [Part]
        public var appOnly = false
        public var bytes: Int64 { parts.compactMap(\.bytes).reduce(0, +) }
        public var complete: Bool { parts.allSatisfy { $0.bytes != nil } }
        public var summary: String {
            let drives = Set(parts.map(\.drive))
            return (appOnly ? "App: " : "") + (complete ? "" : "At least ") + Storage.format(bytes) + " · " + (drives.count == 1 ? (drives.first ?? "Unknown drive") : "\(drives.count) drives")
        }
        public var detail: String {
            parts.map { "\($0.title): " + ($0.bytes.map(Storage.format) ?? "drive not connected") + " on \($0.drive)" }.joined(separator: " · ")
        }
    }
    public static func driveName(_ url: URL) -> String {
        if url.path.hasPrefix("/Volumes/"), url.pathComponents.count > 2 { return url.pathComponents[2] }
        return GameFolders.volumeName(url)
    }
    /// App/runtime plus separately stored game files and known Documents data. Never add a folder
    /// already inside another counted folder, and never follow arbitrary links while sizing the app.
    public static func usage(for g: InstalledGame) -> GameUsage {
        let app = g.native?.installFolder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } ?? g.appURL.resolvingSymlinksInPath()
        var roots: [(String, URL)] = [("App", app)]
        if let data = GameMover.externalFiles(g) ?? WineTools.places(for: g).first(where: { $0.title == "Game folder" })?.url {
            let resolved = data.resolvingSymlinksInPath()
            if !resolved.path.hasPrefix(app.path + "/"), resolved != app { roots.append(("Game files", resolved)) }
        }
        if let data = GameDataSpec.forGame(g)?.folder {
            let resolved = data.resolvingSymlinksInPath()
            if !roots.contains(where: { resolved == $0.1 || resolved.path.hasPrefix($0.1.path + "/") }) {
                roots.append(("Settings & saves", resolved))
            }
        }
        return GameUsage(parts: roots.map { title, url in
            GameUsage.Part(title: title, url: url, bytes: FileManager.default.fileExists(atPath: url.path) ? size(url) : nil, drive: driveName(url))
        }, appOnly: g.native != nil && g.native?.installFolder == nil)
    }

    public static func games(_ games: [InstalledGame]) -> [Item] {
        games.map { g in
            let logs = size(g.logs)
            var detail: [String] = []
            let folder = g.appURL.deletingLastPathComponent()
            if folder.path.hasPrefix("/Volumes/") { detail.append("on \(folder.pathComponents.count > 2 ? folder.pathComponents[2] : "another drive")") }
            var bytes = size(g.appURL)
            if let ext = GameMover.externalFiles(g) {
                let b = size(ext)
                detail.append("game files on \(ext.path.hasPrefix("/Volumes/") ? ext.pathComponents[2] : "another drive") (\(format(b)))")
                bytes += b
            }
            if logs > 1_000_000 { detail.append("logs \(format(logs))") }
            return Item(title: g.isSteamHost ? "Steam (all Steam games)" : g.name, url: g.appURL, bytes: bytes,
                        detail: detail.joined(separator: " · "))
        }.sorted { $0.bytes > $1.bytes }
    }

    public static func nokcanduData() -> [Item] {
        let s = NokPaths.support
        let parts: [(String, URL, String)] = [
            ("Engines cache", NokPaths.runtimes, "Verified Wine engines new games are copied from"),
            ("Downloads", NokPaths.downloads, "Installers and engine downloads (safe to empty)"),
            ("Work folder", s.appendingPathComponent("Work"), "Leftovers from interrupted jobs (safe to empty)"),
            ("Backups & undo history", NokPaths.backups, "Files Nokcandu replaced, kept so changes can be undone"),
            ("Diagnostics reports", NokPaths.diagnostics, ""),
        ]
        return parts.map { Item(title: $0.0, url: $0.1, bytes: size($0.1), detail: $0.2) }
    }

    public static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            return VolumeInfo(name: v.volumeName ?? u.lastPathComponent, url: u,
                              free: GameFolders.freeSpace(u) ?? 0, total: Int64(total))
        }
    }

    public static func format(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    // MARK: Clean-up actions (none touch game files, saves or settings)

    /// Empties every game's log files (keeps the files, so running games keep writing). Returns bytes freed.
    @discardableResult
    public static func clearLogs(_ games: [InstalledGame]) -> Int64 {
        var freed: Int64 = 0
        let fm = FileManager.default
        for g in games {
            guard let items = try? fm.contentsOfDirectory(at: g.logs, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for f in items {
                guard let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
                      let n = v.fileSize, n > 0 else { continue }
                if let h = try? FileHandle(forWritingTo: f) { try? h.truncate(atOffset: 0); try? h.close(); freed += Int64(n) }
            }
        }
        return freed
    }

    /// Removes everything inside a Nokcandu folder that's safe to empty (Downloads, Work).
    @discardableResult
    public static func empty(_ folder: URL) -> Int64 {
        let before = size(folder)
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        return before - size(folder)
    }
}
