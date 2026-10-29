import Foundation

/// Removing a game completely: its app plus everything Nokcandu keeps for it elsewhere (undo backups,
/// change journal, install progress, notes). All of it goes to the Trash, so it can be put back.
/// Your own saved profiles (Game Profiles → My Profiles) are kept.
public enum GameRemoval {
    public struct Item: Identifiable, Hashable {
        public var id: String { url.path }
        public var url: URL
        public var what: String
        public var bytes: Int64
    }

    public enum Mode { case appOnly, appAndGameFiles }
    public struct FolderChoice {
        public var url: URL
        public var bytes: Int64
        public var drive: String
        var identity: String
        var associated: [Item] = []
    }
    public struct Plan {
        public var appItems: [Item]
        public var gameFolder: FolderChoice?
        public var folderUnavailable: String?
        public var launcherName: String?
        public var shared: Bool
        public var appBytes: Int64 { appItems.reduce(0) { $0 + $1.bytes } }
    }
    /// Same folder on disk (same drive and directory), not just the same path.
    public static func sameFolder(_ a: FolderChoice, _ b: FolderChoice) -> Bool { a.identity == b.identity }
    static func identity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber,
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw NokError("The game folder could not be verified.") }
        return "\(device):\(inode)"
    }
    public static func plan(for game: InstalledGame, library: [InstalledGame]) -> Plan {
        let shared = game.hosted != nil || game.battleNet != nil || game.usesSharedSteam
        var plan = Plan(appItems: items(for: game, library: library, includeGameFiles: false),
                        folderUnavailable: nil, launcherName: game.hosted?.launcher.title ?? (game.battleNet != nil ? "Battle.net" : game.usesSharedSteam ? "Steam" : nil), shared: shared)
        var root: URL?, associated: [Item] = []
        if shared {
            if let location = LauncherInstallation.location(for: game) {
                plan.launcherName = location.launcher
                if let reason = LauncherInstallation.removalBlocker(location, game: game, library: library) { plan.folderUnavailable = reason }
                else {
                    root = location.folder.resolvingSymlinksInPath().standardizedFileURL
                    if let manifest = location.manifest, FileManager.default.fileExists(atPath: manifest.path) {
                        associated.append(Item(url: manifest, what: "Steam installation record", bytes: size(manifest)))
                    }
                }
            } else { plan.folderUnavailable = "The launcher has no verified game-folder location. Remove only the app and keep the game files." }
        } else { root = removableExternalFiles(game, library: library) }
        if let root, let id = try? identity(root) {
            plan.gameFolder = FolderChoice(url: root, bytes: size(root), drive: Storage.driveName(root), identity: id, associated: associated)
        } else if root != nil { plan.folderUnavailable = "The game folder could not be verified. Its files will be kept." }
        return plan
    }

    static func size(_ u: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0 }
        var total: Int64 = 0
        let e = fm.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: nil)
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Everything that would be removed with this game.
    public static func items(for g: InstalledGame, library: [InstalledGame] = [], includeGameFiles: Bool = true) -> [Item] {
        let fm = FileManager.default
        var out = [Item(url: g.appURL, what: (g.hosted != nil || g.battleNet != nil || g.usesSharedSteam) ? "Nokcandu app (shortcut and its local settings)" : "The game app (including files and saves inside it)", bytes: size(g.appURL))]
        if includeGameFiles, let external = removableExternalFiles(g, library: library) {
            out.append(Item(url: external, what: "Game files on \(GameFolders.volumeName(external)): \(external.path) (including saves there)", bytes: size(external)))
        }
        let scope = g.journalScope
        let s = NokPaths.support
        for (u, what) in [(s.appendingPathComponent("Backups/\(scope)"), "Undo backups"),
                          (s.appendingPathComponent("Journals/\(scope).json"), "Change history"),
                          (s.appendingPathComponent("Notes/\(GameNotes.key(for: g)).json"), "Your notes for this game")]
            where fm.fileExists(atPath: u.path) {
            out.append(Item(url: u, what: what, bytes: size(u)))
        }
        for st in InstallExecutor.savedInstalls() where URL(fileURLWithPath: st.targetApp).standardizedFileURL.path == g.appURL.standardizedFileURL.path {
            let d = NokPaths.installs.appendingPathComponent(st.installID)
            if fm.fileExists(atPath: d.path) { out.append(Item(url: d, what: "Install progress", bytes: size(d))) }
            let j = s.appendingPathComponent("Journals/install-\(st.installID).json")
            if fm.fileExists(atPath: j.path) { out.append(Item(url: j, what: "Install change history", bytes: size(j))) }
        }
        return out
    }

    /// Only a game's dedicated folder in a registered library may be removed. Borrowed folders,
    /// shared launcher data and folders used by another game must stay.
    static func removableExternalFiles(_ g: InstalledGame, library: [InstalledGame], folders: [URL] = GameFolders.all) -> URL? {
        let fm = FileManager.default
        guard g.custom != nil, !g.usesSharedSteam, g.battleNet == nil, g.hosted == nil,
              !fm.fileExists(atPath: g.support.appendingPathComponent("referenced-game-folder.txt").path),
              let external = GameMover.externalFiles(g)?.resolvingSymlinksInPath(),
              fm.isDirectory(external),
              folders.contains(where: { $0.resolvingSymlinksInPath().path == external.deletingLastPathComponent().path }) else { return nil }
        for other in library where other.appURL != g.appURL {
            guard let files = GameMover.gameFilesFolder(other)?.resolvingSymlinksInPath() else { continue }
            if files.path == external.path || files.path.hasPrefix(external.path + "/") || external.path.hasPrefix(files.path + "/") { return nil }
        }
        return external
    }

    /// Why this game can't be removed right now (nil = it can).
    public static func blocker(_ g: InstalledGame, library: [InstalledGame]) -> String? {
        if case .launcherRunning = GameLauncher.runState(of: g) { return "Quit the game first." }
        if g.isSteamHost {
            if SharedSteam.isRunning { return "Quit Steam first." }
            let dependents = library.filter(\.usesSharedSteam)
            if !dependents.isEmpty { return "Your Steam games (\(dependents.map(\.name).joined(separator: ", "))) run inside this Steam. Remove them first." }
        }
        if BattleNet.isHost(g) {
            let dependents = library.filter { $0.battleNet != nil }
            if !dependents.isEmpty { return "Your Battle.net games (\(dependents.map(\.name).joined(separator: ", "))) run inside this Battle.net. Remove them first." }
        }
        if let kind = PCLaunchers.kind(of: g) {
            let dependents = library.filter { $0.hosted.map { URL(fileURLWithPath: $0.hostApp).resolvingSymlinksInPath() == g.appURL.resolvingSymlinksInPath() } ?? false }
            if !dependents.isEmpty { return "Your \(kind.title) games use this launcher. Remove their Nokcandu apps first." }
        }
        return nil
    }

    /// Files go first: an external-drive Trash failure must not leave an orphaned installation.
    /// The previewed directory identity is rechecked before any mutation. No permanent-delete fallback.
    @discardableResult
    public static func remove(_ game: InstalledGame, library: [InstalledGame], mode: Mode = .appOnly,
                              expectedFolder: FolderChoice? = nil) throws -> [String] {
        try remove(game, library: library, mode: mode, expectedFolder: expectedFolder, trash: {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        })
    }
    static func remove(_ game: InstalledGame, library: [InstalledGame], mode: Mode,
                       expectedFolder: FolderChoice?, trash: (URL) throws -> Void) throws -> [String] {
        if let reason = blocker(game, library: library) { throw NokError(reason) }
        let current = plan(for: game, library: library)
        var removalItems = current.appItems
        if mode == .appAndGameFiles {
            guard let expected = expectedFolder, let folder = current.gameFolder,
                  expected.url == folder.url, expected.identity == folder.identity else {
                throw NokError("The game folder changed or is no longer available. Nothing was removed; open Remove Game again to review its location.")
            }
            if current.shared, let contents = WineTools.hostContents(for: game), !WineTools.ownedProcesses(contents: contents).isEmpty {
                throw NokError("Close the launcher and its Windows games before removing game files.")
            }
            removalItems = [Item(url: folder.url, what: "Game files", bytes: folder.bytes)] + folder.associated + removalItems
        }
        // Eject mounted images in this app, never in the shared launcher.
        if let mounts = try? FileManager.default.contentsOfDirectory(at: game.support, includingPropertiesForKeys: nil) {
            for mount in mounts where mount.lastPathComponent.hasPrefix("MountedDisc") {
                _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60)
            }
        }
        var failures: [String] = []
        for item in removalItems {
            do { try trash(item.url) }
            catch {
                failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                break // Keep the app and records if the game files could not be trashed.
            }
        }
        // The app's restore points go with it (to the Trash, so they can still be recovered).
        let points = RestorePoints.root(for: game.appURL)
        if failures.isEmpty, !FileManager.default.fileExists(atPath: game.appURL.path), FileManager.default.fileExists(atPath: points.path) {
            try? trash(points)
        }
        return failures
    }

    /// Leftovers from games that no longer exist (removed in Finder, older versions, tests).
    public static func orphans(library: [InstalledGame]) -> [Item] {
        let fm = FileManager.default
        let s = NokPaths.support
        let scopes = Set(library.map(\.journalScope))
        let apps = Set(library.map { $0.appURL.standardizedFileURL.path })
        var out: [Item] = []
        for name in (try? fm.contentsOfDirectory(atPath: s.appendingPathComponent("Backups").path)) ?? []
            where name.hasPrefix("game-") && !scopes.contains(name) {
            let u = s.appendingPathComponent("Backups/\(name)"); out.append(Item(url: u, what: "Undo backups of a removed game", bytes: size(u)))
        }
        let unfinished = Set(InstallExecutor.savedInstalls().filter { $0.finishedAt == nil }.map(\.installID))
        for name in (try? fm.contentsOfDirectory(atPath: s.appendingPathComponent("Journals").path)) ?? [] {
            let base = (name as NSString).deletingPathExtension
            if base.hasPrefix("game-"), !scopes.contains(base) {
                let u = s.appendingPathComponent("Journals/\(name)"); out.append(Item(url: u, what: "Change history of a removed game", bytes: size(u)))
            } else if base.hasPrefix("install-"), !unfinished.contains(String(base.dropFirst("install-".count))),
                      !fm.fileExists(atPath: NokPaths.installs.appendingPathComponent(String(base.dropFirst("install-".count))).path) {
                let u = s.appendingPathComponent("Journals/\(name)"); out.append(Item(url: u, what: "Change history of an old install", bytes: size(u)))
            }
        }
        for st in InstallExecutor.savedInstalls() where !apps.contains(URL(fileURLWithPath: st.targetApp).standardizedFileURL.path)
            && !fm.fileExists(atPath: st.targetApp) {
            let u = NokPaths.installs.appendingPathComponent(st.installID); out.append(Item(url: u, what: "Install progress for an app that's gone", bytes: size(u)))
        }
        return out
    }

    public static func clean(_ items: [Item]) -> Int {
        items.filter { (try? FileManager.default.trashItem(at: $0.url, resultingItemURL: nil)) != nil }.count
    }
}
