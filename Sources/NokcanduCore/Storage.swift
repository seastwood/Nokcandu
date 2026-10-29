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

    /// Space a file or folder really uses: on APFS only the bytes not shared with clones (each game app's
    /// Wine engine is a clone of the same files, so counting it in full overstated every game by ~1.4 GB);
    /// elsewhere (ExFAT…) the allocated size. Links aren't followed. `excluding` folders are skipped.
    public static func size(_ url: URL, excluding: [URL] = []) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        func one(_ u: URL) -> Int64 {
            if let p = privateSize(u) { return p }
            return Int64((try? u.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        if !isDir.boolValue { return one(url) }
        let skip = Set(excluding.map { $0.standardizedFileURL.path })
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            if !skip.isEmpty, skip.contains(u.standardizedFileURL.path) { e.skipDescendants(); continue }
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            total += one(u)
        }
        return total
    }

    /// Bytes of this file not shared with any APFS clone (nil where the drive doesn't report it).
    static func privateSize(_ u: URL) -> Int64? {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        al.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buf = [UInt8](repeating: 0, count: 64)
        let r = u.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return getattrlist(path, &al, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard r == 0 else { return nil }
        return buf.withUnsafeBytes { b -> Int64? in
            // u_int32 length, attribute_set_t returned (common, vol, dir, file, fork), then off_t private size
            let returnedFork = b.load(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            return b.loadUnaligned(fromByteOffset: 24, as: Int64.self)
        }
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
        // Launchers: games installed in the launcher's own library are listed separately, not as its size.
        let hosted = launcherGames(in: g).filter { $0.1.path.hasPrefix(app.path + "/") }
        if !hosted.isEmpty {
            var parts = [GameUsage.Part(title: g.isSteamHost ? "Steam" : "Launcher", url: app, bytes: size(app, excluding: hosted.map(\.1)), drive: driveName(app))]
            parts += hosted.map { name, url in GameUsage.Part(title: name, url: url, bytes: FileManager.default.fileExists(atPath: url.path) ? size(url) : nil, drive: driveName(url)) }
            return GameUsage(parts: parts)
        }
        var roots: [(String, URL)] = [("App", app)]
        let launcherFolder = (g.usesSharedSteam || g.battleNet != nil || g.hosted != nil) ? LauncherInstallation.location(for: g)?.folder : nil
        if let data = launcherFolder ?? GameMover.externalFiles(g) ?? WineTools.places(for: g).first(where: { $0.title == "Game folder" })?.url {
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

    /// Games a launcher app (Steam, Battle.net, EA, Ubisoft) has installed: (name, folder).
    static func launcherGames(in g: InstalledGame) -> [(String, URL)] {
        if g.isSteamHost { return SharedSteam.installedGames().compactMap { s in s.folder.map { (s.name, $0.standardizedFileURL) } } }
        if BattleNet.isHost(g) {
            return BattleNet.installedGames(host: g).compactMap { b in LauncherInstallation.windowsFolder(b.installLocation, prefix: g.prefix).map { (b.name, $0) } }
        }
        if let kind = PCLaunchers.kind(of: g) {
            return PCLaunchers.installedGames(kind, host: g).compactMap { h in LauncherInstallation.windowsFolder(h.installLocation, prefix: g.prefix).map { (h.name, $0) } }
        }
        return []
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
