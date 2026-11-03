import Foundation

/// Where the space goes: each game app, Nokcandu's own caches, and free space on each drive.
public enum Storage {
    public struct Item: Identifiable, Hashable {
        public var id: String { url.path }
        public var title: String
        public var url: URL
        public var bytes: Int64
        public var detail: String
        public var incomplete = false
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
        measure(url, excluding: excluding, privateOnly: true)
    }
    /// Allocated file blocks, including blocks shared with APFS clones. This
    /// describes an app's contents and copy capacity, rather than deletion savings.
    public static func allocatedSize(_ url: URL, excluding: [URL] = []) -> Int64 {
        measure(url, excluding: excluding, privateOnly: false)
    }
    private static func measure(_ url: URL, excluding: [URL], privateOnly: Bool) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        func one(_ u: URL) -> Int64 {
            if privateOnly, let p = privateSize(u) { return p }
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
        public var unavailableGameFilesDrive: String? = nil
        public var bytes: Int64 { parts.compactMap(\.bytes).reduce(0, +) }
        public var complete: Bool { parts.allSatisfy { $0.bytes != nil } && unavailableGameFilesDrive == nil }
        public var summary: String {
            var drives = Set(parts.map(\.drive))
            if let drive = unavailableGameFilesDrive, drive != "an unknown drive" { drives.insert(drive) }
            return (appOnly ? "App: " : "") + (complete ? "" : "At least ") + Storage.format(bytes) + " · " + (drives.count == 1 ? (drives.first ?? "Unknown drive") : "\(drives.count) drives")
        }
        public var detail: String {
            var details = parts.map { "\($0.title): " + ($0.bytes.map(Storage.format) ?? "unavailable") + " on \($0.drive)" }
            if let drive = unavailableGameFilesDrive { details.append("Game files: unavailable on " + drive) }
            return details.joined(separator: " · ")
        }
    }
    public static func driveName(_ url: URL) -> String {
        if url.path.hasPrefix("/Volumes/"), url.pathComponents.count > 2 { return url.pathComponents[2] }
        return GameFolders.volumeName(url)
    }
    /// App/runtime plus separately stored game files and known Documents data. Never add a folder
    /// already inside another counted folder, and never follow arbitrary links while sizing the app.
    public static func usage(for g: InstalledGame, includingLauncherGames: Bool = true) -> GameUsage {
        let originalApp = g.appURL.resolvingSymlinksInPath()
        let nativeFolder = g.native?.installFolder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        let app = nativeFolder.flatMap { originalApp.path.hasPrefix($0.path + "/") ? $0 : nil } ?? originalApp
        // Launcher summaries may include games across several drives. The Settings
        // inventory lists those games individually, so its launcher row excludes them.
        var hosted: [(String, URL)] = []
        for (name, folder) in launcherGames(in: g).map({ ($0.0, $0.1.resolvingSymlinksInPath()) }).sorted(by: { $0.1.path.count < $1.1.path.count }) {
            guard folder != app, !app.path.hasPrefix(folder.path + "/"),
                  !hosted.contains(where: { folder == $0.1 || folder.path.hasPrefix($0.1.path + "/") }) else { continue }
            hosted.append((name, folder))
        }
        if !hosted.isEmpty {
            var parts = [GameUsage.Part(title: g.isSteamHost ? "Steam" : "Launcher", url: app, bytes: FileManager.default.fileExists(atPath: app.path) ? allocatedSize(app, excluding: hosted.filter { $0.1.path.hasPrefix(app.path + "/") }.map(\.1)) : nil, drive: driveName(app))]
            if includingLauncherGames {
                parts += hosted.map { name, url in GameUsage.Part(title: name, url: url, bytes: FileManager.default.fileExists(atPath: url.path) ? allocatedSize(url) : nil, drive: driveName(url)) }
            }
            return GameUsage(parts: parts)
        }
        var roots: [(String, URL)] = [(app != originalApp ? "App & game files" : "App", app)]
        let launcherFolder = (g.usesSharedSteam || g.battleNet != nil || g.hosted != nil) ? LauncherInstallation.location(for: g)?.folder : nil
        var candidates = [nativeFolder, launcherFolder, GameMover.externalFiles(g),
                          WineTools.places(for: g).first(where: { $0.title == "Game folder" })?.url].compactMap { $0 }
        if g.native == nil, !g.usesSharedSteam, g.battleNet == nil, g.hosted == nil,
           !g.isSteamHost, !BattleNet.isHost(g), PCLaunchers.kind(of: g) == nil {
            candidates += linkedGameFolders(in: g)
        }
        for data in candidates.map({ $0.resolvingSymlinksInPath() }).sorted(by: { $0.path.count < $1.path.count }) {
            if !roots.contains(where: { data == $0.1 || data.path.hasPrefix($0.1.path + "/") }),
               !app.path.hasPrefix(data.path + "/") {
                roots.append(("Game files", data))
            }
        }
        if let data = GameDataSpec.forGame(g)?.folder {
            let resolved = data.resolvingSymlinksInPath()
            if !roots.contains(where: { resolved == $0.1 || resolved.path.hasPrefix($0.1.path + "/") }) {
                roots.append(("Settings & saves", resolved))
            }
        }
        var result = GameUsage(parts: roots.map { title, url in
            GameUsage.Part(title: title, url: url, bytes: FileManager.default.fileExists(atPath: url.path) ? allocatedSize(url) : nil, drive: driveName(url))
        }, appOnly: g.native != nil && g.native?.installFolder == nil)
        if launcherFolder == nil, g.usesSharedSteam || g.battleNet != nil || g.hosted != nil,
           !roots.contains(where: { $0.0 == "Game files" }) {
            result.unavailableGameFilesDrive = g.custom?.steamAppID.flatMap(SharedSteam.offlineDrive) ?? "an unknown drive"
        }
        return result
    }

    /// Private apps can launch a hub/client outside the game's folder. Count their
    /// explicit game-directory links even when the selected executable changes.
    /// Never walk users/, dosdevices/ or arbitrary symlinks inside the app.
    static func linkedGameFolders(in game: InstalledGame) -> [URL] {
        let fm = FileManager.default, app = game.appURL.resolvingSymlinksInPath()
        var queue = ["Games", "GOG Games", "GOG.com", "Program Files", "Program Files (x86)"].map {
            (game.prefix.appendingPathComponent("drive_c/" + $0), 0)
        }
        var result: [URL] = [], visited = 0, inspected = 0
        while !queue.isEmpty, visited < 256, inspected < 10_000 {
            let (folder, depth) = queue.removeFirst(); visited += 1
            // A container itself can be linked to a shared library: don't scan it.
            guard (try? fm.destinationOfSymbolicLink(atPath: folder.path)) == nil else { continue }
            for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [] {
                inspected += 1; if inspected > 10_000 { break }
                if let link = try? fm.destinationOfSymbolicLink(atPath: entry.path) {
                    let target = (link.hasPrefix("/") ? URL(fileURLWithPath: link) : folder.appendingPathComponent(link)).resolvingSymlinksInPath().standardizedFileURL
                    guard target.path != "/", !(target.path.hasPrefix("/Volumes/") && target.pathComponents.count <= 3),
                          target != NokPaths.home, !NokPaths.home.path.hasPrefix(target.path + "/"),
                          target != app, !target.path.hasPrefix(app.path + "/"), !app.path.hasPrefix(target.path + "/"),
                          !fm.fileExists(atPath: target.path) || fm.isDirectory(target) else { continue }
                    result.append(target)
                } else if depth < 1, (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    queue.append((entry, depth + 1))
                }
            }
        }
        return result
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
        games.map { game in
            let usage = usage(for: game, includingLauncherGames: false)
            let logs = allocatedSize(game.logs)
            var detail = usage.detail
            if game.isSteamHost || BattleNet.isHost(game) || PCLaunchers.kind(of: game) != nil {
                detail = "Launcher & shared Windows environment · " + detail
            }
            if logs > 1_000_000 { detail += " · logs " + format(logs) }
            return Item(title: game.name, url: game.appURL, bytes: usage.bytes,
                        detail: detail, incomplete: !usage.complete)
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
