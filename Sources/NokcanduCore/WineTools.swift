import Foundation
import Darwin

/// Windows tools and folders for a game's private Windows environment (or the shared Steam's).
public enum WineTools {
    public enum Tool: String, CaseIterable, Identifiable {
        case winecfg, regedit, taskmgr, console, explorer, control
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .winecfg: "Wine Settings"
            case .regedit: "Registry Editor"
            case .taskmgr: "Task Manager"
            case .console: "Command Prompt"
            case .explorer: "Windows File Browser"
            case .control: "Control Panel"
            }
        }
        public var symbol: String {
            switch self {
            case .winecfg: "gearshape.2"; case .regedit: "list.bullet.indent"; case .taskmgr: "chart.bar"
            case .console: "terminal"; case .explorer: "folder"; case .control: "slider.horizontal.3"
            }
        }
        var args: [String] {
            switch self {
            case .winecfg: ["winecfg"]
            case .regedit: ["regedit"]
            case .taskmgr: ["taskmgr"]
            case .console: ["wineconsole", "cmd"]
            case .explorer: ["explorer", "C:\\"]
            case .control: ["control"]
            }
        }
    }

    /// The app whose Wine engine and prefix a game uses (Steam games use the shared Steam app).
    public static func hostContents(for g: InstalledGame) -> URL? {
        if g.usesSharedSteam { return SharedSteam.isSetUp ? SharedSteam.contents : nil }
        if let hostApp = g.battleNet?.hostApp ?? g.hosted?.hostApp {
            let h = URL(fileURLWithPath: hostApp).appendingPathComponent("Contents")
            return FileManager.default.isExecutableFile(atPath: h.appendingPathComponent("SharedSupport/wine/bin/wine").path) ? h : nil
        }
        let c = g.contents
        guard FileManager.default.isExecutableFile(atPath: c.appendingPathComponent("SharedSupport/wine/bin/wine").path) else { return nil }
        return c
    }

    public static func environment(contents c: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let support = c.appendingPathComponent("SharedSupport")
        env["WINEPREFIX"] = support.appendingPathComponent("prefix").path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = WineEnvironment.libraryPath(contents: c)
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1"
        env["PATH"] = support.appendingPathComponent("wine/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// Starts a Wine tool or Windows program detached; it keeps running after Nokcandu returns.
    public static func run(_ args: [String], for g: InstalledGame, cwd: URL? = nil) throws {
        guard let c = hostContents(for: g) else { throw NokError("This game has no Windows environment to open.") }
        let p = Process()
        p.executableURL = c.appendingPathComponent("SharedSupport/wine/bin/wine")
        p.arguments = args
        p.environment = environment(contents: c)
        p.currentDirectoryURL = cwd ?? c.appendingPathComponent("SharedSupport/prefix/drive_c")
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    public static func open(_ tool: Tool, for g: InstalledGame) throws { try run(tool.args, for: g) }

    /// Force-quits every Windows program in this game's environment (stuck crash reporters, hung
    /// launchers, leftover debuggers). Unsaved progress in a running game is lost.
    public static func stopAll(for g: InstalledGame) async throws {
        guard let c = hostContents(for: g) else { throw NokError("This game has no Windows environment.") }
        let ws = c.appendingPathComponent("SharedSupport/wine/bin/wineserver").path
        let stopped = try await Shell.runAsync(ws, ["-k"], env: environment(contents: c), timeout: 60)
        // A broken Wine client can survive its server (EA activation/relaunch can leave one
        // behind). Verify the actual native executable, never a game name shared by other prefixes.
        let waited = try await Shell.runAsync(ws, ["-w"], env: environment(contents: c), timeout: 60)
        var remaining = ownedProcesses(contents: c)
        if !remaining.isEmpty {
            for pid in remaining where owns(pid: pid, contents: c) { kill(pid, SIGTERM) }
            for _ in 0..<30 {
                remaining = ownedProcesses(contents: c)
                if remaining.isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            for pid in remaining where owns(pid: pid, contents: c) { kill(pid, SIGKILL) }
            for _ in 0..<20 {
                if ownedProcesses(contents: c).isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard ownedProcesses(contents: c).isEmpty else { throw NokError("Some Windows programs did not close. Your setting has not been changed.") }
        // -k returns 1 when a server has already exited; that is safe only after the native
        // process check above and a successful server wait.
        guard waited.ok, stopped.ok || stopped.status == 1 else { throw NokError("Windows programs are still closing. Wait before restarting the launcher.") }
        // The shell supervisor may briefly outlive wineserver; wait before removing its lock.
        let pidFile = c.appendingPathComponent("SharedSupport/Logs/game.lock/pid")
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
            for _ in 0..<100 {
                if kill(pid, 0) != 0 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if kill(pid, 0) == 0 { throw NokError("The launcher is still closing. Wait a moment and try again.") }
        }
        for lock in ["game.lock", "steam.lock"] {
            try? FileManager.default.removeItem(at: c.appendingPathComponent("SharedSupport/Logs/\(lock)"))
        }
    }

    static func owns(executable path: String, contents: URL) -> Bool {
        let support = contents.appendingPathComponent("SharedSupport").standardizedFileURL.path
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        if ["wine", "wine64", "wine-preloader", "wine64-preloader", "wineserver"].contains((file as NSString).lastPathComponent),
           (file as NSString).deletingLastPathComponent == support + "/wine/bin" { return true }
        // Wine's loader for the environment's programs, named after the app it belongs to
        // (GameApp/StarCraft.app/Contents/MacOS/StarCraft) or plain "wine".
        guard file.hasPrefix(support + "/GameApp/") else { return false }
        let rest = file.dropFirst(support.count + "/GameApp/".count).components(separatedBy: "/")
        return rest.count == 4 && rest[0].hasSuffix(".app") && rest[1] == "Contents" && rest[2] == "MacOS"
    }
    static func owns(pid: Int32, contents: URL) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return false }
        return owns(executable: String(cString: bytes), contents: contents)
    }
    static func ownedProcesses(contents: URL) -> [Int32] {
        guard let rows = try? Shell.run("/bin/ps", ["-axo", "pid="], timeout: 10), rows.ok else { return [] }
        return rows.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }.filter { owns(pid: $0, contents: contents) }
    }

    /// Read-only probe, including background services with no visible launcher window.
    /// `wineserver -w` returns immediately when no server exists; a live environment keeps it waiting.
    public static func environmentIsRunning(for game: InstalledGame) async -> Bool {
        guard let contents = hostContents(for: game) else { return false }
        if !ownedProcesses(contents: contents).isEmpty { return true }
        do {
            let result = try await Shell.runAsync(contents.appendingPathComponent("SharedSupport/wine/bin/wineserver").path,
                ["-w"], env: environment(contents: contents), timeout: 0.3)
            return !result.ok
        } catch { return true }
    }
    /// Apply while the environment is closed, then relaunch the selected game through its host. Callers obtain
    /// confirmation first; mouse settings that apply live never use this path.
    public static func applySettings(for game: InstalledGame, restart: Bool,
                                     edit: (InstalledGame) async throws -> Void,
                                     reopen: (InstalledGame) throws -> Void = { try GameLauncher.launch($0) }) async throws {
        let contents = hostContents(for: game)
        let hostURL = contents?.deletingLastPathComponent()
        if restart { try await stopAll(for: game) }
        do { try await edit(GameLibrary.inspect(game.appURL) ?? game) }
        catch {
            if restart, let hostURL, let host = GameLibrary.inspect(hostURL) { try? reopen(host) }
            throw error
        }
        if restart, let hostURL, let host = GameLibrary.inspect(hostURL) {
            let selected=GameLibrary.inspect(game.appURL) ?? game
            CustomGames.upgradeLaunchers([host, selected])
            try reopen(GameLibrary.inspect(selected.appURL) ?? selected)
        }
    }

    /// Close this shared environment, migrate only fingerprinted generated launchers while closed,
    /// then reopen its host. Reopening immediately can otherwise skip a pending launcher upgrade.
    public static func restartHost(for game: InstalledGame) async throws {
        guard let contents = hostContents(for: game) else { throw NokError("This game has no Windows environment.") }
        try await stopAll(for: game)
        guard let host = GameLibrary.inspect(contents.deletingLastPathComponent()) else { throw NokError("The launcher app is missing.") }
        CustomGames.upgradeLaunchers([host])
        try GameLauncher.launch(GameLibrary.inspect(host.appURL) ?? host)
    }

    /// Runs any Windows program (an installer, a patch, a tool) once inside this game's environment.
    public static func runProgram(_ exe: URL, for g: InstalledGame) throws {
        try run(["start", "/unix", exe.path], for: g, cwd: exe.deletingLastPathComponent())
    }

    // MARK: Folders

    public struct Place: Identifiable, Hashable {
        public var id: String { title }
        public var title: String
        public var url: URL
        public var symbol: String
    }

    /// Useful folders for this game, in the order people usually need them.
    public static func places(for g: InstalledGame) -> [Place] {
        let fm = FileManager.default
        var out: [Place] = []
        func add(_ t: String, _ u: URL?, _ s: String) {
            if let u, fm.fileExists(atPath: u.path) { out.append(Place(title: t, url: u, symbol: s)) }
        }
        if let l = g.battleNet, let host = GameLibrary.inspect(URL(fileURLWithPath: l.hostApp)) {
            let loc = BattleNet.installedGames(host: host).first { $0.uid == l.uid }?.installLocation
            add("Game folder", loc.flatMap { BattleNet.unixPath($0, prefix: host.prefix) }, "folder")
            add("Battle.net's C: drive", host.prefix.appendingPathComponent("drive_c"), "internaldrive")
            return out
        }
        if let link = g.hosted, let host = GameLibrary.inspect(URL(fileURLWithPath: link.hostApp)) {
            add("Game folder", PCLaunchers.installFolder(link, host: host), "folder")
            add("\(link.launcher.title)'s C: drive", host.prefix.appendingPathComponent("drive_c"), "internaldrive")
            return out
        }
        if g.usesSharedSteam, let id = g.custom?.steamAppID {
            add("Game folder", SharedSteam.installedGames().first { $0.appID == id }?.folder, "folder")
            add("Steam's C: drive", SharedSteam.contents.appendingPathComponent("SharedSupport/prefix/drive_c"), "internaldrive")
        } else {
            if let exe = g.custom?.exeRelativeToContents {
                add("Game folder", g.contents.appendingPathComponent(exe).deletingLastPathComponent(), "folder")
            } else if let d = g.gameDirectory {
                add("Game folder", d, "folder")
            }
            add("C: drive", g.prefix.appendingPathComponent("drive_c"), "internaldrive")
            let users = g.prefix.appendingPathComponent("drive_c/users")
            let user = (try? fm.contentsOfDirectory(atPath: users.path))?.first { $0 != "Public" && !$0.hasPrefix(".") }
            add("Saved games & settings (AppData)", user.map { users.appendingPathComponent("\($0)/AppData") }, "person.crop.circle")
        }
        if let spec = GameDataSpec.forGame(g) { add("Settings & replays (Documents)", spec.folder, "doc.on.doc") }
        add("Logs", g.usesSharedSteam ? SharedSteam.contents.appendingPathComponent("SharedSupport/Logs") : g.logs, "doc.text")
        add("Inside the app (Contents)", g.contents, "shippingbox")
        return out
    }
}

extension CustomGames {
    /// Copies a new disc image into the game app and reads its volume label. Returns the updated settings
    /// (not yet saved). The old image is kept until the new settings are saved and then moved to the Trash.
    public static func prepareDisc(_ iso: URL, for g: InstalledGame, current: CustomGameConfig) throws -> CustomGameConfig {
        let fm = FileManager.default
        let name = safeFolderName(iso.deletingPathExtension().lastPathComponent) + ".iso"
        let dest = g.support.appendingPathComponent(name)
        if !fm.fileExists(atPath: dest.path) { try fm.cloneItem(at: iso, to: dest) }
        let label = try Discs.volumeLabel(dest)
        var c = current
        c.disc = DiscSpec(imageName: name, volumeLabel: label, internalMountDir: "SharedSupport/MountedDisc")
        return c
    }

    /// Saves edited settings, including the app's display name.
    public static func saveAll(_ c: CustomGameConfig, to g: InstalledGame, force: Bool = false) throws {
        let oldDisc = g.custom?.disc?.imageName
        try save(c, to: g, force: force)
        let plistURL = g.contents.appendingPathComponent("Info.plist")
        if var plist = NSDictionary(contentsOf: plistURL) as? [String: Any], plist["CFBundleName"] as? String != c.name {
            plist["CFBundleName"] = c.name
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        }
        if let old = oldDisc, old != c.disc?.imageName {
            // Unmount the old disc so the next launch mounts the new one.
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", g.support.appendingPathComponent("MountedDisc").path, "-quiet"])
            try? FileManager.default.trashItem(at: g.support.appendingPathComponent(old), resultingItemURL: nil)
        }
    }
}
