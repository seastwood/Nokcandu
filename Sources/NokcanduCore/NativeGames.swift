import Foundation

/// Mac games in the library: apps Nokcandu doesn't run through Wine (OpenMW, a GOG/Epic Mac version…).
/// Nokcandu only remembers where they are; it doesn't change them.
public struct NativeGame: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var appPath: String
    /// Set when Nokcandu installed it from a store (then removing can also delete its files).
    public var store: StoreLink?
    /// The folder Nokcandu downloaded it into (store installs only).
    public var installFolder: String?
    public var addedAt = Date()
}

public enum NativeGames {
    static var file: URL { NokPaths.support.appendingPathComponent("mac-games.json") }

    public static func all() -> [NativeGame] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([NativeGame].self, from: $0) } ?? []
    }
    static func save(_ list: [NativeGame]) {
        try? NokPaths.ensure(NokPaths.support)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(list).write(to: file, options: .atomic)
    }

    /// Adds a Mac app (a .app, or a folder containing one) to the library.
    @discardableResult
    public static func add(_ url: URL, name: String? = nil, store: StoreLink? = nil, installFolder: URL? = nil) throws -> NativeGame {
        guard let app = url.pathExtension.lowercased() == "app" ? url : findApp(in: url) else {
            throw NokError("That isn't a Mac app (.app).")
        }
        var list = all()
        if let existing = list.first(where: { $0.appPath == app.standardizedFileURL.path }) { return existing }
        if GameLibrary.inspect(app) != nil { throw NokError("That's already a Nokcandu game.") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let n = name ?? (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
        let g = NativeGame(id: UUID().uuidString, name: n, appPath: app.standardizedFileURL.path, store: store, installFolder: installFolder?.path)
        list.append(g)
        save(list)
        return g
    }

    public static func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    /// The main .app inside a downloaded game folder (the biggest one, ignoring helpers).
    public static func findApp(in folder: URL) -> URL? {
        let fm = FileManager.default
        var apps: [URL] = []
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e {
                if u.pathExtension.lowercased() == "app" { apps.append(u); e.skipDescendants() }
                if e.level > 4 { e.skipDescendants() }
            }
        }
        let skip = ["uninstall", "crash", "helper", "updater", "launcher setup"]
        let good = apps.filter { a in !skip.contains { a.lastPathComponent.lowercased().contains($0) } }
        return (good.isEmpty ? apps : good).min { $0.pathComponents.count < $1.pathComponents.count }
    }

    public static func installedGame(_ n: NativeGame) -> InstalledGame? {
        let app = URL(fileURLWithPath: n.appPath)
        guard FileManager.default.fileExists(atPath: app.path) else { return nil }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        var g = InstalledGame(appURL: app, name: n.name, bundleIdentifier: info?["CFBundleIdentifier"] as? String)
        g.native = n
        if let o = LibraryOrganizer.nameOverride(g) { g.name = o }
        return g
    }

    /// Mac games whose app can't be found right now (e.g. on an unplugged drive): (name, drive).
    public static func missing() -> [(name: String, drive: String)] {
        all().filter { !FileManager.default.fileExists(atPath: $0.appPath) }.map { n in
            let c = URL(fileURLWithPath: n.appPath).pathComponents
            return (n.name, n.appPath.hasPrefix("/Volumes/") && c.count > 2 ? c[2] : "its drive")
        }
    }

    // MARK: Store Mac versions

    /// Downloads a store game's Mac version into `folder/<name>` and adds it to the library.
    public static func installFromStore(_ g: StoreGame, into folder: URL, log: @escaping @Sendable (String) -> Void) async throws -> NativeGame {
        try await StoreAccounts.checkSpace(g.store, id: g.id, mac: true, folder: folder)
        let dest = folder.appendingPathComponent(CustomGames.safeFolderName(g.title), isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let status: Int32
        switch g.store {
        case .gog:
            status = try await StoreTools.stream(.gog, ["download", g.id, "--platform", "osx", "--path", dest.path,
                                                        "--support", dest.appendingPathComponent(".gog-support").path, "--skip-dlcs"], log: log)
        case .epic:
            status = try await StoreTools.stream(.epic, ["install", g.id, "--base-path", folder.path, "--game-folder", dest.lastPathComponent,
                                                         "--platform", "Mac", "--skip-sdl", "-y"], log: log)
        case .amazon:
            throw NokError("Amazon Games has no Mac versions.")
        }
        guard status == 0 else { throw NokError("The download stopped (exit \(status)). Press Install again to resume.") }
        guard let app = findApp(in: dest) else { throw NokError("The download finished, but no Mac app was found in \(dest.path).") }
        return try add(app, name: g.title, store: StoreLink(store: g.store, id: g.id), installFolder: dest)
    }
}
