import Foundation

/// Per-game input consent. Off blocks capture; live-mode discovery remains available
/// because Wine caches endpoints. Active input stops without interrupting output.
public enum GameMicrophone {
    /// Games whose launcher Nokcandu writes (its own games and EA/Ubisoft games added to Nokcandu).
    public static func supported(_ g: InstalledGame) -> Bool { g.native == nil && (g.custom != nil || g.hosted?.exe != nil || g.battleNet != nil || g.isSteamHost || RecipeSettings.supports(g)) }

    static let sharedChoice = "microphone-enabled"
    public static func isOn(_ g: InstalledGame) -> Bool {
        if g.isSteamHost || g.battleNet != nil { return FileManager.default.fileExists(atPath: g.nokcanduState.appendingPathComponent(sharedChoice).path) }
        if let c = g.custom { return c.microphone == true }
        if g.hosted != nil { return HostedSettings.load(g).microphone == true }
        if RecipeSettings.supports(g) { return RecipeSettings.load(g).microphone }
        return true
    }

    static let variable = "NOKCANDU_NO_MICROPHONE"
    static func launcherExports(allowed: Bool) -> String { "export \(variable)=\(allowed ? "0" : "1")" }
    static func apply(contents: URL, to env: inout [String: String]) {
        if let config = CustomGameConfig.load(contents: contents) {
            env[variable] = config.microphone == true ? "0" : "1"
        } else if SharedSteam.isHost(contents: contents) {
            let flag = contents.appendingPathComponent("SharedSupport/nokcandu/" + sharedChoice)
            env[variable] = FileManager.default.fileExists(atPath: flag.path) ? "0" : "1"
        } else if let game = GameLibrary.inspect(contents.deletingLastPathComponent()), RecipeSettings.supports(game) {
            env[variable] = RecipeSettings.load(game).microphone ? "0" : "1"
        }
        // Wine setup/tool processes need the same input guard as normal Play.
        if env[variable] != nil {
            let helper = contents.appendingPathComponent("SharedSupport/nokcandu/" + RawMouse.dylibName)
            if FileManager.default.fileExists(atPath: helper.path) { env["DYLD_INSERT_LIBRARIES"] = helper.path }
        }
    }
    /// The guard reads these files using its own dylib location, so child
    /// programs cannot lose the policy by rebuilding their environment.
    static let policyFile = "microphone-policy"
    static let routeFile = "program-microphones.tsv"
    public static func refreshPolicies(_ games: [InstalledGame]) throws {
        var defaults: [URL: Bool] = [:] // true = input blocked
        var routes: [URL: [String: Bool]] = [:]
        func add(_ key: String, blocked: Bool, host: URL) {
            guard !key.isEmpty, key.rangeOfCharacter(from: .newlines) == nil, !key.contains("\t") else { return }
            let key = key.lowercased()
            routes[host, default: [:]][key] = (routes[host]?[key] ?? false) || blocked
        }
        for saved in games {
            let g = GameLibrary.inspect(saved.appURL) ?? saved
            guard supported(g), let host = WineTools.hostContents(for: g) else { continue }
            let blocked = !isOn(g)
            let client = PCLaunchers.kind(of: g)
            let shared = g.usesSharedSteam || g.hosted != nil || g.battleNet != nil || g.isSteamHost || BattleNet.isHost(g) || client != nil
            if shared {
                defaults[host] = true // unknown children never inherit a client's opt-in
                if g.isSteamHost {
                    for name in ["steam.exe", "steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe"] { add(name, blocked: blocked, host: host) }
                } else if BattleNet.isHost(g) || client != nil {
                    let names = BattleNet.isHost(g) ? ["battle.net.exe", "battle.net launcher.exe", "agent.exe"] : client == .ea ? ["eadesktop.exe", "eabackgroundservice.exe", "ealocalhostsvc.exe"] : ["upc.exe", "uplaywebcore.exe", "uplayservice.exe"]
                    for name in names { add(name, blocked: blocked, host: host) }
                } else {
                    if g.battleNet != nil, let h = GameLibrary.inspect(host.deletingLastPathComponent()), let name = BattleNetGraphics.program(g, host: h) { add(name, blocked: blocked, host: host) }
                    if let id = g.custom?.steamAppID { add("steam:\(id)", blocked: blocked, host: host) }
                    if let exe = g.hosted?.exe ?? g.custom?.exe {
                        add(exe, blocked: blocked, host: host)
                        let name = exe.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? exe
                        add(name, blocked: blocked, host: host)
                        if let folder = BattleNet.unixPath(exe, prefix: host.appendingPathComponent("SharedSupport/prefix"))?.deletingLastPathComponent() {
                            for name in RawMouse.exeNames(in: folder) { add(name, blocked: blocked, host: host) }
                        }
                    }
                    if g.usesSharedSteam, let id = g.custom?.steamAppID,
                       let folder = SharedSteam.installedGames().first(where: { $0.appID == id })?.folder {
                        for name in RawMouse.exeNames(in: folder) { add(name, blocked: blocked, host: host) }
                    }
                }
            } else { defaults[host] = blocked }
        }
        for (host, blocked) in defaults {
            // An app that moved away while this ran must not be recreated as an empty folder.
            guard AppPresence.exists(host) else { continue }
            let directory = host.appendingPathComponent("SharedSupport/nokcandu")
            try NokPaths.ensure(directory)
            let values = [("microphone-live", "1\n"), (policyFile, blocked ? "1\n" : "0\n"),
                          (routeFile, (routes[host] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)\tNOKCANDU_NO_MICROPHONE=\($0.value ? "1" : "0")" }.joined(separator: "\n") + "\n")]
            for (name, text) in values {
                let target = directory.appendingPathComponent(name)
                guard target.resolvingSymlinksInPath() == target else { throw NokError("The microphone policy path is linked. It was preserved.") }
                if (try? String(contentsOf: target, encoding: .utf8)) != text { try Data(text.utf8).write(to: target, options: .atomic) }
            }
        }
    }
    public static func set(_ on: Bool, for g: InstalledGame) throws {
        guard supported(g) else { throw NokError("This game does not support microphone settings.") }
        // Change only consent, never regenerate a running game's launcher or lose
        // unknown settings. Its saved launcher hash continues to describe that file.
        _ = try AppPrivacy.apply(g.appURL, microphone: on)
        let journal = ChangeJournal(scope: g.journalScope)
        if g.isSteamHost || g.battleNet != nil {
            let flag = g.nokcanduState.appendingPathComponent(sharedChoice)
            try NokPaths.ensure(g.nokcanduState)
            if on { try journal.write(Data("1\n".utf8), to: flag, reason: "Microphone input on") }
            else if FileManager.default.fileExists(atPath: flag.path) { try FileManager.default.removeItem(at: flag) }
        } else {
            let file = g.custom != nil ? CustomGameConfig.url(in: g.contents)
                : g.hosted != nil ? HostedSettings.url(g.contents) : RecipeSettings.file(g)
            guard file.resolvingSymlinksInPath() == file else { throw NokError("The microphone settings path is linked. It was preserved.") }
            var value: [String: Any]
            if FileManager.default.fileExists(atPath: file.path) {
                guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw NokError("The game's settings could not be read. They were preserved.") }
                value = saved
            } else if g.hosted != nil {
                value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HostedSettings.load(g))) as! [String: Any]
            } else {
                value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RecipeSettings.load(g))) as! [String: Any]
            }
            value["microphone"] = on
            try journal.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: file, reason: "Microphone input \(on ? "on" : "off")")
        }
        let fresh = GameLibrary.inspect(g.appURL) ?? g
        if let host = WineTools.hostContents(for: fresh) {
            // Finder/Dock launches must see the new saved policy immediately,
            // rather than waiting for Play or the periodic library maintenance.
            var related = [fresh]
            if host != fresh.contents {
                related += GameLibrary.scan().filter { $0.id != fresh.id && WineTools.hostContents(for: $0) == host }
                if let parent = GameLibrary.inspect(host.deletingLastPathComponent()), !related.contains(where: { $0.id == parent.id }) { related.append(parent) }
            }
            try refreshPolicies(related)
            if on { try AppPrivacy.prepare(fresh, games: related) }
        }
    }
}
