import Foundation

/// "Raw mouse capture": a small library (Resources/rawmouse) that Wine loads at start. While a game
/// is in mouse-look it feeds the game the mouse's own movement (hundreds of updates a second, no macOS
/// acceleration) instead of Wine's pointer-derived moves. The switch lives with the app that owns the
/// Wine engine — for Steam games that's the shared Steam, so it applies to all of them.
public enum RawMouse {
    public static let dylibName = "nokcandu-rawmouse.dylib"

    public struct Settings: Equatable {
        public var enabled: Bool
        public var scale: Double
        /// Spread each report over the time until the next (evens out 125 Hz mice; ≤1 report of delay).
        public var smooth: Bool = false
        /// Hand movement to the game once per frame instead of report by report (experimental).
        public var frameSync: Bool = false
        public init(enabled: Bool, scale: Double, smooth: Bool = false, frameSync: Bool = false) {
            self.enabled = enabled; self.scale = scale; self.smooth = smooth; self.frameSync = frameSync
        }
    }

    static func folder(_ host: URL) -> URL { host.appendingPathComponent("SharedSupport/nokcandu", isDirectory: true) }
    static func settingsContents(_ g: InstalledGame) -> URL? { g.hosted != nil ? g.contents : WineTools.hostContents(for: g) }
    static func flag(_ host: URL) -> URL { folder(host).appendingPathComponent("raw-mouse") }
    /// Present once the setting has been chosen (by you, or the default below), so the default is set only once.
    static func chosen(_ host: URL) -> URL { folder(host).appendingPathComponent("raw-mouse-chosen") }
    /// Raw capture is opt-in: game compatibility varies, and ordinary Wine input remains the default.
    public static let defaultSettings = Settings(enabled: false, scale: 1, smooth: false)

    public static func settings(for g: InstalledGame) -> Settings {
        guard let h = settingsContents(g) else { return Settings(enabled: false, scale: 1) }
        guard let text = try? String(contentsOf: flag(h), encoding: .utf8) else { return Settings(enabled: false, scale: 1) }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let s = Double(lines.first ?? "") ?? 1
        return Settings(enabled: true, scale: s, smooth: lines.dropFirst().contains("smooth"), frameSync: lines.dropFirst().contains("framesync"))
    }

    public static var bundledLibrary: URL? { NokPaths.bundledResource(dylibName) }

    /// Turns it on (copying the current library into the app) or off. A running game picks the change up
    /// within a second (libraries from Nokcandu 0.9.7 on); older ones on their next start.
    public static func apply(_ s: Settings, for g: InstalledGame) throws {
        guard let h = WineTools.hostContents(for: g) else { throw NokError("This game has no Windows environment.") }
        let state = g.hosted != nil ? g.contents : h
        let fm = FileManager.default
        try fm.createDirectory(at: folder(state), withIntermediateDirectories: true)
        if s.enabled {
            guard let lib = bundledLibrary else { throw NokError("Nokcandu's raw-mouse library is missing; rebuild Nokcandu.") }
            let dst = folder(h).appendingPathComponent(dylibName)
            if (try? Hashing.sha256(file: dst)) != (try? Hashing.sha256(file: lib)) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: lib, to: dst)
            }
            let scale = min(max(s.scale, 0.1), 10)
            try Data((String(format: "%.2f\n", scale) + (s.smooth ? "smooth\n" : "") + (s.frameSync ? "framesync\n" : "")).utf8).write(to: flag(state), options: .atomic)
        } else {
            try? fm.removeItem(at: flag(state))
        }
        try? Data().write(to: chosen(state))
    }

    /// Puts Nokcandu's helper library (real app names in the Dock + raw mouse) into every app with a Wine
    /// engine, keeps it current after Nokcandu updates, and writes each app's program → name list.
    /// Called on refresh, off the main thread (it looks through game folders).
    public static func refreshLibraries(_ games: [InstalledGame]) {
        let fm = FileManager.default
        let lib = bundledLibrary
        let want = lib.flatMap { try? Hashing.sha256(file: $0) }
        var input: [URL: [String: String]] = [:]
        var basenames: [URL: [String: [String]]] = [:]
        var names: [URL: [String: String]] = [:]       // host Contents → exe → name
        var appNames: [URL: String] = [:]               // host Contents → name of its main GameApp wrapper
        var wrappers: [URL: [GameApp.Wrapper]] = [:]    // host Contents → wrappers (one per program name)
        for g in games {
            guard let h = WineTools.hostContents(for: g) else { continue }
            var m = names[h] ?? [:]
            if g.isSteamHost { appNames[h] = "Steam" }
            else if BattleNet.isHost(g) { appNames[h] = "Battle.net" }
            else if appNames[h] == nil, !g.usesSharedSteam, g.battleNet == nil, g.hosted == nil { appNames[h] = LibraryOrganizer.canonicalName(g) }
            if g.isSteamHost || BattleNet.isHost(g) || (!g.usesSharedSteam && g.battleNet == nil && g.hosted == nil) {
                wrappers[h, default: []].insert(GameApp.Wrapper(name: appNames[h] ?? g.name, iconFrom: g.contents,
                                                               isGame: !g.isSteamHost && !BattleNet.isHost(g) && PCLaunchers.kind(of: g) == nil), at: 0)
            } else {
                wrappers[h, default: []].append(GameApp.Wrapper(name: g.battleNet?.name ?? g.name, iconFrom: g.contents))
            }
            if g.isSteamHost {
                for e in ["steam.exe", "steamwebhelper.exe", "steamerrorreporter.exe", "steamservice.exe"] { m[e] = "Steam" }
            } else if BattleNet.isHost(g) {
                for e in ["battle.net.exe", "battle.net launcher.exe", "agent.exe", "blizzard battle.net app.exe"] { m[e] = "Battle.net" }
            } else if g.usesSharedSteam, let id = g.custom?.steamAppID,
                      let folder = SharedSteam.installedGames().first(where: { $0.appID == id })?.folder {
                for e in exeNames(in: folder) where m[e] == nil { m[e] = g.name }
            } else if let link = g.hosted, let host = GameLibrary.inspect(URL(fileURLWithPath: link.hostApp)),
                      let exe = link.exe, let file = BattleNet.unixPath(exe, prefix: host.prefix) {
                m[file.lastPathComponent.lowercased()] = g.name
                let flag = flag(g.contents).path
                if flag.rangeOfCharacter(from: CharacterSet(charactersIn: "\t\r\n")) == nil {
                    input[h, default: [:]][exe.lowercased()] = flag
                    input[h, default: [:]][file.path.lowercased()] = flag
                    input[h, default: [:]][file.resolvingSymlinksInPath().path.lowercased()] = flag
                    basenames[h, default: [:]][file.lastPathComponent.lowercased(), default: []].append(flag)
                }
            } else if let l = g.battleNet, let host = GameLibrary.inspect(URL(fileURLWithPath: l.hostApp)),
                      let loc = BattleNet.installedGames(host: host).first(where: { $0.uid == l.uid })?.installLocation,
                      let folder = BattleNet.unixPath(loc, prefix: host.prefix) {
                for e in exeNames(in: folder) where m[e] == nil { m[e] = l.name }
            }
            names[h] = m
        }
        for (h, m) in names {
            var routes = input[h] ?? [:]
            for (name, flags) in basenames[h] ?? [:] where Set(flags).count == 1 { routes[name] = flags[0] }
            let routeText = routes.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n") + "\n"
            let routeFile = folder(h).appendingPathComponent("program-input.tsv")
            try? NokPaths.ensure(folder(h))
            if (try? String(contentsOf: routeFile, encoding: .utf8)) != routeText { try? Data(routeText.utf8).write(to: routeFile, options: .atomic) }
            try? fm.createDirectory(at: folder(h), withIntermediateDirectories: true)
            if let lib, let want {
                let dst = folder(h).appendingPathComponent(dylibName)
                if (try? Hashing.sha256(file: dst)) != want {
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: lib, to: dst)
                }
            }
            if let tool = NokPaths.bundledResource("screen-size"), let want = try? Hashing.sha256(file: tool) {
                let dst = folder(h).appendingPathComponent("screen-size")
                if (try? Hashing.sha256(file: dst)) != want { try? fm.removeItem(at: dst); try? fm.copyItem(at: tool, to: dst) }
            }
            let text = m.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n") + "\n"
            if !fm.fileExists(atPath: chosen(h).path) {
                if !fm.fileExists(atPath: flag(h).path) {
                    let d = defaultSettings
                    if d.enabled {
                        try? Data((String(format: "%.2f\n", d.scale) + (d.smooth ? "smooth\n" : "")).utf8).write(to: flag(h), options: .atomic)
                    }
                }
                try? Data().write(to: chosen(h))
            }
            if let n = appNames[h] { GameApp.ensure(host: h, wrappers: wrappers[h] ?? [], programs: m, fallback: n) }
            let file = folder(h).appendingPathComponent("app-names.tsv")
            if (try? String(contentsOf: file, encoding: .utf8)) != text { try? Data(text.utf8).write(to: file, options: .atomic) }
        }
    }

    /// Lower-cased .exe names in a game's folder (a few levels deep; skips huge data folders quickly).
    static func exeNames(in folder: URL) -> [String] {
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let u as URL in en {
            if en.level > 5 { en.skipDescendants(); continue }
            let n = u.lastPathComponent.lowercased()
            if n.hasSuffix(".exe") { out.append(n) }
            if out.count > 200 { break }
        }
        return out
    }

    /// What the library said in the last run (it logs "nokcandu-rawmouse: …" lines to the game's log).
    public static func lastStatus(for g: InstalledGame) -> String? {
        guard let h = WineTools.hostContents(for: g) else { return nil }
        let log = (g.hosted != nil ? g.contents : h).appendingPathComponent(g.usesSharedSteam || g.isSteamHost ? "SharedSupport/Logs/steam.log" : "SharedSupport/Logs/launch.log")
        guard let tail = tailOfFile(log, maxLines: 4000) else { return nil }
        let notes = tail.components(separatedBy: .newlines).filter { $0.hasPrefix("nokcandu-rawmouse:") }
            .map { String($0.dropFirst("nokcandu-rawmouse: ".count)) }
        return summary(notes)
    }

    /// One plain sentence about the most recent run (notes since the last "installed" line).
    static func summary(_ all: [String]) -> String? {
        guard !all.isEmpty else { return nil }
        let run = all.lastIndex { $0.hasPrefix("installed") }.map { Array(all[$0...]) } ?? all
        if let bad = run.last(where: { $0.contains("staying off") }) { return "not used — \(bad)" }
        let aims = run.filter { $0 == "aiming: raw mouse on" }.count
        if aims > 0 {
            return "working — took over the mouse \(aims) time\(aims == 1 ? "" : "s") while aiming (menus and other apps get the normal pointer back)"
        }
        if run.contains(where: { $0.hasPrefix("ready") }) { return "ready, but the game never captured the mouse for aiming" }
        return "loaded, waiting for the first mouse move"
    }
}
