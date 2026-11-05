import Foundation

/// A game app found on disk, matched to a shipped recipe (or not).
public struct InstalledGame: Identifiable, Hashable {
    public var id: String { appURL.path }
    public var appURL: URL
    public var name: String
    public var recipe: GameRecipe?
    /// Settings of a general game added through Nokcandu (nil for shipped recipes and unmanaged apps).
    public var custom: CustomGameConfig?
    public var bundleIdentifier: String?
    public var executableName: String?
    public var iconURL: URL?
    public var wineVersion: String?
    public var renderer: String?
    /// A Blizzard game started through the shared Battle.net app.
    public var battleNet: BattleNetLink? = nil
    /// A game started through the EA app or Ubisoft Connect app.
    public var hosted: HostedGameLink? = nil
    /// A Mac game (no Wine): Nokcandu just opens it.
    public var native: NativeGame? = nil

    public var contents: URL { appURL.appendingPathComponent("Contents", isDirectory: true) }
    public var support: URL { contents.appendingPathComponent("SharedSupport", isDirectory: true) }
    public var prefix: URL { support.appendingPathComponent("prefix", isDirectory: true) }
    public var logs: URL { support.appendingPathComponent("Logs", isDirectory: true) }
    public var launcherURL: URL? { executableName.map { contents.appendingPathComponent("MacOS/\($0)") } }
    public var nokcanduState: URL { support.appendingPathComponent("nokcandu", isDirectory: true) }
    public var gameDirectory: URL? { recipe.map { contents.appendingPathComponent($0.gameDirectory) } }

    /// Short, jargon-free status for the library row.
    public var isManaged: Bool { recipe != nil }
    public var isSteamHost: Bool { recipe?.id == SharedSteam.recipeID }
    /// A Steam game that starts through the shared Steam app (no Wine inside this app).
    public var usesSharedSteam: Bool { custom?.source == .steamLibrary }
    public var journalScope: String { "game-" + (bundleIdentifier ?? name).replacingOccurrences(of: "/", with: "_") }
}

public enum GameLibrary {
    /// Scans the Sikarugir apps folder (and any extra folders) for game apps.
    public static func scan(folders: [URL] = GameFolders.all) -> [InstalledGame] {
        let fm = FileManager.default
        var found: [InstalledGame] = []
        // An app moved to another drive keeps a link in the standard folder (so it stays in Applications), and
        // the folder it moved to may be a library folder too: list each real app once, by its real place.
        var seen = Set<String>()
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for app in items where app.pathExtension == "app" {
                guard let g = inspect(app), seen.insert(g.appURL.resolvingSymlinksInPath().path).inserted else { continue }
                found.append(g)
            }
        }
        if folders == GameFolders.all {
            let known = Set(found.map { $0.appURL.standardizedFileURL.path })
            found += NativeGames.all().compactMap(NativeGames.installedGame).filter { !known.contains($0.appURL.standardizedFileURL.path) }
        }
        return found.sorted { ($0.recipe == nil ? 1 : 0, $0.name) < ($1.recipe == nil ? 1 : 0, $1.name) }
    }

    public static func inspect(_ app: URL) -> InstalledGame? {
        // Through a link (an app moved to another drive), work with the real app: Nokcandu refuses to write
        // through links inside apps, and running programs report their real paths.
        let app = (try? FileManager.default.destinationOfSymbolicLink(atPath: app.path)) != nil ? app.resolvingSymlinksInPath() : app
        let contents = app.appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] else { return nil }
        // Wine-wrapper apps carry SharedSupport/prefix; Steam-library game apps carry only their Nokcandu settings.
        let hasPrefix = FileManager.default.fileExists(atPath: contents.appendingPathComponent("SharedSupport/prefix").path)
        let bnet = BattleNetLink.load(contents: contents)
        let hosted = HostedGameLink.load(contents: contents)
        guard hasPrefix || bnet != nil || hosted != nil || FileManager.default.fileExists(atPath: CustomGameConfig.url(in: contents).path) else { return nil }
        let exe = (info[LauncherEntry.key] as? String) ?? (info["CFBundleExecutable"] as? String)
        let name = (info["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent
        var recipe = RecipeCatalog.all.first { r in
            exe == r.launcherExecutable || app.lastPathComponent == r.appBundleName
        }
        let custom = CustomGameConfig.load(contents: contents)
        if let custom { recipe = custom.recipe }
        let isSteamHost = SharedSteam.isHost(contents: contents)
        if isSteamHost { recipe = SharedSteam.hostRecipe(wineVersion: nil) }
        var icon: URL?
        if var iconName = info["CFBundleIconFile"] as? String, !iconName.isEmpty {
            if !iconName.hasSuffix(".icns") { iconName += ".icns" }
            let u = contents.appendingPathComponent("Resources/\(iconName)")
            if FileManager.default.fileExists(atPath: u.path) { icon = u }
        }
        let version = (try? String(contentsOf: contents.appendingPathComponent("SharedSupport/wine/version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var renderer: String?
        if (info["D9VK"] as? Int) == 1 { renderer = "D9VK" }
        else if (info["DXVK"] as? Int) == 1 { renderer = "DXVK" }
        else if (info["D3DMETAL"] as? Int) == 1 { renderer = "D3DMetal" }
        if let r = recipe?.runtime.renderer { renderer = r }
        if let custom { renderer = custom.graphics.technical }
        return InstalledGame(appURL: app, name: name, recipe: recipe, custom: custom,
                             bundleIdentifier: info["CFBundleIdentifier"] as? String,
                             executableName: exe, iconURL: icon, wineVersion: version, renderer: renderer, battleNet: bnet, hosted: hosted)
    }
}

// MARK: - Launching and run state

public enum RunState: Equatable {
    case notRunning
    case unknown // No reliable process scan; never treat this as permission to mutate a game.
    /// The launcher process is alive. This is NOT proof the game is playable.
    case launcherRunning(pid: Int32)
}

public enum GameLauncher {
    /// What Quit closes for this app, in words for the confirmation.
    public static func quitScope(_ g: InstalledGame) -> String {
        if g.isSteamHost || BattleNet.isHost(g) || PCLaunchers.kind(of: g) != nil {
            return "Any games running in it will close too, and unsaved progress will be lost."
        }
        if g.usesSharedSteam || g.battleNet != nil || g.hosted != nil { return "Only the game closes; its launcher stays open. Unsaved progress will be lost." }
        return "Unsaved progress will be lost."
    }

    /// Quits a running game or launcher (not Mac games — the app asks those to quit itself).
    /// Launcher games: only the game's own programs. Everything else: Windows is asked to end the session
    /// (programs get a chance to close), and whatever is left after 10 s is stopped.
    public static func quit(_ g: InstalledGame) async throws {
        if g.isSteamHost { await SharedSteam.shutdown(); return }
        if g.usesSharedSteam || g.battleNet != nil || g.hosted != nil {
            let procs = StuckGames.running(g)
            guard !procs.isEmpty else { throw NokError("No running program of \(g.name) was found. If it's stuck, use Force Quit Windows Programs in its settings.") }
            for p in procs { kill(p.pid, SIGTERM) }
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !procs.contains(where: { kill($0.pid, 0) == 0 }) { return }
            }
            for p in procs where kill(p.pid, 0) == 0 { kill(p.pid, SIGKILL) }
            return
        }
        guard let c = WineTools.hostContents(for: g) else { throw NokError("This game has no Windows environment.") }
        let wine = c.appendingPathComponent("SharedSupport/wine/bin/wine").path
        // Don't wait for the end-session request itself: a game that isn't drawing (in the background, paused)
        // may never answer it. Programs get 10 s from the request to close; whatever is left is stopped.
        let env = WineTools.environment(contents: c)
        let request = Task.detached { _ = try? await Shell.runAsync(wine, ["wineboot", "--end-session", "--force"], env: env, timeout: 15) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for _ in 0..<19 {
            if WineTools.ownedProcesses(contents: c).isEmpty { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try await WineTools.stopAll(for: g)
        request.cancel()
    }

    /// Reads the launcher's single-instance lock (Logs/game.lock/pid).
    public static func runState(of game: InstalledGame) -> RunState {
        let snapshot = processStatus()
        return runState(of: game, processes: snapshot.rows, reliable: snapshot.reliable)
    }

    static func ownsLock(pid: Int32, game: InstalledGame, processes: [(Int32, String)]) -> Bool {
        guard pid > 1, let command = processes.first(where: { $0.0 == pid })?.1 else { return false }
        let macOS = game.contents.appendingPathComponent("MacOS").standardizedFileURL.path + "/"
        let canonical = game.contents.resolvingSymlinksInPath().appendingPathComponent("MacOS").path + "/"
        if command.contains(macOS) || command.contains(canonical) { return true }
        if game.isSteamHost {
            if command.contains(game.contents.appendingPathComponent("Resources/" + SharedSteam.helperName).path) { return true }
            let normalized = command.lowercased().replacingOccurrences(of: "/", with: "\\")
            if normalized.contains(#"\steam\steam.exe"#), let contents = WineTools.hostContents(for: game), WineTools.owns(pid: pid, contents: contents) { return true }
        }
        return launchedGameProcess(game, processes: processes) == pid
    }

    static func runState(of game: InstalledGame, processes: [(Int32, String)]?, reliable: Bool = true) -> RunState {
        if game.isSteamHost {
            let f = game.logs.appendingPathComponent("steam.lock/pid")
            if let s = try? String(contentsOf: f, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0, ownsLock(pid: pid, game: game, processes: processes ?? processSnapshot()) {
                return .launcherRunning(pid: pid)
            }
            return reliable ? .notRunning : .unknown
        }
        let pidFile = game.logs.appendingPathComponent("game.lock/pid")
        if let s = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, kill(pid, 0) == 0, ownsLock(pid: pid, game: game, processes: processes ?? processSnapshot()) {
            return .launcherRunning(pid: pid)
        }
        // Games started by their launcher (Battle.net, EA app): the game's app hands the game over and exits, so
        // look for the game's own program in the launcher's environment. Also right after Nokcandu restarts.
        if let pid = launchedGameProcess(game, processes: processes) { return .launcherRunning(pid: pid) }
        return reliable ? .notRunning : .unknown
    }

    /// A library-wide status pass uses one process scan, even when checking many
    /// games takes longer than the snapshot cache lifetime. Call off the UI thread.
    public static func runStates(of games: [InstalledGame]) -> [InstalledGame.ID: RunState] {
        let snapshot = processStatus()
        let processes = snapshot.rows
        let steam = games.contains(where: \.usesSharedSteam) ? SharedSteam.runningGames(processes: processes) : [:]
        var result: [InstalledGame.ID: RunState] = [:]
        for game in games {
            if game.usesSharedSteam {
                result[game.id] = steam[game.custom?.steamAppID ?? -1].flatMap { kill($0, 0) == 0 ? .launcherRunning(pid: $0) : nil } ?? (snapshot.reliable ? .notRunning : .unknown)
            } else { result[game.id] = runState(of: game, processes: processes, reliable: snapshot.reliable) }
        }
        return result
    }

    /// A running copy of the game that its own launcher script didn't record: a game its launcher (Battle.net,
    /// Steam, EA app) started, a Mac game, or any game after Nokcandu restarted. Found by the game's own program.
    static func launchedGameProcess(_ game: InstalledGame, processes: [(Int32, String)]? = nil) -> Int32? {
        let rows = processes ?? processSnapshot()
        if let n = game.native {
            // A Mac game: its app's own program.
            let prefix = URL(fileURLWithPath: n.appPath).standardizedFileURL.path + "/Contents/MacOS/"
            return rows.first { kill($0.0, 0) == 0 && $0.1.hasPrefix(prefix) }?.0
        }
        var match: ((String) -> Bool)?
        if BattleNet.isHost(game) || PCLaunchers.kind(of: game) != nil {
            // A launcher app (Battle.net, EA app, Ubisoft Connect): running while any of its programs is, besides
            // Wine's own background ones.
            match = { c in !c.isEmpty && !c.hasPrefix(#"c:\windows\"#) }
        } else if let b = game.battleNet {
            // Battle.net starts each game with its product code.
            let uid = "-uid \(b.uid.lowercased())"
            match = { c in c.hasSuffix(uid) || c.contains(uid + " ") }
        } else if let tail = windowsProgramTail(game.hosted?.exe ?? game.custom?.exe) {
            // The game's program by its folder and file name ("StarCraft\\x86_64\\starcraft.exe"), so two games
            // in one environment with the same file name (game.exe) aren't mixed up.
            match = { c in c.contains(tail) }
        }
        guard let match, let host = WineTools.hostContents(for: game) else { return nil }
        // Cheap tests first (the command text, then whether the program is this environment's Wine), and
        // the liveness probe only for the few that pass.
        let support = WineTools.supportPath(host)
        func ours(_ pid: Int32) -> Bool {
            guard pid > 1, pid != getpid(), let path = WineTools.executablePath(pid) else { return false }
            return WineTools.owns(executable: path, support: support) && kill(pid, 0) == 0
        }
        let lowered = loweredCommands(rows)
        for (pid, command) in lowered where match(command) && ours(pid) { return pid }
        // A private game may hand off from its configured launcher to another
        // executable. Keep tracking that game's own environment, never another
        // game's similarly named process or a shared store client.
        if hasPrivateGamePrefix(game) {
            for (pid, command) in lowered where privateGameCommand(command) && ours(pid) { return pid }
        }
        return nil
    }

    /// Lowercased process commands, computed once per process scan rather than once per game.
    private static let loweredCache = LockedCache<Int, [(Int32, String)]>(limit: 4)
    static func loweredCommands(_ rows: [(Int32, String)]) -> [(Int32, String)] {
        var hasher = Hasher()
        hasher.combine(rows.count)
        for row in rows { hasher.combine(row.0); hasher.combine(row.1) }
        let key = hasher.finalize()
        if let cached = loweredCache[key], cached.count == rows.count, cached.first?.0 == rows.first?.0 { return cached }
        let lowered = rows.map { ($0.0, $0.1.lowercased()) }
        loweredCache[key] = lowered
        return lowered
    }

    static func hasPrivateGamePrefix(_ game: InstalledGame) -> Bool {
        game.native == nil && !game.usesSharedSteam && game.battleNet == nil && game.hosted == nil &&
        !game.isSteamHost && PCLaunchers.kind(of: game) == nil
    }
    static func privateGameCommand(_ command: String) -> Bool {
        let text = command.lowercased().replacingOccurrences(of: "/", with: "\\")
        guard text.count > 3, text.dropFirst().hasPrefix(":"), text.first?.isLetter == true else { return false }
        return !text.hasPrefix(#"c:\windows\"#)
    }

    /// The last two parts of a Windows program path, lowercased with backslashes ("folder\\game.exe").
    static func windowsProgramTail(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").map(String.init)
        guard let file = parts.last, file.lowercased().hasSuffix(".exe") else { return nil }
        return (parts.count >= 2 ? parts[parts.count - 2] + "\\" + file : "\\" + file).lowercased()
    }

    private static let processCache = ProcessSnapshotCache()
    static func loadProcessRows() throws -> [(Int32, String)] {
        let result = try Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="], timeout: 15)
        guard result.ok else { throw NokError("Game status could not be checked.") }
        let rows: [(Int32, String)] = result.stdout.split(separator: "\n").compactMap { line in
            let text = line.drop(while: { $0 == " " })
            guard let space = text.firstIndex(of: " "), let pid = Int32(text[..<space]) else { return nil }
            return (pid, String(text[text.index(after: space)...]))
        }
        guard !rows.isEmpty else { throw NokError("The process scan was empty.") }
        return rows
    }
    static func processStatus() -> ProcessSnapshot { processCache.read { try loadProcessRows() } }
    static func freshProcessStatus() -> ProcessSnapshot {
        do { return ProcessSnapshot(rows: try loadProcessRows(), reliable: true) }
        catch { return ProcessSnapshot(rows: [], reliable: false) }
    }
    static func processSnapshot() -> [(Int32, String)] { processStatus().rows }

    /// Opens the game's own app through LaunchServices so it behaves exactly like a Finder double-click.
    /// `arguments` are passed through to the launcher (e.g. ["--windowed"]).
    public static func launch(_ game: InstalledGame, arguments: [String] = []) throws {
        try AppPrivacy.prepare(game)
        Discs.prepareMountPoints(support: game.support)
        if game.hosted != nil { PCLaunchers.refreshLaunchers([game]) }
        HelperPatch.refresh([game])
        try LauncherEntry.ensure(game)
        // Crash reports land in the environment, where Nokcandu can explain them (only while it's closed).
        if game.native == nil, let host = WineTools.hostContents(for: game) { CrashReports.ensureCapture(contents: host) }
        if game.isSteamHost || game.usesSharedSteam { SharedSteam.refreshHostScriptsIfNeeded() }
        var args = [game.appURL.path]
        if !arguments.isEmpty { args += ["--args"] + arguments }
        let r = try Shell.run("/usr/bin/open", args, timeout: 30)
        if r.ok { return }
        try selfHealLaunch(game, arguments: arguments, firstError: r.combined)
    }

    /// Play must work: when macOS refuses or times out opening the game's app (a stale copy of it that stopped
    /// answering, LaunchServices out of date: errors like -1712, -600, -10810), Nokcandu clears that up and tries
    /// again, and as a last resort starts the game's launcher itself.
    static func selfHealLaunch(_ game: InstalledGame, arguments: [String], firstError: String) throws {
        let app = game.appURL.standardizedFileURL.path
        // 1. A stale copy of this app (Nokcandu only offers Play when the game isn't running).
        _ = try? Shell.run("/usr/bin/pkill", ["-9", "-f", "^" + NSRegularExpression.escapedPattern(for: app + "/Contents/MacOS/")], timeout: 10)
        // 2. LaunchServices' record of the app.
        _ = try? Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                           ["-f", app], timeout: 30)
        Thread.sleep(forTimeInterval: 1)
        var args = [app]
        if !arguments.isEmpty { args += ["--args"] + arguments }
        if let r = try? Shell.run("/usr/bin/open", args, timeout: 30), r.ok { return }
        // 3. Start the launcher directly (detached, like an app would run it).
        guard let launcher = game.launcherURL, FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw NokError("macOS could not open \(game.name): \(firstError)")
        }
        let p = Process()
        p.executableURL = launcher
        p.arguments = arguments
        p.currentDirectoryURL = launcher.deletingLastPathComponent()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw NokError("macOS could not open \(game.name): \(firstError)") }
    }

    /// The launcher's own preflight (`--check`): validates game files, engine, and (Worms) the disc.
    public static func preflight(_ game: InstalledGame) async -> ShellResult {
        if game.hosted != nil { PCLaunchers.refreshLaunchers([game]) }
        HelperPatch.refresh([game])
        if game.isSteamHost || game.usesSharedSteam { SharedSteam.refreshHostScriptsIfNeeded() }
        guard let launcher = game.launcherURL else {
            return ShellResult(status: -1, stdout: "", stderr: "No launcher found in the app.")
        }
        do {
            return try await Shell.runAsync("/bin/bash", [launcher.path, "--check"], timeout: 120)
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
