import Foundation

/// Per-game key remapping. While the game is in front,
/// Nokcandu's helper inside it swaps the chosen keys with macOS's own keyboard remapping (hidutil), and puts the
/// keyboard back when you switch away or the game quits. Kept per Windows environment ("key-remap" in its state
/// folder, beside the helper), like raw mouse capture. Keys are stored as HID usages (page 7 keyboard keys, and
/// Apple's fn key), the form macOS's remapping takes.
public enum KeyRemap {
    public struct Key: Hashable, Identifiable, Sendable {
        public var code: Int
        public var title: String
        /// Karabiner-Elements' name for it ("left_control"), for importing.
        public var karabiner: String
        public var id: Int { code }
    }

    /// Keys that can be remapped (Mac virtual key codes).
    public static let keys: [Key] = {
        var k: [Key] = [
            Key(code: 59, title: "Left Control", karabiner: "left_control"), Key(code: 62, title: "Right Control", karabiner: "right_control"),
            Key(code: 58, title: "Left Option", karabiner: "left_option"), Key(code: 61, title: "Right Option", karabiner: "right_option"),
            Key(code: 55, title: "Left Command", karabiner: "left_command"), Key(code: 54, title: "Right Command", karabiner: "right_command"),
            Key(code: 56, title: "Left Shift", karabiner: "left_shift"), Key(code: 60, title: "Right Shift", karabiner: "right_shift"),
            Key(code: 63, title: "fn", karabiner: "fn"), Key(code: 57, title: "Caps Lock", karabiner: "caps_lock"),
            Key(code: 49, title: "Space", karabiner: "spacebar"), Key(code: 48, title: "Tab", karabiner: "tab"),
            Key(code: 36, title: "Return", karabiner: "return_or_enter"), Key(code: 53, title: "Escape", karabiner: "escape"),
            Key(code: 51, title: "Delete", karabiner: "delete_or_backspace"), Key(code: 117, title: "Forward Delete", karabiner: "delete_forward"),
            Key(code: 50, title: "` (Grave)", karabiner: "grave_accent_and_tilde"), Key(code: 10, title: "§ (Section)", karabiner: "non_us_backslash"),
            Key(code: 123, title: "Left Arrow", karabiner: "left_arrow"), Key(code: 124, title: "Right Arrow", karabiner: "right_arrow"),
            Key(code: 125, title: "Down Arrow", karabiner: "down_arrow"), Key(code: 126, title: "Up Arrow", karabiner: "up_arrow"),
            Key(code: 115, title: "Home", karabiner: "home"), Key(code: 119, title: "End", karabiner: "end"),
            Key(code: 116, title: "Page Up", karabiner: "page_up"), Key(code: 121, title: "Page Down", karabiner: "page_down"),
        ]
        let letters: [(String, Int)] = [("A", 0), ("S", 1), ("D", 2), ("F", 3), ("H", 4), ("G", 5), ("Z", 6), ("X", 7), ("C", 8), ("V", 9),
                                        ("B", 11), ("Q", 12), ("W", 13), ("E", 14), ("R", 15), ("Y", 16), ("T", 17), ("O", 31), ("U", 32),
                                        ("I", 34), ("P", 35), ("L", 37), ("J", 38), ("K", 40), ("N", 45), ("M", 46)]
        k += letters.sorted { $0.0 < $1.0 }.map { Key(code: $0.1, title: $0.0, karabiner: $0.0.lowercased()) }
        let digits: [(String, Int)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)]
        k += digits.map { Key(code: $0.1, title: $0.0, karabiner: $0.0) }
        let fkeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        k += fkeys.enumerated().map { Key(code: $0.element, title: "F\($0.offset + 1)", karabiner: "f\($0.offset + 1)") }
        return k
    }()
    public static func key(_ code: Int) -> Key? { keys.first { $0.code == code } }

    /// HID usage (as macOS's keyboard remapping takes it) for a Mac key code.
    static let hidUsages: [Int: UInt64] = {
        var u: [Int: UInt64] = [59: 0xE0, 56: 0xE1, 58: 0xE2, 55: 0xE3, 62: 0xE4, 60: 0xE5, 61: 0xE6, 54: 0xE7, 57: 0x39,
                                49: 0x2C, 48: 0x2B, 36: 0x28, 53: 0x29, 51: 0x2A, 117: 0x4C, 50: 0x35, 10: 0x64,
                                124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52, 115: 0x4A, 119: 0x4D, 116: 0x4B, 121: 0x4E]
        let letters: [Int] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]   // A…Z
        for (i, code) in letters.enumerated() { u[code] = 0x04 + UInt64(i) }
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]                                                    // 1…9, 0
        for (i, code) in digits.enumerated() { u[code] = 0x1E + UInt64(i) }
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { u[code] = 0x3A + UInt64(i) }
        var out = u.mapValues { 0x7_0000_0000 | $0 }
        out[63] = 0xFF01_0000_0003                                                                               // fn (Globe)
        return out
    }()
    /// A key that does nothing (keyboard usage 0: no event).
    static let nothingUsage: UInt64 = 0x7_0000_0000

    /// One remap: `from` acts as `to` (nil: does nothing).
    public struct Mapping: Hashable, Identifiable, Sendable, Codable {
        public var from: Int
        public var to: Int?
        public var id: Int { from }
        public init(from: Int, to: Int?) { self.from = from; self.to = to }
    }

    static func folder(_ contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu", isDirectory: true) }
    static func file(_ contents: URL) -> URL { folder(contents).appendingPathComponent("key-remap") }
    /// Same scope as raw mouse capture: the game's own environment, or its launcher's.
    public static func contents(for g: InstalledGame) -> URL? { WineTools.hostContents(for: g) }

    public static func load(contents: URL) -> [Mapping] {
        guard let text = try? String(contentsOf: file(contents), encoding: .utf8) else { return [] }
        return parse(text)
    }
    static func parse(_ text: String) -> [Mapping] {
        var seen = Set<Int>()
        let byUsage = Dictionary(hidUsages.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        return text.split(separator: "\n").compactMap { line -> Mapping? in
            let p = line.split(separator: " ").compactMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
            guard p.count == 2, let from = byUsage[p[0]], seen.insert(from).inserted else { return nil }
            if p[1] == nothingUsage { return Mapping(from: from, to: nil) }
            guard let to = byUsage[p[1]] else { return nil }
            return Mapping(from: from, to: to)
        }
    }
    static func text(_ m: [Mapping]) -> String {
        m.compactMap { x -> String? in
            guard let src = hidUsages[x.from] else { return nil }
            let dst = x.to.flatMap { hidUsages[$0] } ?? nothingUsage
            return String(format: "0x%llx 0x%llx", src, dst)
        }.joined(separator: "\n") + (m.isEmpty ? "" : "\n")
    }

    // MARK: Layouts shared by games

    /// A named set of remaps that any number of games can use ("Voidlink keys"). Editing it changes every game
    /// using it. Kept in Application Support/Nokcandu/key-layouts.json. One layout can be the default: every game
    /// that hasn't been given keys of its own follows it.
    public struct Layout: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var mappings: [Mapping]
        public init(id: String = UUID().uuidString, name: String, mappings: [Mapping]) { self.id = id; self.name = name; self.mappings = mappings }
    }

    /// What a Windows environment's keys follow ("key-layout" in its state folder; its keys are in "key-remap").
    public enum Choice: Equatable, Sendable {
        /// The default layout, whatever it is (and normal keys while there's none). Every game starts here.
        case followDefault
        /// Normal keys, even when there's a default layout.
        case normal
        /// Keys of its own, not shared.
        case own
        case layout(String)
        /// A game inside a shared launcher (Steam, Battle.net…) that uses the launcher's keys.
        case sameAsLauncher
    }

    /// Games inside a shared launcher keep their own choice in their own app; the launcher's is the fallback.
    public static func isShared(_ g: InstalledGame) -> Bool { g.usesSharedSteam || g.battleNet != nil || g.hosted != nil }
    /// Where this game's own keys live: its own app for games inside a launcher, else its Windows environment.
    public static func gameContents(for g: InstalledGame) -> URL? { isShared(g) ? g.contents : contents(for: g) }

    public static var layoutsFile: URL { NokPaths.support.appendingPathComponent("key-layouts.json") }
    public static var defaultFile: URL { NokPaths.support.appendingPathComponent("key-layout-default") }
    static func layoutFile(_ contents: URL) -> URL { folder(contents).appendingPathComponent("key-layout") }

    public static func layouts(file: URL = layoutsFile) -> [Layout] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Layout].self, from: $0) } ?? []
    }
    static func saveLayouts(_ l: [Layout], file: URL = layoutsFile) throws {
        try NokPaths.ensure(file.deletingLastPathComponent())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }).write(to: file, options: .atomic)
    }

    public static func defaultLayoutID(file: URL = defaultFile) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    public static func defaultLayout(layouts all: [Layout]? = nil, file: URL = defaultFile, layoutsFile lf: URL = layoutsFile) -> Layout? {
        guard let id = defaultLayoutID(file: file) else { return nil }
        return (all ?? layouts(file: lf)).first { $0.id == id }
    }

    public static func choice(contents: URL, shared: Bool = false) -> Choice {
        guard let raw = (try? String(contentsOf: layoutFile(contents), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            if shared { return .sameAsLauncher }
            // Keys set before layouts existed are this game's own.
            return FileManager.default.fileExists(atPath: file(contents).path) ? .own : .followDefault
        }
        switch raw {
        case "launcher": return .sameAsLauncher
        case "default": return .followDefault
        case "none": return .normal
        case "own": return .own
        default: return .layout(raw)
        }
    }

    /// Sets what this environment's keys follow and writes the keys the helper reads.
    public static func set(_ c: Choice, contents: URL, own: [Mapping] = [], file lf: URL = layoutsFile, defaultFile df: URL = defaultFile) throws {
        try NokPaths.ensure(folder(contents))
        let tag: String, keys: [Mapping]
        switch c {
        case .followDefault: tag = "default"; keys = defaultLayout(file: df, layoutsFile: lf)?.mappings ?? []
        case .normal: tag = "none"; keys = []
        case .own: tag = "own"; keys = own
        case .layout(let id): tag = id; keys = layouts(file: lf).first { $0.id == id }?.mappings ?? []
        case .sameAsLauncher:
            try? FileManager.default.removeItem(at: layoutFile(contents)); try save([], contents: contents); return
        }
        try Data((tag + "\n").utf8).write(to: layoutFile(contents), options: .atomic)
        try save(keys, contents: contents)
    }

    /// The keys an environment has now.
    public static func keys(contents: URL) -> [Mapping] { load(contents: contents) }

    /// Writes each environment's keys again from its layout or the default (after a layout or the default changed,
    /// and at start for games added since). Returns how many changed.
    @discardableResult
    public static func refresh(environments: [URL], shared: [URL] = [], file lf: URL = layoutsFile, defaultFile df: URL = defaultFile) -> Int {
        let all = layouts(file: lf), fallback = defaultLayout(layouts: all, file: df, layoutsFile: lf)?.mappings ?? []
        let sharedSet = Set(shared)
        var n = 0
        for c in Set(environments).union(sharedSet) {
            let want: [Mapping]
            switch choice(contents: c, shared: sharedSet.contains(c)) {
            case .followDefault:
                want = fallback
                // Recorded, so keys written here aren't mistaken later for keys of its own.
                if !FileManager.default.fileExists(atPath: layoutFile(c).path) {
                    try? NokPaths.ensure(folder(c)); try? Data("default\n".utf8).write(to: layoutFile(c), options: .atomic)
                }
            case .layout(let id): want = all.first { $0.id == id }?.mappings ?? fallback
            case .normal: want = []
            case .own, .sameAsLauncher: continue
            }
            if load(contents: c) != want { try? save(want, contents: c); n += 1 }
        }
        return n
    }

    /// Saves a new or edited layout and updates every environment using it (directly or as the default).
    @discardableResult
    public static func store(_ layout: Layout, environments: [URL], shared: [URL] = [], file: URL = layoutsFile, defaultFile df: URL = defaultFile) throws -> Int {
        var all = layouts(file: file)
        if let i = all.firstIndex(where: { $0.id == layout.id }) { all[i] = layout } else { all.append(layout) }
        try saveLayouts(all, file: file)
        return refresh(environments: environments, shared: shared, file: file, defaultFile: df)
    }

    /// Makes a layout the default for every game that hasn't been given keys of its own (nil: no default).
    public static func setDefault(_ layout: Layout?, environments: [URL], shared: [URL] = [], file df: URL = defaultFile, layoutsFile lf: URL = layoutsFile) throws {
        if let layout {
            try NokPaths.ensure(df.deletingLastPathComponent())
            try Data((layout.id + "\n").utf8).write(to: df, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: df)
        }
        refresh(environments: environments, shared: shared, file: lf, defaultFile: df)
    }

    /// Removes a layout. Games that used it keep its keys as their own; if it was the default, there's none.
    public static func delete(_ layout: Layout, environments: [URL], shared: [URL] = [], file: URL = layoutsFile, defaultFile df: URL = defaultFile) throws {
        try saveLayouts(layouts(file: file).filter { $0.id != layout.id }, file: file)
        for c in Set(environments).union(shared) where choice(contents: c, shared: shared.contains(c)) == .layout(layout.id) {
            try set(.own, contents: c, own: layout.mappings, file: file, defaultFile: df)
        }
        if defaultLayoutID(file: df) == layout.id { try setDefault(nil, environments: environments, shared: shared, file: df, layoutsFile: file) }
    }

    /// The Windows environments of these games (each once), and the own folders of games inside launchers.
    public static func environments(_ games: [InstalledGame]) -> [URL] {
        Array(Set(games.compactMap { $0.native == nil ? contents(for: $0) : nil }))
    }
    /// The own folders of games inside launchers (where their keys live when they don't use the launcher's).
    public static func sharedFolders(_ games: [InstalledGame]) -> [URL] { games.filter(isShared).map(\.contents) }

    // MARK: Games inside shared launchers

    static func routesFile(_ host: URL) -> URL { folder(host).appendingPathComponent("key-remap.tsv") }

    /// For each launcher, which of its programs use a game's own keys: "program.exe<TAB>/…/Game.app/…/key-remap",
    /// from the launcher's list of each game's programs (app-names.tsv). The helper in each program reads it.
    @discardableResult
    public static func refreshRoutes(_ games: [InstalledGame]) -> Int {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var changed = 0
        var byHost: [URL: [InstalledGame]] = [:]
        for g in games where isShared(g) { if let h = contents(for: g) { byHost[h, default: []].append(g) } }
        for (host, members) in byHost {
            let names = (try? String(contentsOf: folder(host).appendingPathComponent("app-names.tsv"), encoding: .utf8)) ?? ""
            var lines: [String] = []
            for line in names.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, let g = members.first(where: { key($0.name) == key(parts[1]) }),
                      choice(contents: g.contents, shared: true) != .sameAsLauncher else { continue }
                lines.append(parts[0] + "\t" + file(g.contents).path)
            }
            let text = lines.sorted().joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
            let f = routesFile(host)
            if lines.isEmpty {
                if FileManager.default.fileExists(atPath: f.path) { try? FileManager.default.removeItem(at: f); changed += 1 }
            } else if (try? String(contentsOf: f, encoding: .utf8)) != text {
                try? NokPaths.ensure(folder(host)); try? Data(text.utf8).write(to: f, options: .atomic); changed += 1
            }
        }
        return changed
    }

    // MARK: A keyboard left remapped

    static var activeMarker: URL { NokPaths.support.appendingPathComponent("key-remap-active") }

    /// The game that remapped the keyboard is gone (it crashed or was force-quit) but its mapping is still on:
    /// put back the mapping that was there before. Cheap when nothing is remapped (one stat). Call off the main thread.
    @discardableResult
    public static func recoverIfStale() -> Bool {
        guard let text = try? String(contentsOf: activeMarker, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let pid = lines.first.flatMap({ Int32($0) }) else { try? FileManager.default.removeItem(at: activeMarker); return false }
        if pid > 1, kill(pid, 0) == 0 { return false }
        let previous = lines.count > 1 && lines[1].hasPrefix("[") ? String(lines[1]) : "[]"
        _ = try? Shell.run("/usr/bin/hidutil", ["property", "--set", "{\"UserKeyMapping\":\(previous)}"], timeout: 10)
        try? FileManager.default.removeItem(at: activeMarker)
        return true
    }
    public static func save(_ m: [Mapping], contents: URL) throws {
        let clean = m.filter { $0.to != $0.from }
        if clean.isEmpty { try? FileManager.default.removeItem(at: file(contents)); return }
        try NokPaths.ensure(folder(contents))
        try Data(text(clean).utf8).write(to: file(contents), options: .atomic)
    }

    // MARK: Importing Karabiner-Elements

    public struct KarabinerProfile: Identifiable, Equatable, Sendable {
        public var name: String
        public var selected: Bool
        public var mappings: [Mapping]
        /// Rules Nokcandu can't copy (complex modifications, mouse buttons, consumer keys…).
        public var skipped: Int
        public var id: String { name }
    }

    public static var karabinerConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/karabiner/karabiner.json")
    }

    /// Karabiner-Elements is installed (its settings can stay behind after it's removed, so the app itself is checked).
    public static var karabinerInstalled: Bool {
        ["/Applications/Karabiner-Elements.app", NSHomeDirectory() + "/Applications/Karabiner-Elements.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    public static func karabinerProfiles(_ url: URL = karabinerConfig) -> [KarabinerProfile] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = json["profiles"] as? [[String: Any]] else { return [] }
        func code(_ side: [String: Any]?) -> Int?? {
            guard let side else { return nil }
            if let k = side["key_code"] as? String, k == "vk_none" { return .some(nil) }
            if let k = side["key_code"] as? String { return keys.first { $0.karabiner == k }.map { .some($0.code) } }
            if let k = side["apple_vendor_top_case_key_code"] as? String, k == "keyboard_fn" { return .some(63) }
            return nil
        }
        return profiles.map { p in
            var mappings: [Mapping] = [], skipped = 0
            var simple = (p["simple_modifications"] as? [[String: Any]]) ?? []
            // Modifications for one keyboard are included too (all keyboards are treated alike in games).
            for d in (p["devices"] as? [[String: Any]]) ?? [] { simple += (d["simple_modifications"] as? [[String: Any]]) ?? [] }
            for s in simple {
                let from = code(s["from"] as? [String: Any])
                let toList = s["to"] as? [[String: Any]] ?? []
                let to: Int?? = toList.isEmpty ? .some(nil) : toList.count == 1 ? code(toList[0]) : nil
                guard let f = from ?? nil, let t = to else { skipped += 1; continue }
                if !mappings.contains(where: { $0.from == f }) { mappings.append(Mapping(from: f, to: t)) }
            }
            skipped += ((p["complex_modifications"] as? [String: Any])?["rules"] as? [Any])?.count ?? 0
            return KarabinerProfile(name: p["name"] as? String ?? "Profile", selected: p["selected"] as? Bool ?? false,
                                    mappings: mappings, skipped: skipped)
        }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
