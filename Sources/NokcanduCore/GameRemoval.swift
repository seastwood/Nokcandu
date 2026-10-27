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
    public static func items(for g: InstalledGame) -> [Item] {
        let fm = FileManager.default
        var out = [Item(url: g.appURL, what: "The game app (game files, Windows environment, saves inside it)", bytes: size(g.appURL))]
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
        return nil
    }

    /// Moves the game and its items to the Trash. Returns what couldn't be moved.
    @discardableResult
    public static func remove(_ g: InstalledGame, library: [InstalledGame]) throws -> [String] {
        if let b = blocker(g, library: library) { throw NokError(b) }
        var failed: [String] = []
        // Disc images stay mounted inside the app after playing; eject them first.
        if let mounts = try? FileManager.default.contentsOfDirectory(at: g.support, includingPropertiesForKeys: nil) {
            for m in mounts where m.lastPathComponent.hasPrefix("MountedDisc") {
                _ = try? Shell.run("/usr/bin/hdiutil", ["detach", m.path, "-force"], timeout: 60)
            }
        }
        for i in items(for: g) {
            do { try FileManager.default.trashItem(at: i.url, resultingItemURL: nil) }
            catch { failed.append("\(i.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return failed
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
