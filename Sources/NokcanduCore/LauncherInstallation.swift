import Foundation

/// File-backed installation state is shared across launcher discovery and removal. Registry/manifests
/// are retained as recovery information; stale records never prove that files are still installed.
public enum LauncherInstallation {
    public enum Presence: Equatable { case present, missing, offline, unknown }
    public static func presence(at url: URL?) -> Presence {
        guard let url else { return .unknown }
        let fm = FileManager.default, file = url.resolvingSymlinksInPath().standardizedFileURL
        let parts = file.pathComponents
        // An unplugged drive can leave an empty /Volumes/<name> folder behind: only a mounted drive counts.
        if parts.count >= 3 && parts[1] == "Volumes" && !isMountPoint(URL(fileURLWithPath: "/Volumes/" + parts[2])) { return .offline }
        if fm.isDirectory(file) { return .present }
        // Permission errors must not masquerade as an uninstall.
        var parent = file.deletingLastPathComponent()
        while !fm.fileExists(atPath: parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
        return fm.isReadableFile(atPath: parent.path) ? .missing : .unknown
    }
    /// Is this folder where a drive is mounted (not just a folder of the same name)?
    static func isMountPoint(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &st.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        return mountedOn == url.resolvingSymlinksInPath().path
    }
    static func windowsFolder(_ path: String, prefix: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "/", with: "\\")
        guard !normalized.contains("\0"), !normalized.split(separator: "\\").contains("..") else { return nil }
        return BattleNet.unixPath(normalized, prefix: prefix)?.standardizedFileURL
    }
    struct Location {
        var folder: URL
        var host: InstalledGame
        var launcher: String
        var otherFolders: [URL]
        var manifest: URL? = nil
    }
    static func location(for game: InstalledGame) -> Location? {
        if let link = game.hosted, let host = GameLibrary.inspect(URL(fileURLWithPath: link.hostApp)),
           let selected = PCLaunchers.registeredGames(link.launcher, host: host).first(where: { $0.id == link.id }),
           let folder = windowsFolder(selected.installLocation, prefix: host.prefix) {
            let others = PCLauncher.allCases.flatMap { kind in
                PCLaunchers.registeredGames(kind, host: host).filter { kind != link.launcher || $0.id != link.id }
                    .compactMap { windowsFolder($0.installLocation, prefix: host.prefix) }
            } + BattleNet.registeredGames(host: host).compactMap { windowsFolder($0.installLocation, prefix: host.prefix) }
            return Location(folder: folder, host: host, launcher: link.launcher.title, otherFolders: others)
        }
        if let link = game.battleNet, let host = GameLibrary.inspect(URL(fileURLWithPath: link.hostApp)),
           let selected = BattleNet.registeredGames(host: host).first(where: { $0.uid == link.uid }),
           let folder = windowsFolder(selected.installLocation, prefix: host.prefix) {
            let others = BattleNet.registeredGames(host: host).filter { $0.uid != link.uid }.compactMap { windowsFolder($0.installLocation, prefix: host.prefix) }
                + PCLauncher.allCases.flatMap { PCLaunchers.registeredGames($0, host: host).compactMap { windowsFolder($0.installLocation, prefix: host.prefix) } }
            return Location(folder: folder, host: host, launcher: "Battle.net", otherFolders: others)
        }
        if game.usesSharedSteam, let id = game.custom?.steamAppID,
           let host = GameLibrary.inspect(SharedSteam.contents.deletingLastPathComponent()),
           let selected = SharedSteam.registeredGames(in: SharedSteam.libraryFolders()).first(where: { $0.appID == id }), let folder = selected.folder {
            let all = SharedSteam.registeredGames(in: SharedSteam.libraryFolders())
            let manifest = selected.library?.appendingPathComponent("steamapps/appmanifest_\(id).acf")
            return Location(folder: folder, host: host, launcher: "Steam", otherFolders: all.filter { $0.appID != id }.compactMap(\.folder), manifest: manifest)
        }
        return nil
    }
    static func overlap(_ a: URL, _ b: URL) -> Bool {
        let x = a.resolvingSymlinksInPath().standardizedFileURL.path
        let y = b.resolvingSymlinksInPath().standardizedFileURL.path
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }
    /// Validate at preview and immediately before trashing. Never infer the game root from bin/ or an
    /// executable's parent: that could be a shared launcher directory, or only a fraction of the game.
    static func removalBlocker(_ location: Location, game: InstalledGame, library: [InstalledGame]) -> String? {
        let fm = FileManager.default, root = location.folder.resolvingSymlinksInPath().standardizedFileURL
        switch presence(at: location.folder) {
        case .offline: return "Connect the game's drive to remove its files."
        case .missing: return "The registered game folder is already gone."
        case .unknown: return "The game's folder could not be checked. Its files will be kept."
        case .present: break
        }
        let parts = root.pathComponents
        if root.path == "/" || (parts.count <= 3 && root.path.hasPrefix("/Volumes/")) { return "A drive root cannot be removed as a game folder." }
        let sharedNames: Set<String> = ["games", "ea games", "gog games", "steamapps", "common", "program files", "program files (x86)", "applications", "downloads", "documents", "desktop", "users", "windows", "programdata"]
        if sharedNames.contains(root.lastPathComponent.lowercased()) { return "This is a shared folder, not a dedicated game folder." }
        var boundaries = [fm.homeDirectoryForCurrentUser, location.host.appURL, location.host.prefix]
        boundaries += GameFolders.all
        boundaries += Drives.list(for: location.host).map { URL(fileURLWithPath: $0.target) }
        boundaries += [fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")]
        if boundaries.contains(where: { boundary in
            let p = boundary.resolvingSymlinksInPath().standardizedFileURL.path
            return root.path == p || p.hasPrefix(root.path + "/")
        }) { return "This folder contains a shared library or Windows environment and cannot be removed as one game." }
        let protected = ["windows", "users", "ProgramData", "nokcandu", "Program Files/Common Files", "Program Files (x86)/Common Files"]
            .map { location.host.prefix.appendingPathComponent("drive_c/" + $0) }
        if protected.contains(where: { overlap(root, $0) }) { return "This is shared Windows data, not a dedicated game folder." }
        if let exe = location.host.custom?.exe, let program = windowsFolder(exe, prefix: location.host.prefix), overlap(root, program.deletingLastPathComponent()) {
            return "The folder is used by the launcher itself."
        }
        if location.otherFolders.contains(where: { overlap(root, $0) }) { return "Another launcher game uses this folder or a folder inside it. Its files will be kept." }
        for other in library where other.appURL != game.appURL && other.appURL != location.host.appURL && fm.fileExists(atPath: other.appURL.path) {
            if let folder = self.location(for: other)?.folder ?? GameMover.gameFilesFolder(other), overlap(root, folder) {
                return "Another Nokcandu game uses this folder. Remove its shortcut first or manage the files in the launcher."
            }
        }
        return nil
    }
}
