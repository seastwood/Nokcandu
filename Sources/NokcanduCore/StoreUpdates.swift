import Foundation

/// Updates for games installed from GOG and Epic (Steam and the launchers update their own games).
/// Epic: legendary compares installed and latest versions. GOG: the build gogdl installed (its
/// manifest) against the newest public build for the platform.
public enum StoreUpdates {
    public struct Available: Codable, Hashable, Sendable {
        public var link: StoreLink
        public var installed: String
        public var latest: String
        public var mac: Bool
    }

    /// The store link and whether it's the Mac version, for a game installed from GOG or Epic.
    public static func link(_ g: InstalledGame) -> (StoreLink, mac: Bool)? {
        if let n = g.native, let s = n.store, s.store != .amazon { return (s, true) }
        if let s = g.custom?.store, s.store != .amazon, !g.usesSharedSteam { return (s, false) }
        return nil
    }

    // MARK: Epic

    /// "  -> Update available! Installed: 1.0, Latest: 1.1" lines after " * Title (App name: X | …".
    public static func parseLegendary(_ text: String) -> [String: (installed: String, latest: String)] {
        var out: [String: (String, String)] = [:]
        var current: String?
        for line in text.components(separatedBy: .newlines) {
            if let r = line.range(of: #"App name: [^ |)]+"#, options: .regularExpression) {
                current = String(line[r].dropFirst("App name: ".count))
            } else if line.contains("Update available"), let id = current,
                      let i = line.range(of: #"Installed: [^,]+"#, options: .regularExpression),
                      let l = line.range(of: #"Latest: \S+"#, options: .regularExpression) {
                out[id] = (String(line[i].dropFirst("Installed: ".count)), String(line[l].dropFirst("Latest: ".count)))
            }
        }
        return out
    }

    // MARK: GOG

    static var gogManifests: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/heroic_gogdl/manifests", isDirectory: true)
    }
    public static func gogInstalledBuild(_ id: String) -> String? {
        guard let d = try? Data(contentsOf: gogManifests.appendingPathComponent(id)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["buildId"] as? String
    }

    public static func supportOwner(from start: URL) -> URL? {
        var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".gog-support").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func gogHasDLC(_ id: String) -> Bool {
        guard let d = try? Data(contentsOf: gogManifests.appendingPathComponent(id)),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return !((j["HGLdlcs"] as? [Any]) ?? []).isEmpty
    }

    /// The folder holding goggame-<id>.info (the game's root), searched upward from the program.
    public static func gogRoot(from start: URL, id: String) -> URL? {
        var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("goggame-\(id).info").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func gogLatest(_ id: String, mac: Bool) async -> (build: String, name: String?)? {
        guard let r = try? await StoreTools.capture(.gog, ["info", id, "--platform", mac ? "osx" : "windows"], timeout: 60), r.status == 0,
              let j = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any], let b = j["buildId"] as? String else { return nil }
        return (b, j["versionName"] as? String)
    }

    // MARK: Checking

    /// Checks every GOG/Epic game in the library. Keyed by the game's id (app path).
    public static func check(_ games: [InstalledGame]) async -> [String: Available] {
        var out: [String: Available] = [:]
        let linked = games.compactMap { g in link(g).map { (g, $0.0, $0.mac) } }
        if linked.contains(where: { $0.1.store == .epic }), StoreAccounts.isSignedIn(.epic),
           let r = try? await StoreTools.capture(.epic, ["list-installed", "--check-updates"], timeout: 120) {
            let found = parseLegendary(String(decoding: r.out, as: UTF8.self) + "\n" + r.err)
            for (g, l, mac) in linked where l.store == .epic {
                if let u = found[l.id] { out[g.id] = Available(link: l, installed: u.installed, latest: u.latest, mac: mac) }
            }
        }
        if StoreAccounts.isSignedIn(.gog) {
            for (g, l, mac) in linked where l.store == .gog {
                guard let have = gogInstalledBuild(l.id), let latest = await gogLatest(l.id, mac: mac), latest.build != have else { continue }
                out[g.id] = Available(link: l, installed: have, latest: latest.name ?? latest.build, mac: mac)
            }
        }
        ListCache.save(out, "store-updates")
        return out
    }

    public static func cached() -> (value: [String: Available], saved: Date)? {
        ListCache.load("store-updates", as: [String: Available].self).map { ($0.value, $0.saved) }
    }

    // MARK: Updating

    public static func update(_ g: InstalledGame, log: @escaping @Sendable (String) -> Void,
                              progress: @escaping @Sendable (StoreTools.Progress) -> Void) async throws {
        guard let (l, mac) = link(g) else { throw NokError("\(g.name) wasn't installed from GOG or Epic.") }
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit \(g.name) first.") }
        let status: Int32
        switch l.store {
        case .epic:
            status = try await StoreTools.stream(.epic, ["install", l.id, "--update-only", "--skip-sdl", "-y"], log: log, progress: progress)
        case .gog:
            let start: URL? = mac ? g.native?.installFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
                                  : CompatibilityFixes.program(g)?.resolvingSymlinksInPath()
            // The download's --path is the folder that holds the .gog-support folder Nokcandu asked for.
            guard let s = start, let path = supportOwner(from: s) else {
                throw NokError("Couldn't find \(g.name)'s GOG download folder to update.")
            }
            status = try await StoreTools.stream(.gog, ["update", l.id, "--platform", mac ? "osx" : "windows", "--path", path.path,
                                                        "--support", path.appendingPathComponent(".gog-support").path] + StoreAccounts.dlcArgs(.gog, include: gogHasDLC(l.id)),
                                                 log: log, progress: progress)
        case .amazon:
            throw NokError("Amazon games update through Amazon.")
        }
        guard status == 0 else { throw NokError("The update stopped (exit \(status)). Press Update again to continue it.") }
        if var c = cached()?.value { c[g.id] = nil; ListCache.save(c, "store-updates") }
    }
}
