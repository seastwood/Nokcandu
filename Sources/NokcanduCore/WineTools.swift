import Foundation

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
        env["DYLD_FALLBACK_LIBRARY_PATH"] = c.appendingPathComponent("Frameworks").path + ":/usr/lib"
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
        guard stopped.ok else { throw NokError("Couldn’t stop this Windows environment. Try again before restarting it.") }
        let waited = try await Shell.runAsync(ws, ["-w"], env: environment(contents: c), timeout: 60)
        guard waited.ok else { throw NokError("Windows programs are still closing. Wait before restarting the launcher.") }
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
