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

    public static func games(_ games: [InstalledGame]) -> [Item] {
        games.map { g in
            let logs = size(g.logs)
            return Item(title: g.isSteamHost ? "Steam (all Steam games)" : g.name, url: g.appURL, bytes: size(g.appURL),
                        detail: logs > 1_000_000 ? "logs \(format(logs))" : "")
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
                              free: v.volumeAvailableCapacityForImportantUsage ?? 0, total: Int64(total))
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
