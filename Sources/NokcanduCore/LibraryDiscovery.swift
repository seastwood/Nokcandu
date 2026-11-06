import Foundation

/// Finding games Nokcandu already made, wherever they are. Every game app is self-contained (its engine, Windows
/// setup and settings live inside it), so after reinstalling Nokcandu, on a new Mac, or with a drive of games
/// copied from elsewhere, adding the folders that hold them is all it takes — nothing is copied or rebuilt.
public enum LibraryDiscovery {
    /// Folders below `root` (down to `depth` levels) that directly hold Nokcandu game apps, and how many each holds.
    /// Skips hidden folders (restore points, the Trash), app bundles' insides and folders already in the library.
    public static func folders(in root: URL, depth: Int = 3, known: [URL] = GameFolders.all, library: Set<String> = []) -> [(folder: URL, games: Int)] {
        let fm = FileManager.default
        let knownPaths = Set(known.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var out: [(URL, Int)] = []
        func visit(_ dir: URL, _ level: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
            var apps = 0
            var subfolders: [URL] = []
            for u in items {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { continue }           // links point at apps counted where they really are
                if u.pathExtension == "app" {
                    if !library.contains(u.resolvingSymlinksInPath().standardizedFileURL.path), isGameApp(u) { apps += 1 }
                } else if v?.isDirectory == true, level < depth, !skipped(u) {
                    subfolders.append(u)
                }
            }
            if apps > 0, !knownPaths.contains(dir.resolvingSymlinksInPath().standardizedFileURL.path) { out.append((dir, apps)) }
            for s in subfolders { visit(s, level + 1) }
        }
        visit(root, 0)
        return out.sorted { $0.0.path < $1.0.path }
    }

    static func skipped(_ u: URL) -> Bool {
        let n = u.lastPathComponent.lowercased()
        return ["system", "library", "private", "usr", "bin", "sbin", "cores", "dev", "volumes", "applications"].contains(n) && u.pathComponents.count <= 2
            || n.hasSuffix(".sparsebundle") || n.hasSuffix(".photoslibrary") || n == "node_modules" || n == "drive_c"
    }

    /// A Nokcandu game app (a Windows game, launcher or store game), not just any app.
    static func isGameApp(_ app: URL) -> Bool {
        guard let g = GameLibrary.inspect(app) else { return false }
        return g.native == nil
    }

    /// Connected drives' folders holding Nokcandu games that aren't in the library yet (looked for at start, and
    /// when a drive is connected). Network drives are left out (too slow to look through); add those by hand.
    public static func onConnectedDrives(known: [URL] = GameFolders.all, library: [InstalledGame] = []) -> [(folder: URL, games: Int)] {
        let have = Set(library.map { $0.appURL.resolvingSymlinksInPath().standardizedFileURL.path })
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [(URL, Int)] = []
        for v in volumes {
            let r = try? v.resourceValues(forKeys: Set(keys))
            guard r?.volumeIsLocal == true, r?.volumeIsBrowsable != false, r?.volumeIsRootFileSystem != true else { continue }
            out += folders(in: v, depth: 2, known: known, library: have)
        }
        // The usual places on this Mac.
        for home in [NokPaths.home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            out += folders(in: home, depth: 1, known: known, library: have)
        }
        return out
    }

    /// Folders offered once and turned down aren't offered again.
    static let declinedKey = "libraryDiscoveryDeclined"
    public static func notDeclined(_ found: [(folder: URL, games: Int)], defaults: UserDefaults = .standard) -> [(folder: URL, games: Int)] {
        let no = Set(defaults.stringArray(forKey: declinedKey) ?? [])
        return found.filter { !no.contains($0.folder.path) }
    }
    public static func decline(_ folders: [URL], defaults: UserDefaults = .standard) {
        defaults.set(Array(Set((defaults.stringArray(forKey: declinedKey) ?? []) + folders.map(\.path))), forKey: declinedKey)
    }
    /// Adds the folders to the library. Returns how many were added.
    @discardableResult
    public static func add(_ folders: [URL]) -> Int {
        folders.filter { (try? GameFolders.add($0)) != nil }.count
    }
}
