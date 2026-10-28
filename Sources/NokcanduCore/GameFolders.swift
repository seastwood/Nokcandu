import Foundation
import Darwin

/// Folders that hold game apps. The first is always the standard one (~/Applications/Sikarugir or
/// ~/Applications/Nokcandu Games); people can add more, e.g. a folder on an external drive.
public enum GameFolders {
    struct Saved: Codable {
        var extra: [String] = []
        var installTo: String?
        /// Apps last seen in each extra folder (folder path → app file names), to list them while the drive is unplugged.
        var seen: [String: [String]]? = nil
    }
    static var file: URL { NokPaths.support.appendingPathComponent("game-folders.json") }
    static func load() -> Saved {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }
    static func save(_ s: Saved) {
        try? NokPaths.ensure(NokPaths.support)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(s).write(to: file, options: .atomic)
    }

    /// Every library folder, standard one first (including ones on drives that aren't plugged in).
    public static var all: [URL] {
        var out = [NokPaths.gameAppsFolder.standardizedFileURL]
        for p in load().extra {
            let u = URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL
            if !out.contains(u) { out.append(u) }
        }
        return out
    }
    public static func isStandard(_ u: URL) -> Bool { u.standardizedFileURL == NokPaths.gameAppsFolder.standardizedFileURL }
    /// The folder exists right now (an external drive may be unplugged).
    public static func isAvailable(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    /// Where new games (other than Steam and Battle.net) are installed.
    /// Where a new game's app goes for the chosen install folder, and where its files go if elsewhere.
    public static func installPlan(_ chosen: URL) -> (apps: URL, files: URL?) {
        holdsApps(chosen) ? (chosen, nil) : (NokPaths.gameAppsFolder, chosen)
    }

    public static var installFolder: URL {
        if let p = load().installTo {
            let u = URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL
            if all.contains(u), isAvailable(u) { return u }
        }
        return NokPaths.gameAppsFolder
    }
    public static func setInstallFolder(_ u: URL) {
        var s = load(); s.installTo = isStandard(u) ? nil : u.standardizedFileURL.path; save(s)
    }

    /// A drive's friendly name, e.g. "Macintosh HD" or "Games SSD".
    public static func volumeName(_ u: URL) -> String {
        var probe = u
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Unknown drive"
    }
    public static func freeSpace(_ u: URL) -> Int64? {
        let values = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let filesystem = (try? FileManager.default.attributesOfFileSystem(forPath: u.path)[.systemFreeSize]) as? NSNumber
        return [values?.volumeAvailableCapacityForImportantUsage, values?.volumeAvailableCapacity.map(Int64.init), filesystem?.int64Value]
            .compactMap { $0 }.filter { $0 >= 0 }.max()
    }

    /// Why a folder can't hold Wine games, or nil if it can. Wine prefixes need symbolic links and
    /// ordinary Unix permissions, so drives formatted ExFAT/FAT (common on new USB drives) won't work.
    public static func problem(with u: URL) -> String? {
        guard isAvailable(u) else { return "That folder isn't available." }
        guard FileManager.default.isWritableFile(atPath: u.path) else { return "Nokcandu can't write to that folder." }
        let v = try? u.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey, .volumeLocalizedFormatDescriptionKey, .volumeIsReadOnlyKey])
        if v?.volumeIsReadOnly == true { return "That drive is read-only." }
        return nil
    }

    /// Whole game apps can live here. Drives formatted ExFAT/FAT (common on USB drives) can't hold the app —
    /// Wine's setup needs symbolic links — so there Nokcandu keeps the small app on the Mac and stores
    /// only the game's own files on the drive, which works fine.
    public static func holdsApps(_ u: URL) -> Bool {
        var probe = u
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeSupportsSymbolicLinksKey, .volumeLocalizedFormatDescriptionKey])
        // macOS can report symbolic-link support on ExFAT even though it cannot host a Wine prefix
        // reliably. Keep those drives on the game-files-only path regardless of that capability flag.
        if values?.volumeLocalizedFormatDescription?.range(of: "fat", options: .caseInsensitive) != nil { return false }
        return values?.volumeSupportsSymbolicLinks ?? false
    }
    public static func formatName(_ u: URL) -> String {
        (try? u.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]).volumeLocalizedFormatDescription) ?? "?"
    }

    /// Adds a folder. Picking the top of a drive makes a "Nokcandu Games" folder on it. Returns the folder used.
    @discardableResult
    public static func add(_ picked: URL) throws -> URL {
        var u = picked.standardizedFileURL
        if let p = problem(with: u) { throw NokError(p) }
        let isVolumeRoot = (try? u.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
        if isVolumeRoot || u.path == "/" { u = u.appendingPathComponent("Nokcandu Games", isDirectory: true) }
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        if all.contains(u) { return u }
        var s = load(); s.extra.append(u.path); save(s)
        return u
    }

    /// Forgets a folder. Games stay in it on disk; they just stop showing in Nokcandu.
    public static func remove(_ u: URL) {
        var s = load()
        s.extra.removeAll { URL(fileURLWithPath: $0).standardizedFileURL == u.standardizedFileURL }
        if s.installTo.map({ URL(fileURLWithPath: $0).standardizedFileURL == u.standardizedFileURL }) == true { s.installTo = nil }
        save(s)
    }

    /// Remembers which apps are in each extra folder that's connected right now.
    public static func remember(_ games: [InstalledGame]) {
        var s = load(), seen = s.seen ?? [:], changed = false
        for f in all where !isStandard(f) && isAvailable(f) {
            let names = games.filter { folder(of: $0) == f }.map(\.appURL.lastPathComponent).sorted()
            if seen[f.path] != names { seen[f.path] = names; changed = true }
        }
        if changed { s.seen = seen; save(s) }
    }

    /// Games whose whole app is on a drive that isn't connected: (name, drive name).
    public static func offlineGames() -> [(name: String, drive: String)] {
        let s = load()
        return all.filter { !isStandard($0) && !isAvailable($0) }.flatMap { f in
            (s.seen?[f.path] ?? []).map { (name: ($0 as NSString).deletingPathExtension, drive: f.pathComponents.count > 2 && f.path.hasPrefix("/Volumes/") ? f.pathComponents[2] : f.lastPathComponent) }
        }
    }

    /// The library folder a game is in.
    public static func folder(of g: InstalledGame) -> URL { g.appURL.deletingLastPathComponent().standardizedFileURL }
}

/// Moving a game app to another library folder (e.g. onto an external drive to free up space).
public enum GameMover {
    /// Why this game can't be moved, or nil. Steam, Battle.net and the games that run inside them stay
    /// in the standard folder because other apps point at them.
    public static func blocker(_ g: InstalledGame) -> String? {
        if g.native != nil { return "Mac games stay where they are — Nokcandu only opens them. Move the app in Finder, then add it again." }
        if g.isSteamHost { return "Steam stays in the standard folder — your Steam games run inside it." }
        if g.usesSharedSteam { return "Steam games are stored inside Steam, so they move with it, not on their own." }
        if BattleNet.isHost(g) { return "Battle.net stays in the standard folder — your Blizzard games run inside it." }
        if g.battleNet != nil { return "Blizzard games are stored inside Battle.net, so they can't be moved on their own." }
        if let h = g.hosted { return "Use \(h.launcher.title)’s storage controls to move its installed game files. This small Nokcandu app is only a shortcut." }
        if let k = PCLaunchers.kind(of: g) { return "\(k.title) stays in the standard folder — your \(k.title) games run inside it." }
        if case .launcherRunning = GameLauncher.runState(of: g) { return "Quit the game first." }
        return nil
    }

    // MARK: Game files only (any drive, including ExFAT)

    /// The game's own install folder inside drive_c (e.g. drive_c/Games/Battlefield 1942), from its program path.
    public static func gameFilesFolder(_ g: InstalledGame) -> URL? {
        g.custom.flatMap { gameFilesFolder(exe: $0.exe, prefix: g.prefix) }
    }
    public static func gameFilesFolder(exe: String, prefix: URL) -> URL? {
        guard let rel = CustomGames.driveCRelative(windowsPath: exe) else { return nil }
        var parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        parts.removeLast()                                     // the .exe
        let containers = ["games", "program files", "program files (x86)", "gog games", "gog.com", "users", "programdata"]
        var keep = 1
        if containers.contains(parts[0].lowercased()) { keep = 2 }
        if parts.count >= 3, parts[0].lowercased() == "users" { return nil }   // inside a user profile: leave it
        guard parts.count >= keep else { return nil }
        return prefix.appendingPathComponent("drive_c").appendingPathComponent(parts.prefix(keep).joined(separator: "/"), isDirectory: true)
    }

    /// Where the game's files really are when they've been moved off the Mac (the folder in drive_c is a link).
    public static func externalFiles(_ g: InstalledGame) -> URL? {
        guard let f = gameFilesFolder(g), let d = try? FileManager.default.destinationOfSymbolicLink(atPath: f.path) else { return nil }
        return d.hasPrefix("/") ? URL(fileURLWithPath: d, isDirectory: true) : f.deletingLastPathComponent().appendingPathComponent(d).standardizedFileURL
    }

    /// Nil when the game can start; otherwise e.g. "Connect Elements first".
    public static func missingDrive(_ g: InstalledGame) -> String? {
        guard let ext = externalFiles(g), !FileManager.default.fileExists(atPath: ext.path) else { return nil }
        return "\(g.name)'s files are on \(ext.path.hasPrefix("/Volumes/") ? ext.pathComponents[2] : "another drive"), which isn't connected. Connect it, then press Play again."
    }

    public static func filesBlocker(_ g: InstalledGame) -> String? {
        if g.native != nil { return "Mac games stay where they are — Nokcandu only opens them." }
        if g.usesSharedSteam { return "Steam games are stored by Steam — add a Steam library folder on that drive in Steam's own Settings → Storage." }
        if g.isSteamHost || BattleNet.isHost(g) || g.battleNet != nil || g.hosted != nil || PCLaunchers.kind(of: g) != nil {
            return "Launchers choose where games go themselves: pick the drive in Steam's or Battle.net's own install options."
        }
        if case .launcherRunning = GameLauncher.runState(of: g) { return "Quit the game first." }
        if gameFilesFolder(g) == nil { return "Nokcandu can't tell which folder holds this game's files." }
        return nil
    }

    /// Copies a folder without Mac-only extras (keeps ExFAT drives free of "._" files).
    public static func copyPlain(_ from: URL, _ to: URL) throws {
        let r = try Shell.run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noacl", from.path, to.path], timeout: 6 * 3600)
        guard r.ok else { throw NokError("Copying failed: \(r.combined.suffix(300))") }
        try removeCopiedMacMetadata(in: to)
    }

    /// Called only on a newly created copy. Some Windows engines scan every filename and crash
    /// when AppleDouble sidecars look like game data. Do not touch the source or arbitrary ._ files.
    static func removeCopiedMacMetadata(in folder: URL) throws {
        let fm = FileManager.default
        func scan(_ directory: URL) throws {
            guard let stream = opendir(directory.path) else { throw NokError("Cannot check copied game files: \(directory.path)") }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let file = directory.appendingPathComponent(name)
                var attributes = stat()
                guard lstat(file.path, &attributes) == 0 else { continue }
                let type = attributes.st_mode & S_IFMT
                if type == S_IFDIR { try scan(file); continue }
                guard type == S_IFREG, name.hasPrefix("._"), let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let header = try? handle.read(upToCount: 4)
                try? handle.close()
                if header == Data([0x00, 0x05, 0x16, 0x07]) { try fm.removeItem(at: file) }
            }
        }
        // Foundation's URL enumerator can omit AppleDouble files, so inspect directory entries.
        try scan(folder)

    }

    /// Moves just the game's files to `folder` (any drive) and leaves a link in their place, so the app,
    /// its settings and every path inside Windows stay the same. `folder` = nil brings them back to the Mac.
    @discardableResult
    public static func moveFiles(_ g: InstalledGame, to folder: URL?, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> URL {
        if let b = filesBlocker(g) { throw NokError(b) }
        guard let inPrefix = gameFilesFolder(g) else { throw NokError("Unknown game folder.") }
        if folder == nil, externalFiles(g) == nil { throw NokError("\(g.name)'s files are already on this Mac.") }
        if let m = missingDrive(g) { throw NokError(m) }
        return try relocate(inPrefix, to: folder, progress: progress)
    }

    /// `inPrefix` is the game's folder in drive_c (a real folder, or a link to where the files are).
    @discardableResult
    public static func relocate(_ inPrefix: URL, to folder: URL?, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let linked = (try? fm.destinationOfSymbolicLink(atPath: inPrefix.path)).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let current = linked ?? inPrefix
        guard fm.fileExists(atPath: current.path) else { throw NokError("The game's files are missing (\(current.path)).") }
        let need = Storage.size(current)
        let dest: URL
        if let folder {
            if let p = GameFolders.problem(with: folder) { throw NokError(p) }
            dest = folder.appendingPathComponent(inPrefix.lastPathComponent, isDirectory: true)
            guard dest.standardizedFileURL != current.standardizedFileURL else { throw NokError("They're already there.") }
            guard !fm.fileExists(atPath: dest.path) else { throw NokError("\(folder.path)/\(inPrefix.lastPathComponent) already exists. Rename or remove it first.") }
        } else {
            guard linked != nil else { return inPrefix }
            dest = inPrefix
        }
        if let free = GameFolders.freeSpace(folder ?? inPrefix.deletingLastPathComponent()), free < need + 200_000_000 {
            throw NokError("Not enough space: the game's files need \(Storage.format(need)), \(Storage.format(free)) is free.")
        }
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).nokcandu-moving")
        try? fm.removeItem(at: staging)
        progress("Copying \(Storage.format(need))…")
        do { try copyPlain(current, staging) } catch { try? fm.removeItem(at: staging); throw error }
        // Swap: the old link (or folder) goes, the new folder (or link) takes its place.
        if folder == nil {
            try fm.removeItem(at: inPrefix)                          // the link
            try fm.moveItem(at: staging, to: inPrefix)
            progress("Removing the copy on the drive…")
            try? fm.removeItem(at: current)
        } else {
            try fm.moveItem(at: staging, to: dest)
            let backup = inPrefix.deletingLastPathComponent().appendingPathComponent(".\(inPrefix.lastPathComponent).nokcandu-old")
            try fm.moveItem(at: inPrefix, to: backup)
            do { try fm.createSymbolicLink(atPath: inPrefix.path, withDestinationPath: dest.path) }
            catch { try? fm.moveItem(at: backup, to: inPrefix); throw error }
            progress("Removing the old copy…")
            try? fm.removeItem(at: backup)
            if current != inPrefix { try? fm.removeItem(at: current) }   // was on another drive before
        }
        return dest
    }

    /// Moves the app into `folder`, keeping it working there. `progress` gets short status lines.
    /// Returns the app's new location.
    @discardableResult
    public static func move(_ g: InstalledGame, to folder: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> URL {
        if let b = blocker(g) { throw NokError(b) }
        let fm = FileManager.default
        let dest = folder.standardizedFileURL
        guard GameFolders.holdsApps(dest) else { throw NokError("Whole apps can't live on \(GameFolders.volumeName(dest)) (\(GameFolders.formatName(dest))); move just the game's files there instead.") }
        guard dest != GameFolders.folder(of: g) else { throw NokError("\(g.name) is already there.") }
        if let p = GameFolders.problem(with: dest) { throw NokError(p) }
        let target = dest.appendingPathComponent(g.appURL.lastPathComponent)
        guard !fm.fileExists(atPath: target.path) else { throw NokError("There's already an app called \(g.appURL.lastPathComponent) in that folder.") }

        // Disc images stay mounted inside the app; eject them so the copy doesn't include their contents.
        if let mounts = try? fm.contentsOfDirectory(at: g.support, includingPropertiesForKeys: nil) {
            for m in mounts where m.lastPathComponent.hasPrefix("MountedDisc") {
                _ = try? Shell.run("/usr/bin/hdiutil", ["detach", m.path, "-force"], timeout: 60)
            }
        }
        let sameDrive = volumeID(g.appURL) != nil && volumeID(g.appURL) == volumeID(dest)
        if sameDrive {
            progress("Moving…")
            try fm.moveItem(at: g.appURL, to: target)
        } else {
            let need = Storage.size(g.appURL)
            if let free = GameFolders.freeSpace(dest), free < need + 500_000_000 {
                throw NokError("Not enough space on \(GameFolders.volumeName(dest)): \(g.name) needs \(Storage.format(need)), \(Storage.format(free)) is free.")
            }
            progress("Copying \(Storage.format(need)) to \(GameFolders.volumeName(dest))…")
            let partial = dest.appendingPathComponent(".\(g.appURL.lastPathComponent).nokcandu-moving")
            try? fm.removeItem(at: partial)
            do {
                try fm.copyItem(at: g.appURL, to: partial)
                try fm.moveItem(at: partial, to: target)
            } catch {
                try? fm.removeItem(at: partial)
                throw NokError("Copying \(g.name) failed, so it was left where it was: \(error.localizedDescription)")
            }
        }
        progress("Updating paths inside the game…")
        do { try fixPaths(in: target, from: g.appURL) }
        catch {
            if sameDrive {
                try? fm.moveItem(at: target, to: g.appURL)
                try? fixPaths(in: g.appURL, from: target)
            } else { try? fm.removeItem(at: target) }
            throw NokError("The move couldn't finish updating paths. The original game was kept: \(error.localizedDescription)")
        }
        if !sameDrive {
            progress("Removing the old copy…")
            do { try fm.removeItem(at: g.appURL) }
            catch { progress("The old copy couldn't be removed (\(error.localizedDescription)); you can delete it in Finder.") }
        }
        return target
    }

    static func volumeID(_ u: URL) -> NSObject? {
        var probe = u
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
    }

    /// Points what referred to the old location at the new one: Wine's drive links and the registry's
    /// font paths (Z:\Users\…\Old.app\…).
    static func fixPaths(in app: URL, from old: URL) throws {
        let fm = FileManager.default
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        let oldPath = old.standardizedFileURL.path, newPath = app.standardizedFileURL.path
        let dos = prefix.appendingPathComponent("dosdevices")
        for name in (try? fm.contentsOfDirectory(atPath: dos.path)) ?? [] {
            let link = dos.appendingPathComponent(name)
            guard let d = try? fm.destinationOfSymbolicLink(atPath: link.path), d.hasPrefix(oldPath + "/") || d == oldPath else { continue }
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: newPath + d.dropFirst(oldPath.count))
        }
        let contents = app.appendingPathComponent("Contents")
        if var config = CustomGameConfig.load(contents: contents) {
            config.environment = config.environment?.mapValues { $0.replacingOccurrences(of: oldPath + "/", with: newPath + "/") }
            let launcher = contents.appendingPathComponent("MacOS/" + CustomGames.launcherName)
            if let data = try? Data(contentsOf: launcher), let text = String(data: data, encoding: .utf8) {
                let owned = config.launcherSHA == Hashing.sha256(data: data)
                let rewritten = Data(text.replacingOccurrences(of: oldPath + "/", with: newPath + "/").utf8)
                if rewritten != data { try rewritten.write(to: launcher, options: .atomic) }
                if owned { config.launcherSHA = Hashing.sha256(data: rewritten) }
            }
            try config.encoded().write(to: CustomGameConfig.url(in: contents), options: .atomic)
        }
        func winPath(_ p: String) -> String { "Z:" + p.replacingOccurrences(of: "/", with: "\\\\") }
        let (o, n) = (winPath(oldPath), winPath(newPath))
        for reg in ["system.reg", "user.reg", "userdef.reg"] {
            let u = prefix.appendingPathComponent(reg)
            guard let data = try? Data(contentsOf: u), var s = String(data: data, encoding: .utf8), s.contains(o) else { continue }
            s = s.replacingOccurrences(of: o, with: n)
            try? s.write(to: u, atomically: true, encoding: .utf8)
        }
    }
}

/// How the sidebar lists games: sort order, favorites and when each was last played.
public enum LibraryOrganizer {
    public enum Sort: String, Codable, CaseIterable, Identifiable {
        case name, recent, custom
        public var id: String { rawValue }
        public var title: String {
            switch self { case .name: return "Name"; case .recent: return "Recently Played"; case .custom: return "My Order" }
        }
    }
    struct Saved: Codable {
        var sort: Sort = .name
        var order: [String] = []
        var favorites: [String] = []
        var played: [String: Date] = [:]
        /// Your own subtitles for games (shown under the name in the sidebar).
        var subtitles: [String: String]? = nil
        /// Names you gave Mac games (their app isn't Nokcandu's to rename).
        var names: [String: String]? = nil
    }
    static var file: URL { NokPaths.support.appendingPathComponent("library-order.json") }
    static func load() -> Saved {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }
    static func save(_ s: Saved) {
        try? NokPaths.ensure(NokPaths.support)
        try? JSONEncoder().encode(s).write(to: file, options: .atomic)
    }

    /// A key that survives moving or renaming the app.
    public static func key(_ g: InstalledGame) -> String { g.bundleIdentifier ?? g.appURL.lastPathComponent }

    /// Steam and Battle.net themselves, as opposed to games.
    public static func isLauncher(_ g: InstalledGame) -> Bool { g.isSteamHost || BattleNet.isHost(g) || PCLaunchers.kind(of: g) != nil }

    public static func subtitle(_ g: InstalledGame) -> String? { load().subtitles?[key(g)] }
    public static func nameOverride(_ g: InstalledGame) -> String? { load().names?[key(g)] }

    /// The game's real title, for matching it with profiles, fixes and anti-cheat data — unaffected by renaming.
    public static func canonicalName(_ g: InstalledGame) -> String {
        g.custom?.name ?? g.battleNet?.name ?? g.hosted?.name ?? g.native?.name ?? g.name
    }

    /// Renames a game as shown in Nokcandu, the Dock and Finder, and sets (or clears) its subtitle.
    public static func rename(_ g: InstalledGame, to name: String, subtitle: String?) throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw NokError("Give the game a name.") }
        var v = load()
        let sub = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        var subs = v.subtitles ?? [:]; subs[key(g)] = (sub?.isEmpty ?? true) ? nil : sub; v.subtitles = subs
        if g.native != nil {
            var names = v.names ?? [:]; names[key(g)] = n == canonicalName(g) ? nil : n; v.names = names
        } else if n != g.name {
            let plist = g.contents.appendingPathComponent("Info.plist")
            guard var d = NSDictionary(contentsOf: plist) as? [String: Any] else { throw NokError("Couldn't read the app's details.") }
            d["CFBundleName"] = n
            d["CFBundleDisplayName"] = n
            try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: plist, options: .atomic)
            _ = try? Shell.run("/usr/bin/touch", [g.appURL.path])
        }
        save(v)
    }

    public static var sort: Sort { load().sort }
    public static func setSort(_ s: Sort) {
        var v = load(); v.sort = s; save(v)
    }
    public static func isFavorite(_ g: InstalledGame) -> Bool { load().favorites.contains(key(g)) }
    public static var favoriteKeys: Set<String> { Set(load().favorites) }
    public static func setFavorite(_ g: InstalledGame, _ on: Bool) {
        var v = load(); v.favorites.removeAll { $0 == key(g) }; if on { v.favorites.append(key(g)) }; save(v)
    }
    public static func notePlayed(_ g: InstalledGame, at date: Date = Date()) {
        var v = load(); v.played[key(g)] = date; save(v)
    }
    /// Last time the game was started: Nokcandu's own record, or the game's launch log for older games.
    public static func lastPlayed(_ g: InstalledGame) -> Date? {
        let recorded = load().played[key(g)]
        let log = (try? g.logs.appendingPathComponent("launch.log").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return [recorded, log].compactMap { $0 }.max()
    }

    /// Games in sidebar order.
    public static func sorted(_ games: [InstalledGame]) -> [InstalledGame] {
        let v = load()
        let byName: (InstalledGame, InstalledGame) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch v.sort {
        case .name:
            return games.sorted(by: byName)
        case .recent:
            let dates = Dictionary(games.map { ($0.id, lastPlayed($0) ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
            return games.sorted { a, b in
                let (x, y) = (dates[a.id]!, dates[b.id]!)
                return x != y ? x > y : byName(a, b)
            }
        case .custom:
            let pos = Dictionary(v.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            // Games not placed yet go after the placed ones, by name.
            return games.sorted { a, b in
                switch (pos[key(a)], pos[key(b)]) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName(a, b)
                }
            }
        }
    }

    /// Saves a new custom order (switching to "My Order"). `visible` is the list as shown, after the move.
    public static func setOrder(_ visible: [InstalledGame]) {
        var v = load()
        let keys = visible.map(key)
        v.order = keys + v.order.filter { !keys.contains($0) }
        v.sort = .custom
        save(v)
    }
}
