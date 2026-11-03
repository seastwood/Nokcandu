import Foundation

/// Local installation discovery, independent of the store window and account web APIs.
public enum StoreGameDiscovery {
    // Manual Add and automatic discovery share one creation transaction.
    static let creationLock = NSRecursiveLock()
    static let nonGameSteamIDs: Set<Int> = [7, 228980, 1070560, 1391110, 1628350, 1493710]
    static var stateURL: URL { NokPaths.support.appendingPathComponent("store-game-discovery.json") }
    struct State: Codable, Equatable {
        var apps: [String: String] = [:]
        var excluded: Set<String> = []
    }
    struct Candidate {
        var key: String
        var name: String
        var create: () throws -> URL
    }
    public struct Result {
        public var added: [URL] = []
        public var errors: [String] = []
    }
    static func hostKey(_ host: InstalledGame) -> String { host.custom?.id ?? host.appURL.resolvingSymlinksInPath().path }
    static func key(for game: InstalledGame, library: [InstalledGame]) -> String? {
        if game.usesSharedSteam, let id = game.custom?.steamAppID { return "steam:\(id)" }
        func host(_ path: String) -> String {
            library.first { $0.appURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path }.map(hostKey)
                ?? GameLibrary.inspect(URL(fileURLWithPath: path)).map(hostKey) ?? path
        }
        if let link = game.battleNet { return "battlenet:\(host(link.hostApp)):\(link.uid.lowercased())" }
        if let link = game.hosted { return "\(link.launcher.rawValue):\(host(link.hostApp)):\(link.id.lowercased())" }
        return nil
    }
    static func load(_ url: URL) throws -> State {
        guard !FileManager.default.fileExists(atPath: url.path) else { return try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) }
        return State()
    }
    static func save(_ state: State, to url: URL) throws {
        try NokPaths.ensure(url.deletingLastPathComponent())
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    static func steamEligible(_ game: SharedSteam.LibraryGame) -> Bool {
        game.installed && game.download == nil && !nonGameSteamIDs.contains(game.appID)
            && LauncherInstallation.presence(at: game.folder) == .present
    }
    static func candidates(in library: [InstalledGame]) -> [Candidate] {
        var result: [Candidate] = []
        if library.contains(where: \.isSteamHost), SharedSteam.isSetUp {
            result += SharedSteam.installedGames().filter(steamEligible).map { game in
                Candidate(key: "steam:\(game.appID)", name: game.name, create: { try SharedSteam.addGame(game) })
            }
        }
        for host in library {
            if BattleNet.isHost(host) {
                result += BattleNet.installedGames(host: host).filter {
                    LauncherInstallation.presence(at: LauncherInstallation.windowsFolder($0.installLocation, prefix: host.prefix)) == .present
                }.map { game in
                    Candidate(key: "battlenet:\(hostKey(host)):\(game.uid.lowercased())", name: game.name,
                              create: { try BattleNet.addGame(game, host: host) })
                }
            }
            if let kind = PCLaunchers.kind(of: host) {
                result += PCLaunchers.installedGames(kind, host: host).filter { game in
                    guard LauncherInstallation.presence(at: LauncherInstallation.windowsFolder(game.installLocation, prefix: host.prefix)) == .present else { return false }
                    // EA launches the registered program directly; an icon-only or unfinished record isn't playable.
                    return kind != .ea || game.exe.flatMap { BattleNet.unixPath($0, prefix: host.prefix) }.map { FileManager.default.fileExists(atPath: $0.path) } == true
                }.map { game in
                    Candidate(key: "\(kind.rawValue):\(hostKey(host)):\(game.id.lowercased())", name: game.name,
                              create: { try PCLaunchers.addGame(game, kind: kind, host: host) })
                }
            }
        }
        return result
    }
    /// A corrupt record fails closed rather than recreating games deliberately removed by the user.
    static func synchronize(candidates: [Candidate], stateURL: URL, allowNew: Bool = true, scan: () -> [InstalledGame]) throws -> Result {
        creationLock.lock(); defer { creationLock.unlock() }
        var state = try load(stateURL), result = Result()
        let before = state
        var library = scan()
        for game in library {
            if let key = key(for: game, library: library) {
                state.apps[key] = game.appURL.path
                state.excluded.remove(key) // explicitly added/restored through another path
            }
        }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.key).inserted {
            if library.contains(where: { key(for: $0, library: library) == candidate.key }) { continue }
            if state.excluded.contains(candidate.key) { continue }
            if let path = state.apps[candidate.key] {
                let app = URL(fileURLWithPath: path)
                // Keep an app on a disconnected drive, or a manually changed app we cannot inspect.
                if FileManager.default.fileExists(atPath: path) || LauncherInstallation.presence(at: app.deletingLastPathComponent()) != .present { continue }
                state.excluded.insert(candidate.key) // removed in Finder; don't immediately recreate it
                continue
            }
            guard allowNew else { continue }
            do {
                let url = try candidate.create()
                state.apps[candidate.key] = url.path
                result.added.append(url)
                library = scan()
            } catch { result.errors.append("\(candidate.name): \(error.localizedDescription)") }
        }
        if state != before { try save(state, to: stateURL) }
        return result
    }
    /// Record removal before Trash; restore the old policy if removal fails.
    static func preservingRemovalIntent<T>(for game: InstalledGame, library: [InstalledGame], at url: URL,
                                           remove: () throws -> T) throws -> T {
        creationLock.lock(); defer { creationLock.unlock() }
        guard let key = key(for: game, library: library) else { return try remove() }
        let old = try load(url)
        var state = old; state.excluded.insert(key); state.apps[key] = game.appURL.path
        try save(state, to: url)
        do {
            let value = try remove()
            if FileManager.default.fileExists(atPath: game.appURL.path) { try save(old, to: url) }
            return value
        } catch { try? save(old, to: url); throw error }
    }
    public static func refresh() -> Result {
        do {
            let candidates = candidates(in: GameLibrary.scan())
            let allowNew = !GameFolders.all.contains { LauncherInstallation.presence(at: $0) == .offline }
            return try synchronize(candidates: candidates, stateURL: stateURL, allowNew: allowNew, scan: { GameLibrary.scan() })
        } catch { return Result(errors: ["Automatic game discovery: \(error.localizedDescription)"]) }
    }
}
