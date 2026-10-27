import Foundation
import IOKit

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
    /// The game's program as a Windows path (C:\Games\…\game.exe), so Apply picks the same one.
    public var program: String? = nil
    /// Battle.net games: Battle.net's own launch options.
    public var hostArguments: String? = nil
    /// Drive letters (besides C: and Z:) the game is installed on or reads from, e.g. ["D"].
    public var drives: [String]? = nil
    /// The game needs its disc image.
    public var disc: Bool? = nil
    /// Raw mouse "Smooth movement".
    public var rawMouseSmooth: Bool? = nil
    /// Audio buffer chunk size in ms (10, 20 or 40) for the game's Wine engine.
    public var audioBuffer: Int? = nil
    /// Game resolution: screen pixels while the game runs ([width, height]); nil = desktop (don't switch).
    public var displayPixels: [Int]? = nil
    /// Wine virtual screen size ([width, height]) for old games, shown in a window.
    public var virtualScreen: [Int]? = nil

    /// Paths inside the game's own app are shared as `{app}/…` and expanded on the other Mac.
    public static let appToken = "{app}"

    public static let sources = ["steam", "battlenet", "installer", "disc", "folder"]
    public static let knownFixes = ["cinematic"]

    /// Settings a shared profile may never set: anything that loads code or files, or moves Wine.
    public static func envNameAllowed(_ k: String) -> Bool {
        guard k.range(of: #"^[A-Z][A-Z0-9_]{0,63}$"#, options: .regularExpression) != nil else { return false }
        let banned = ["PATH", "HOME", "SHELL", "TMPDIR", "WINEPREFIX", "WINESERVER", "WINELOADER", "WINEARCH", "VK_DRIVER_FILES"]
        let bannedParts = ["DYLD_", "LD_", "NOKCANDU", "WINEDLLPATH", "PRELOAD", "ICD", "VK_LAYER", "VK_ADD_"]
        return !banned.contains(k) && !bannedParts.contains { k.hasPrefix($0) || k.contains($0) }
    }

    /// Values are one line; a path may only point inside the game's own app ({app}/…), never elsewhere.
    public static func envValueAllowed(_ v: String) -> Bool {
        if v.count > 300 || v.contains("\n") || v.contains("..") { return false }
        if v.contains("/") { return v.hasPrefix(appToken + "/") && !v.dropFirst(appToken.count).contains("{") }
        return true
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
            if !Self.envValueAllowed(v) { p.append("setting \(k) has a value that isn't allowed (one line; file paths only inside the game's app, as {app}/…)") }
        }
        if let s = rawMouse, s != 0 && !(0.1...10).contains(s) { p.append("rawMouse must be 0 (off) or 0.1–10") }
        if let perf = performance, !(perf.fpsLimit == 0 || (10...360).contains(perf.fpsLimit)) { p.append("fpsLimit must be 0 or 10–360") }
        if let h = performance?.hud, !Performance.Settings.hudStyles.contains(h) { p.append("hud must be fps, graph or full") }
        if let h = performance?.hudSize, !Performance.Settings.hudSizes.contains(h) { p.append("hudSize must be small, medium or large") }
        for f in fixes ?? [] where !Self.knownFixes.contains(f) { p.append("unknown fix \(f)") }
        if let prog = program, prog.range(of: #"^[A-Za-z]:\\[^\n:*?"<>|]{1,250}\.exe$"#, options: [.regularExpression, .caseInsensitive]) == nil || prog.contains("..") {
            p.append("program must be a Windows path to an .exe")
        }
        if let a = hostArguments, a.count > 300 || a.contains("\n") { p.append("Battle.net launch options must be one line, ≤300 characters") }
        for d in drives ?? [] where d.range(of: #"^[D-Yd-y]$"#, options: .regularExpression) == nil { p.append("drive \(d) isn't a letter from D to Y") }
        if let b = audioBuffer, !AudioBuffer.choices.contains(b) { p.append("audioBuffer must be 10, 20 or 40") }
        if let v = virtualScreen, v.count != 2 || !v.allSatisfy({ (320...8192).contains($0) }) { p.append("virtualScreen must be [width, height]") }
        if let d = displayPixels, d.count != 2 || !d.allSatisfy({ (320...8192).contains($0) }) { p.append("displayPixels must be [width, height] in pixels") }
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
    /// When it was first shared (ISO 8601); older catalogs don't have it.
    public var created: String?
    public var profile: GameProfile
    public init(number: Int, url: URL, author: String, up: Int, down: Int, comments: Int, updated: String, created: String? = nil, profile: GameProfile) {
        self.number = number; self.url = url; self.author = author; self.up = up; self.down = down
        self.comments = comments; self.updated = updated; self.created = created; self.profile = profile
    }
    public var updatedDate: Date? { ISO8601DateFormatter().date(from: updated) }
    public var createdDate: Date? { created.flatMap { ISO8601DateFormatter().date(from: $0) } }
    /// Tested with a different engine than the one Nokcandu uses now (may need re-checking).
    public var testedOnOtherEngine: Bool {
        guard let e = profile.tested?.engine, let v = EngineVersion(versionString: e) else { return false }
        return v != EngineVersion.tested
    }
    public var score: Int { up - down }
    /// Many more people say it doesn't work than that it does.
    public var reportedBroken: Bool { down >= 3 && down > up * 2 }
}

/// All profiles for one game, so the catalog stays tidy however many people share.
public struct ProfileGroup: Identifiable, Hashable {
    public var id: String                 // steam:730, bnet:osi, exe:war3.exe
    public var title: String
    public var source: String
    public var entries: [CatalogEntry]    // best first; reported-broken last
    public var steamAppID: Int?
    public var totalUp: Int { entries.reduce(0) { $0 + $1.up } }
    public var bestScore: Int { entries.map(\.score).max() ?? 0 }
    public var bestRating: GameProfile.Rating {
        let ok = entries.filter { !$0.reportedBroken }.map(\.profile.rating)
        return ok.contains(.works) ? .works : ok.contains(.playable) ? .playable : .broken
    }
    public var newest: Date? { entries.compactMap(\.updatedDate).max() }
}

public enum Profiles {
    public enum Sort: String, CaseIterable, Identifiable {
        case liked, recent, name
        public var id: String { rawValue }
        public var title: String { switch self { case .liked: "Most liked"; case .recent: "Recently updated"; case .name: "A–Z" } }
    }

    public static func groupKey(_ p: GameProfile) -> String {
        if let id = p.match.steamAppID { return "steam:\(id)" }
        if let u = p.match.battleNetUID { return "bnet:\(u.lowercased())" }
        return "exe:" + (p.match.exeName ?? p.title).lowercased()
    }

    /// Profiles grouped by game. Within a game: most 👍 first, then most recently updated; reported-broken last.
    public static func groups(_ entries: [CatalogEntry], sort: Sort = .liked) -> [ProfileGroup] {
        let byKey = Dictionary(grouping: entries, by: { groupKey($0.profile) })
        var out: [ProfileGroup] = byKey.map { key, list in
            let sorted = list.sorted {
                if $0.reportedBroken != $1.reportedBroken { return !$0.reportedBroken }
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast)
            }
            // The title most profiles use (people type names differently).
            let titles = Dictionary(grouping: list.map(\.profile.title), by: { $0 }).max { a, b in
                a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key }?.key ?? sorted[0].profile.title
            return ProfileGroup(id: key, title: titles, source: sorted[0].profile.source, entries: sorted,
                                steamAppID: sorted[0].profile.match.steamAppID)
        }
        switch sort {
        case .liked: out.sort { ($0.totalUp, $0.bestScore, $1.title) > ($1.totalUp, $1.bestScore, $0.title) }
        case .recent: out.sort { ($0.newest ?? .distantPast) > ($1.newest ?? .distantPast) }
        case .name: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return out
    }

    /// Profiles have their own repo, so Nokcandu's issue tracker stays for the app itself.
    public static let repo = "seastwood/Nokcandu-Profiles"
    public static let catalogURL = URL(string: "https://seastwood.github.io/Nokcandu-Profiles/catalog.json")!
    public static var catalogPage: URL { URL(string: "https://seastwood.github.io/Nokcandu-Profiles/")! }
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

    /// The app whose Wine settings a game uses (Battle.net games use the Battle.net app's).
    static func settingsApp(_ g: InstalledGame) -> InstalledGame {
        g.battleNet.flatMap { GameLibrary.inspect(URL(fileURLWithPath: $0.hostApp)) } ?? g
    }

    /// `/…/Game.app/Contents/x` → `{app}/x`; any other path stays as is (and then can't be shared).
    static func portable(_ v: String, contents: URL) -> String {
        let base = contents.standardizedFileURL.path
        return v.hasPrefix(base + "/") ? GameProfile.appToken + v.dropFirst(base.count) : v
    }

    /// A setting a profile can describe — so a profile without it means "not set". Settings that can't
    /// be shared (local file paths, loader variables) stay as they are.
    static func replaceable(_ k: String, _ v: String, _ host: InstalledGame) -> Bool {
        GameProfile.envNameAllowed(k) && GameProfile.envValueAllowed(portable(v, contents: host.contents))
    }

    static func expand(_ v: String, contents: URL) -> String {
        v.hasPrefix(GameProfile.appToken + "/") ? contents.standardizedFileURL.path + v.dropFirst(GameProfile.appToken.count) : v
    }

    /// Everything that makes this game work, as a shareable profile.
    public static func make(from g: InstalledGame, rating: GameProfile.Rating, notes: String?, install: String?) -> GameProfile {
        let c = g.custom
        let host = settingsApp(g)
        let hc = host.custom
        var source = "installer"
        var match = GameProfile.Match()
        if let id = c?.steamAppID, g.usesSharedSteam { source = "steam"; match.steamAppID = id }
        else if let l = g.battleNet { source = "battlenet"; match.battleNetUID = l.uid }
        else if let c {
            source = c.source == .disc ? "disc" : c.source == .folder ? "folder" : "installer"
            match.exeName = c.exe.split(separator: "\\").last.map(String.init)
        }
        var env: [String: String] = [:]
        for (k, v) in hc?.environment ?? [:] {
            let pv = portable(v, contents: host.contents)
            if GameProfile.envNameAllowed(k) && GameProfile.envValueAllowed(pv) { env[k] = pv }
        }
        let raw = RawMouse.settings(for: g)
        // Drive letters the game is installed on (or the game's program lives on), besides C:/Z:.
        var drives = Set<String>()
        if let exe = c?.exe, !g.usesSharedSteam, let l = exe.first, exe.dropFirst().hasPrefix(":"), !"CcZz".contains(l) { drives.insert(String(l).uppercased()) }
        if let l = g.battleNet, let loc = BattleNet.installedGames(host: host).first(where: { $0.uid == l.uid })?.installLocation,
           let d = loc.first, !"CcZz".contains(d) { drives.insert(String(d).uppercased()) }
        if g.usesSharedSteam, let id = c?.steamAppID, let lib = SharedSteam.installedGames().first(where: { $0.appID == id })?.library,
           lib.standardizedFileURL.path != SharedSteam.steamDir.standardizedFileURL.path {
            for d in Drives.list(for: g) where !d.builtIn && lib.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: d.target).standardizedFileURL.path) { drives.insert(d.letter) }
        }
        var p = GameProfile(title: g.battleNet?.name ?? c?.name ?? g.name, match: match, source: source, install: install,
                            graphics: hc?.graphics,
                            arguments: g.battleNet == nil ? c?.arguments : nil,
                            environment: env.isEmpty ? nil : env,
                            rawMouse: raw.enabled ? raw.scale : 0,
                            performance: Performance.settings(for: g),
                            fixes: CinematicFix.isPresent(for: g) ? ["cinematic"] : nil,
                            rating: rating,
                            tested: GameProfile.Tested(mac: macModel, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                                       engine: host.wineVersion ?? g.wineVersion, nokcandu: AppUpdate.currentVersion),
                            notes: notes)
        if !g.usesSharedSteam, g.battleNet == nil, let exe = c?.exe { p.program = exe }
        if g.battleNet != nil, let a = hc?.arguments, !a.isEmpty { p.hostArguments = a }
        if !drives.isEmpty { p.drives = drives.sorted() }
        if c?.disc != nil { p.disc = true }
        if raw.enabled { p.rawMouseSmooth = raw.smooth }
        p.audioBuffer = AudioBuffer.current(for: g)
        if g.battleNet == nil { p.displayPixels = c?.displayPixels }
        if p.arguments?.isEmpty == true { p.arguments = nil }
        return p
    }

    /// Your notes marked "Works" or "Info" for this game, to start the shared notes from.
    public static func suggestedNotes(for g: InstalledGame) -> String {
        GameNotes.load(for: g).filter { $0.kind == .works || $0.kind == .info }.map(\.text).joined(separator: "\n")
    }

    /// Settings a profile can't carry, by name and reason (normally none).
    public static func notShared(from g: InstalledGame) -> [String] {
        let host = settingsApp(g)
        var out: [String] = []
        for (k, v) in (host.custom?.environment ?? [:]).sorted(by: { $0.key < $1.key }) {
            let pv = portable(v, contents: host.contents)
            if !GameProfile.envNameAllowed(k) {
                out.append("\(k) — this setting makes Wine load code, so it can't be shared safely")
            } else if !GameProfile.envValueAllowed(pv) {
                out.append("\(k) — it points at a file outside the game's app (\(v)), which wouldn't exist on other Macs")
            }
        }
        return out
    }

    /// The Mac a profile was tested on, e.g. "MacBook Air (13-inch, M4, 2025), 16 GB" — the model matters
    /// (an M4 Air has no fan; an M4 Pro/Max has far more GPU), not only the chip.
    static var macModel: String {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var b = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &b, &size, nil, 0) == 0 else { return nil }
            return String(cString: b)
        }
        var memory: UInt64 = 0
        var msize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memory, &msize, nil, 0)
        let gb = memory > 0 ? ", \(memory / 1_073_741_824) GB" : ""
        // Apple silicon Macs carry their marketing name in the device tree.
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0, let d = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data,
           let name = String(data: d, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces)),
           !name.isEmpty {
            return name + gb
        }
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        return chip + (sysctlString("hw.model").map { " (\($0))" } ?? "") + gb
    }

    /// Opens a pre-filled "Game profile" issue on GitHub (the submitter just clicks Submit).
    public static func submitURL(_ p: GameProfile) -> URL {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")!
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
        let host = settingsApp(g)
        let shared = g.usesSharedSteam ? " (all Steam games)" : g.battleNet != nil ? " (all Battle.net games)" : ""
        if let prog = p.program, g.custom != nil, !g.usesSharedSteam, g.battleNet == nil {
            if BattleNet.unixPath(prog, prefix: g.prefix).map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                plan.gameSettings.append("Program: \(prog)")
            } else {
                plan.skipped.append("Program \(prog) — not found in this game, so the current program is kept")
            }
        }
        if let gr = p.graphics { plan.gameSettings.append("Graphics: \(gr.title)\(g.battleNet != nil ? shared : "")") }
        let a = p.arguments ?? ""
        if g.battleNet != nil {
            if !a.isEmpty { plan.skipped.append("Launch options \(a) (Battle.net games take launch options in Battle.net's game settings)") }
        } else if let mine = g.custom?.arguments, a != mine {
            plan.gameSettings.append(a.isEmpty ? "Launch options: none (removes \(mine))" : "Launch options: \(a)" + (mine.isEmpty ? "" : " (instead of \(mine))"))
        } else if !a.isEmpty {
            plan.gameSettings.append("Launch options: \(a) (same as now)")
        }
        if let a = p.hostArguments, g.battleNet != nil { plan.gameSettings.append("Battle.net launch options: \(a)") }
        let env = p.environment ?? [:]
        let text = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        if g.usesSharedSteam {
            if !env.isEmpty { plan.skipped.append("Extra settings \(text) (Steam games share Steam's environment — add them to a non-Steam copy if needed)") }
        } else {
            let removed = (host.custom?.environment ?? [:]).filter { env[$0.key] == nil && replaceable($0.key, $0.value, host) }.keys.sorted()
            if !env.isEmpty || !removed.isEmpty {
                plan.gameSettings.append("Extra settings: " + (env.isEmpty ? "none" : text) + (removed.isEmpty ? "" : " (removes \(removed.joined(separator: ", ")))") + (g.battleNet != nil ? shared : ""))
            }
        }
        if let r = p.rawMouse { plan.sharedSettings.append(r == 0 ? "Raw mouse: off\(shared)" : "Raw mouse: on at \(String(format: "%.2f", r))×\(p.rawMouseSmooth == true ? ", smooth movement" : "")\(shared)") }
        if let perf = p.performance {
            var parts: [String] = []
            if perf.fpsCounter { parts.append("FPS counter") }
            if perf.lowLatency == true { parts.append("low-latency mode") }
            if perf.vsync { parts.append("vsync") }
            if perf.fpsLimit > 0 { parts.append("\(perf.fpsLimit) FPS limit") }
            plan.sharedSettings.append("Performance: \(parts.isEmpty ? "all off" : parts.joined(separator: ", "))\(shared)")
        }
        if let b = p.audioBuffer, b != AudioBuffer.current(for: g) {
            plan.sharedSettings.append("Audio buffer: \(b) ms chunks\(shared)")
        }
        if g.battleNet == nil, g.custom != nil {
            let mine = g.custom?.displayPixels
            if let d = p.displayPixels {
                if GameDisplay.resolutions().contains(where: { $0.pixels == d }) {
                    if d != mine { plan.gameSettings.append("Game resolution: \(d[0]) × \(d[1]) (use the game's Fullscreen Windowed)") }
                } else {
                    plan.skipped.append("Game resolution \(d[0]) × \(d[1]) — this screen can't run it; pick one in Display")
                }
            } else if let m = mine {
                plan.gameSettings.append("Game resolution: desktop (removes \(m[0]) × \(m[1]))")
            }

        }
        if p.fixes?.contains("cinematic") == true {
            if CinematicFix.isPresent(for: g) { plan.gameSettings.append("Cinematic fix (LAV Filters): already installed") }
            else { plan.needsCinematicFix = true }
        }
        let have = Set(Drives.list(for: host).map(\.letter))
        for d in p.drives ?? [] {
            if have.contains(d.uppercased()) { plan.gameSettings.append("Uses drive \(d.uppercased()): (you have it)") }
            else { plan.skipped.append("Uses drive \(d.uppercased()): — you don't have it yet; add it in Files & Tools → Drives if your copy lives there") }
        }
        if p.disc == true && g.custom?.disc == nil { plan.skipped.append("Needs the game's disc image — add it in Settings → Disc image") }
        return plan
    }

    /// Settings as they were before a profile was applied, so trying a profile can be undone.
    public struct Snapshot {
        let target: InstalledGame
        let config: CustomGameConfig?
        let game: InstalledGame
        let raw: RawMouse.Settings
        let perf: Performance.Settings
        var buffer: Int? = nil
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
        if let b = s.buffer, b != AudioBuffer.current(for: s.game) { try? AudioBuffer.apply(b, for: s.game) }
    }

    /// Applies the profile's settings (not the cinematic fix — that downloads, so the UI runs it).
    /// Works on any game, not only the one it was made for. Returns what to restore for Undo.
    @discardableResult
    public static func apply(_ p: GameProfile, to g: InstalledGame, includeShared: Bool) throws -> Snapshot {
        let problems = p.problems
        guard problems.isEmpty else { throw NokError("This profile can't be applied: \(problems.joined(separator: "; ")).") }
        let target = g.battleNet.flatMap { GameLibrary.inspect(URL(fileURLWithPath: $0.hostApp)) } ?? g
        let snapshot = Snapshot(target: target, config: target.custom, game: g, raw: RawMouse.settings(for: g), perf: Performance.settings(for: g),
                                buffer: AudioBuffer.current(for: g))
        if var c = target.custom {
            if let gr = p.graphics { c.graphics = gr }
            if g.battleNet == nil { c.arguments = p.arguments ?? "" }
            if g.battleNet != nil, let a = p.hostArguments { c.arguments = a }
            if let prog = p.program, g.battleNet == nil, !g.usesSharedSteam,
               BattleNet.unixPath(prog, prefix: g.prefix).map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                c.exe = prog
            }
            if !g.usesSharedSteam {
                // The profile is the complete set of shareable settings; local-only ones are kept.
                var merged = (c.environment ?? [:]).filter { !replaceable($0.key, $0.value, target) }
                for (k, v) in p.environment ?? [:] where GameProfile.envNameAllowed(k) && GameProfile.envValueAllowed(v) {
                    merged[k] = expand(v, contents: target.contents)
                }
                c.environment = merged.isEmpty ? nil : merged
            }
            if g.battleNet == nil { c.virtualScreen = nil }
            if g.battleNet == nil {
                if let d = p.displayPixels { if GameDisplay.resolutions().contains(where: { $0.pixels == d }) { c.displayPixels = d } }
                else { c.displayPixels = nil }
            }
            if c != target.custom { try CustomGames.saveAll(c, to: target) }
        }
        if includeShared {
            if let r = p.rawMouse { try RawMouse.apply(RawMouse.Settings(enabled: r > 0, scale: r > 0 ? r : 1, smooth: p.rawMouseSmooth ?? false), for: g) }
            if let perf = p.performance { try Performance.apply(perf, for: g) }
            // Needs the game (or Steam) closed; skipped quietly otherwise — the profile sheet says so.
            if let b = p.audioBuffer, b != AudioBuffer.current(for: g) { try? AudioBuffer.apply(b, for: g) }
        }
        return snapshot
    }
}

/// The discussion on a shared profile (its GitHub issue), read through GitHub's public API.
public struct ProfileComment: Identifiable, Hashable, Sendable {
    public var id: Int
    public var author: String
    public var body: String
    public var created: Date?
    public var url: URL?
}

public enum ProfileComments {
    /// Current 👍/👎 on the profile (the catalog only refreshes hourly).
    public static func votes(issue number: Int) async -> (up: Int, down: Int)? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Profiles.repo)/issues/\(number)")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let rx = j["reactions"] as? [String: Any] else { return nil }
        return (rx["+1"] as? Int ?? 0, rx["-1"] as? Int ?? 0)
    }

    public static func fetch(issue number: Int) async throws -> [ProfileComment] {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Profiles.repo)/issues/\(number)/comments?per_page=100")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
            throw NokError(code == 403 ? "GitHub is limiting requests right now — try again in a bit, or read them on GitHub." : "Couldn't load the comments (\(code)).")
        }
        let iso = ISO8601DateFormatter()
        return arr.compactMap { c in
            guard let id = c["id"] as? Int, let body = c["body"] as? String else { return nil }
            // The catalog's own status notes (from GitHub Actions) aren't discussion.
            if ((c["user"] as? [String: Any])?["type"] as? String) == "Bot" { return nil }
            return ProfileComment(id: id, author: ((c["user"] as? [String: Any])?["login"] as? String) ?? "someone", body: body,
                                  created: (c["created_at"] as? String).flatMap(iso.date(from:)),
                                  url: (c["html_url"] as? String).flatMap(URL.init(string:)))
        }
    }
}
