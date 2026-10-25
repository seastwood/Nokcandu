import Foundation

/// Shareable game profiles: the settings that make a game work (graphics, launch options, extra
/// settings, raw mouse, performance, needed fixes) plus how well it runs. Settings only — never scripts,
/// files or paths — so applying someone else's profile can't do anything beyond what Nokcandu's own
/// settings screens can.
///
/// The public catalog lives in GitHub Issues on the Nokcandu repo (label `profile`): 👍/👎 reactions are
/// votes, comments are the discussion. A GitHub Action validates each submission with the same rules as
/// `GameProfile.problems` and publishes `catalog.json` to GitHub Pages, which Nokcandu reads.
public struct GameProfile: Codable, Hashable {
    public enum Rating: String, Codable, CaseIterable, Identifiable {
        case works, playable, broken
        public var id: String { rawValue }
        public var title: String { switch self { case .works: "Works great"; case .playable: "Playable with issues"; case .broken: "Doesn't work" } }
    }
    public struct Match: Codable, Hashable {
        public var steamAppID: Int?
        public var battleNetUID: String?
        public var exeName: String?          // e.g. "war3.exe" for games added from an installer, disc or folder
        public init(steamAppID: Int? = nil, battleNetUID: String? = nil, exeName: String? = nil) {
            self.steamAppID = steamAppID; self.battleNetUID = battleNetUID; self.exeName = exeName
        }
    }
    public struct Tested: Codable, Hashable {
        public var mac: String?
        public var macOS: String?
        public var engine: String?
        public var nokcandu: String?
    }

    public var schema = 1
    public var title: String
    public var match: Match
    /// How the game gets onto the Mac: steam, battlenet, installer, disc, folder.
    public var source: String
    public var install: String?
    public var graphics: GraphicsPreset?
    public var arguments: String?
    public var environment: [String: String]?
    public var rawMouse: Double?             // nil = leave as is, 0 = off, >0 = on at that aim speed
    public var performance: Performance.Settings?
    public var fixes: [String]?              // "cinematic"
    public var rating: Rating
    public var tested: Tested?
    public var notes: String?

    public static let sources = ["steam", "battlenet", "installer", "disc", "folder"]
    public static let knownFixes = ["cinematic"]

    /// Settings a shared profile may never set: anything that loads code or files, or moves Wine.
    public static func envNameAllowed(_ k: String) -> Bool {
        guard k.range(of: #"^[A-Z][A-Z0-9_]{0,63}$"#, options: .regularExpression) != nil else { return false }
        let banned = ["PATH", "HOME", "SHELL", "TMPDIR", "WINEPREFIX", "WINESERVER", "WINELOADER", "WINEARCH"]
        let bannedParts = ["DYLD_", "LD_", "NOKCANDU", "WINEDLLPATH", "_PATH", "LIBRARY", "PRELOAD", "ICD", "LAYER", "DRIVER_FILES", "FRAMEWORK"]
        return !banned.contains(k) && !bannedParts.contains { k.hasPrefix($0) || k.contains($0) }
    }

    /// Everything wrong with a profile (empty = safe to publish and apply).
    public var problems: [String] {
        var p: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.count > 100 { p.append("title must be 1–100 characters") }
        if schema != 1 { p.append("unknown schema \(schema)") }
        if !Self.sources.contains(source) { p.append("source must be one of \(Self.sources.joined(separator: ", "))") }
        if match.steamAppID == nil && match.battleNetUID == nil && (match.exeName ?? "").isEmpty { p.append("match needs steamAppID, battleNetUID or exeName") }
        if let e = match.exeName, e.range(of: #"^[^/\\:*?"<>|]{1,80}\.exe$"#, options: [.regularExpression, .caseInsensitive]) == nil { p.append("exeName must be a plain .exe file name") }
        if let u = match.battleNetUID, u.range(of: #"^[a-z0-9_.\-]{1,30}$"#, options: .regularExpression) == nil { p.append("battleNetUID looks wrong") }
        if let a = arguments, a.count > 300 || a.contains("\n") { p.append("launch options must be one line, ≤300 characters") }
        let env = environment ?? [:]
        if env.count > 30 { p.append("too many settings (max 30)") }
        for (k, v) in env {
            if !Self.envNameAllowed(k) { p.append("setting \(k) isn't allowed in shared profiles") }
            if v.count > 300 || v.contains("\n") || v.contains("/") || v.contains("..") { p.append("setting \(k) has a value that isn't allowed (no paths, one line)") }
        }
        if let s = rawMouse, s != 0 && !(0.1...10).contains(s) { p.append("rawMouse must be 0 (off) or 0.1–10") }
        if let perf = performance, !(perf.fpsLimit == 0 || (10...360).contains(perf.fpsLimit)) { p.append("fpsLimit must be 0 or 10–360") }
        for f in fixes ?? [] where !Self.knownFixes.contains(f) { p.append("unknown fix \(f)") }
        for (name, text) in [("install", install), ("notes", notes)] where (text?.count ?? 0) > 4000 { p.append("\(name) is too long") }
        return p
    }

    public func json() -> String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// From a .json file, pasted text, or a GitHub issue body (first ```json block).
    public static func parse(_ text: String) throws -> GameProfile {
        var body = text
        if let r = text.range(of: #"```(?:json)?\s*\n([\s\S]*?)\n```"#, options: .regularExpression) {
            body = String(text[r]).replacingOccurrences(of: #"^```(?:json)?\s*\n"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n```", with: "")
        }
        guard let d = body.data(using: .utf8) else { throw NokError("That isn't a Nokcandu profile.") }
        do { return try JSONDecoder().decode(GameProfile.self, from: d) }
        catch { throw NokError("That isn't a valid Nokcandu profile: \(error.localizedDescription)") }
    }
}

/// A profile as published in the catalog, with its votes and discussion.
public struct CatalogEntry: Codable, Identifiable, Hashable {
    public var id: Int { number }
    public var number: Int
    public var url: URL
    public var author: String
    public var up: Int
    public var down: Int
    public var comments: Int
    public var updated: String
    public var profile: GameProfile
    public init(number: Int, url: URL, author: String, up: Int, down: Int, comments: Int, updated: String, profile: GameProfile) {
        self.number = number; self.url = url; self.author = author; self.up = up; self.down = down
        self.comments = comments; self.updated = updated; self.profile = profile
    }
    public var score: Int { up - down }
    /// Many more people say it doesn't work than that it does.
    public var reportedBroken: Bool { down >= 3 && down > up * 2 }
}

public enum Profiles {
    public static let catalogURL = URL(string: "https://seastwood.github.io/Nokcandu/catalog.json")!
    public static var catalogPage: URL { URL(string: "https://seastwood.github.io/Nokcandu/")! }
    static var cacheURL: URL { NokPaths.support.appendingPathComponent("profiles-catalog.json") }

    /// One bad entry must never hide the rest of the catalog, so entries are decoded one by one.
    struct Catalog: Decodable {
        var profiles: [CatalogEntry]
        struct Lossy: Decodable {
            var value: CatalogEntry?
            init(from d: Decoder) throws { value = try? CatalogEntry(from: d) }
        }
        enum K: String, CodingKey { case profiles }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            profiles = (try c.decode([Lossy].self, forKey: .profiles)).compactMap(\.value)
        }
    }

    static func decode(_ data: Data) -> [CatalogEntry]? {
        (try? JSONDecoder().decode(Catalog.self, from: data))?.profiles.filter { $0.profile.problems.isEmpty }
    }

    public static func cached() -> [CatalogEntry] {
        (try? Data(contentsOf: cacheURL)).flatMap(decode) ?? []
    }

    /// Downloads the catalog (falls back to the last copy when offline). Invalid profiles are dropped.
    public static func fetch() async -> (entries: [CatalogEntry], offline: Bool) {
        var req = URLRequest(url: catalogURL); req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let entries = decode(data) else { return (cached(), true) }
        try? NokPaths.ensure(NokPaths.support)
        try? data.write(to: cacheURL, options: .atomic)
        return (entries, false)
    }

    /// Profiles for this game, best first.
    public static func forGame(_ g: InstalledGame, in entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.filter { matches($0.profile, g) }.sorted { ($0.reportedBroken ? 1 : 0, -$0.score) < ($1.reportedBroken ? 1 : 0, -$1.score) }
    }

    public static func matches(_ p: GameProfile, _ g: InstalledGame) -> Bool {
        if let id = p.match.steamAppID, g.custom?.steamAppID == id { return true }
        if let uid = p.match.battleNetUID, g.battleNet?.uid.lowercased() == uid.lowercased() { return true }
        if let exe = p.match.exeName?.lowercased(), let mine = g.custom?.exe.split(separator: "\\").last?.lowercased(), !g.usesSharedSteam {
            return exe == mine
        }
        return false
    }

    // MARK: Making a profile from a working game

    public static func make(from g: InstalledGame, rating: GameProfile.Rating, notes: String?, install: String?) -> GameProfile {
        let c = g.custom
        var source = "installer"
        var match = GameProfile.Match()
        if let id = c?.steamAppID, g.usesSharedSteam { source = "steam"; match.steamAppID = id }
        else if let l = g.battleNet { source = "battlenet"; match.battleNetUID = l.uid }
        else if let c {
            source = c.source == .disc ? "disc" : c.source == .folder ? "folder" : "installer"
            match.exeName = c.exe.split(separator: "\\").last.map(String.init)
        }
        // Battle.net games run with the Battle.net app's settings.
        let settingsFrom = g.battleNet.flatMap { GameLibrary.inspect(URL(fileURLWithPath: $0.hostApp)) } ?? g
        let sc = settingsFrom.custom
        let raw = RawMouse.settings(for: g)
        let perf = Performance.settings(for: g)
        let env = (sc?.environment ?? [:]).filter { GameProfile.envNameAllowed($0.key) && !$0.value.contains("/") }
        var p = GameProfile(title: g.battleNet?.name ?? c?.name ?? g.name, match: match, source: source, install: install,
                            graphics: sc?.graphics, arguments: g.battleNet == nil ? (c?.arguments.isEmpty == false ? c?.arguments : nil) : nil,
                            environment: env.isEmpty ? nil : env, rawMouse: raw.enabled ? raw.scale : 0,
                            performance: perf.isDefault ? nil : perf, fixes: CinematicFix.isPresent(for: g) ? ["cinematic"] : nil,
                            rating: rating, tested: GameProfile.Tested(mac: macModel, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                                                       engine: (WineTools.hostContents(for: g).flatMap { GameLibrary.inspect($0.deletingLastPathComponent())?.wineVersion }) ?? g.wineVersion,
                                                                       nokcandu: AppUpdate.currentVersion),
                            notes: notes)
        if p.environment?.isEmpty == true { p.environment = nil }
        return p
    }

    static var macModel: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var b = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &b, &size, nil, 0)
        return String(cString: b)
    }

    /// Opens a pre-filled "Game profile" issue on GitHub (the submitter just clicks Submit).
    public static func submitURL(_ p: GameProfile) -> URL {
        var c = URLComponents(string: "https://github.com/\(AppUpdate.repo)/issues/new")!
        c.queryItems = [
            URLQueryItem(name: "template", value: "game-profile.yml"),
            URLQueryItem(name: "title", value: "[Profile] \(p.title) — \(p.rating.title)"),
            URLQueryItem(name: "profile", value: p.json()),
        ]
        return c.url!
    }

    // MARK: Applying

    public struct Plan {
        public var gameSettings: [String] = []
        public var sharedSettings: [String] = []      // raw mouse / performance (whole Steam or Battle.net, or the app)
        public var needsCinematicFix = false
        public var skipped: [String] = []
    }

    /// What applying would change, in plain words.
    public static func plan(_ p: GameProfile, for g: InstalledGame) -> Plan {
        var plan = Plan()
        let shared = g.usesSharedSteam ? " (all Steam games)" : g.battleNet != nil ? " (all Battle.net games)" : ""
        if let gr = p.graphics { plan.gameSettings.append("Graphics: \(gr.title)\(g.battleNet != nil ? shared : "")") }
        if let a = p.arguments, !a.isEmpty {
            if g.battleNet != nil { plan.skipped.append("Launch options (Battle.net games take options in Battle.net's own settings)") }
            else { plan.gameSettings.append("Launch options: \(a)") }
        }
        if let env = p.environment, !env.isEmpty {
            if g.usesSharedSteam { plan.skipped.append("Extra settings \(env.keys.sorted().joined(separator: ", ")) (Steam games share Steam's environment)") }
            else { plan.gameSettings.append("Extra settings: " + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + (g.battleNet != nil ? shared : "")) }
        }
        if let r = p.rawMouse { plan.sharedSettings.append(r == 0 ? "Raw mouse: off\(shared)" : "Raw mouse: on at \(String(format: "%.2f", r))×\(shared)") }
        if let perf = p.performance {
            var parts: [String] = []
            if perf.fpsCounter { parts.append("FPS counter") }
            if perf.vsync { parts.append("vsync") }
            if perf.fpsLimit > 0 { parts.append("\(perf.fpsLimit) FPS limit") }
            plan.sharedSettings.append("Performance: \(parts.isEmpty ? "defaults" : parts.joined(separator: ", "))\(shared)")
        }
        if p.fixes?.contains("cinematic") == true && !CinematicFix.isPresent(for: g) { plan.needsCinematicFix = true }
        return plan
    }

    /// Settings as they were before a profile was applied, so trying a profile can be undone.
    public struct Snapshot {
        let target: InstalledGame
        let config: CustomGameConfig?
        let game: InstalledGame
        let raw: RawMouse.Settings
        let perf: Performance.Settings
        public var gameName: String { game.name }
    }

    /// Games a profile can be tried on: anything with settings Nokcandu manages.
    public static func canTry(_ g: InstalledGame) -> Bool { g.custom != nil || g.battleNet != nil }

    /// Puts back the settings from before `apply`.
    public static func undo(_ s: Snapshot) throws {
        if let c = s.config, GameLibrary.inspect(s.target.appURL)?.custom != c {
            try CustomGames.saveAll(c, to: GameLibrary.inspect(s.target.appURL) ?? s.target)
        }
        try RawMouse.apply(s.raw, for: s.game)
        try Performance.apply(s.perf, for: s.game)
    }

    /// Applies the profile's settings (not the cinematic fix — that downloads, so the UI runs it).
    /// Works on any game, not only the one it was made for. Returns what to restore for Undo.
    @discardableResult
    public static func apply(_ p: GameProfile, to g: InstalledGame, includeShared: Bool) throws -> Snapshot {
        let problems = p.problems
        guard problems.isEmpty else { throw NokError("This profile can't be applied: \(problems.joined(separator: "; ")).") }
        let target = g.battleNet.flatMap { GameLibrary.inspect(URL(fileURLWithPath: $0.hostApp)) } ?? g
        let snapshot = Snapshot(target: target, config: target.custom, game: g, raw: RawMouse.settings(for: g), perf: Performance.settings(for: g))
        if var c = target.custom {
            if let gr = p.graphics { c.graphics = gr }
            if g.battleNet == nil, let a = p.arguments { c.arguments = a }
            if !g.usesSharedSteam, let env = p.environment, !env.isEmpty {
                var merged = c.environment ?? [:]
                for (k, v) in env where GameProfile.envNameAllowed(k) { merged[k] = v }
                c.environment = merged
            }
            if c != target.custom { try CustomGames.saveAll(c, to: target) }
        }
        if includeShared {
            if let r = p.rawMouse { try RawMouse.apply(RawMouse.Settings(enabled: r > 0, scale: r > 0 ? r : 1), for: g) }
            if let perf = p.performance { try Performance.apply(perf, for: g) }
        }
        return snapshot
    }
}
