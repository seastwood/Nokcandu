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
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for app in items where app.pathExtension == "app" {
                if let g = inspect(app) { found.append(g) }
            }
        }
        if folders == GameFolders.all {
            let known = Set(found.map { $0.appURL.standardizedFileURL.path })
            found += NativeGames.all().compactMap(NativeGames.installedGame).filter { !known.contains($0.appURL.standardizedFileURL.path) }
        }
        return found.sorted { ($0.recipe == nil ? 1 : 0, $0.name) < ($1.recipe == nil ? 1 : 0, $1.name) }
    }

    public static func inspect(_ app: URL) -> InstalledGame? {
        let contents = app.appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] else { return nil }
        // Wine-wrapper apps carry SharedSupport/prefix; Steam-library game apps carry only their Nokcandu settings.
        let hasPrefix = FileManager.default.fileExists(atPath: contents.appendingPathComponent("SharedSupport/prefix").path)
        let bnet = BattleNetLink.load(contents: contents)
        let hosted = HostedGameLink.load(contents: contents)
        guard hasPrefix || bnet != nil || hosted != nil || FileManager.default.fileExists(atPath: CustomGameConfig.url(in: contents).path) else { return nil }
        let exe = info["CFBundleExecutable"] as? String
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
        _ = try? await Shell.runAsync(wine, ["wineboot", "--end-session", "--force"], env: WineTools.environment(contents: c), timeout: 15)
        for _ in 0..<20 {
            if WineTools.ownedProcesses(contents: c).isEmpty { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try await WineTools.stopAll(for: g)
    }

    /// Reads the launcher's single-instance lock (Logs/game.lock/pid).
    public static func runState(of game: InstalledGame) -> RunState {
        if game.isSteamHost {
            let f = game.logs.appendingPathComponent("steam.lock/pid")
            if let s = try? String(contentsOf: f, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
                return .launcherRunning(pid: pid)
            }
            return .notRunning
        }
        let pidFile = game.logs.appendingPathComponent("game.lock/pid")
        if let s = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, kill(pid, 0) == 0 {
            return .launcherRunning(pid: pid)
        }
        // Games started by their launcher (Battle.net, EA app): the game's app hands the game over and exits, so
        // look for the game's own program in the launcher's environment. Also right after Nokcandu restarts.
        if let pid = launchedGameProcess(game) { return .launcherRunning(pid: pid) }
        return .notRunning
    }

    /// The running Windows program of a game a launcher started, if any.
    static func launchedGameProcess(_ game: InstalledGame) -> Int32? {
        var match: ((String) -> Bool)?
        if let b = game.battleNet {
            let uid = "-uid \(b.uid.lowercased())"
            match = { c in c.hasSuffix(uid) || c.contains(uid + " ") }
        } else if let exe = game.hosted?.exe, !exe.isEmpty {
            let name = exe.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map { String($0).lowercased() } ?? ""
            if !name.isEmpty { match = { c in c.contains("\\" + name) } }
        }
        guard let match, let host = WineTools.hostContents(for: game) else { return nil }
        for (pid, command) in processSnapshot() where match(command.lowercased()) {
            if WineTools.owns(pid: pid, contents: host) { return pid }
        }
        return nil
    }

    private static let snapshotLock = NSLock()
    private nonisolated(unsafe) static var snapshot: (time: Date, rows: [(Int32, String)]) = (.distantPast, [])

    /// All processes with their command lines, refreshed at most once a second (the library checks often).
    static func processSnapshot() -> [(Int32, String)] {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        if Date().timeIntervalSince(snapshot.time) < 1 { return snapshot.rows }
        var rows: [(Int32, String)] = []
        if let r = try? Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="], timeout: 5), r.ok {
            for line in r.stdout.split(separator: "\n") {
                let t = line.drop(while: { $0 == " " })
                guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
                rows.append((pid, String(t[t.index(after: sp)...])))
            }
        }
        snapshot = (Date(), rows)
        return rows
    }

    /// Opens the game's own app through LaunchServices so it behaves exactly like a Finder double-click.
    /// `arguments` are passed through to the launcher (e.g. ["--windowed"]).
    public static func launch(_ game: InstalledGame, arguments: [String] = []) throws {
        if game.hosted != nil { PCLaunchers.refreshLaunchers([game]) }
        HelperPatch.refresh([game])
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
