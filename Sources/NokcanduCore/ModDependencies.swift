import Foundation

/// Mods for Battlefield 1942–style games (Refractor engine: BF1942, Battlefield Vietnam and their mods) list the
/// other mods they build on in `Mods/<mod>/init.con` (`game.addModPath Mods/FH/`). A missing one isn't reported by
/// the game: it crashes while loading, usually with a page fault in the game's own program. This finds them first.
public enum ModDependencies {
    public struct Missing: Hashable, Sendable {
        /// The mod's folder name (what `+game` takes), e.g. "FHSW".
        public var mod: String
        /// The folders it needs that aren't there, e.g. ["FH"].
        public var needs: [String]
        public var needsNames: [String] { needs.map(ModDependencies.displayName) }
        public var message: String {
            "\(mod) needs \(needs.map { "\(ModDependencies.displayName($0)) (Mods/\($0))" }.joined(separator: " and ")), which \(needs.count == 1 ? "isn't" : "aren't") installed. Install \(needs.count == 1 ? "it" : "them") into the game's Mods folder; without \(needs.count == 1 ? "it" : "them") the game crashes while loading \(mod)."
        }
    }

    /// Known mods' full names, for messages. Anything else is shown by its folder name.
    static let names: [String: String] = [
        "fh": "Forgotten Hope", "fh2": "Forgotten Hope 2", "xpack1": "The Road to Rome", "xpack2": "Secret Weapons of WWII",
        "desertcombat": "Desert Combat", "dc_final": "Desert Combat", "eod": "Eve of Destruction", "bfvietnam": "Battlefield Vietnam",
        "bf1942": "Battlefield 1942", "galacticconquest": "Galactic Conquest", "pirates": "Pirates", "interstate": "Interstate",
    ]
    static func displayName(_ folder: String) -> String { names[folder.lowercased()] ?? folder }

    /// The folder holding `Mods/` for this game, if it is a Refractor-engine game.
    public static func gameRoot(_ g: InstalledGame) -> URL? {
        guard let program = CompatibilityFixes.programForFixes(g) else { return nil }
        var dir = program.deletingLastPathComponent()
        // A launcher or wrapper one level down (e.g. a borderless helper folder) still belongs to the same game.
        for _ in 0..<2 {
            if child(of: dir, named: "Mods") != nil { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Every installed mod with a dependency that isn't installed.
    public static func missing(_ g: InstalledGame) -> [Missing] {
        guard let root = gameRoot(g) else { return [] }
        return missing(root: root)
    }

    public static func missing(root: URL) -> [Missing] {
        guard let mods = child(of: root, named: "Mods") else { return [] }
        let folders = ((try? FileManager.default.contentsOfDirectory(at: mods, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var out: [Missing] = []
        for mod in folders.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let initFile = child(of: mod, named: "init.con"),
                  let data = try? Data(contentsOf: initFile), data.count < 1_000_000 else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var needs: [String] = []
            for path in modPaths(in: text) {
                // Only paths inside Mods/ are checked; the mod's own folder doesn't count.
                let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
                guard parts.count >= 2, parts[0].lowercased() == "mods" else { continue }
                let name = parts[1]
                guard name.lowercased() != mod.lastPathComponent.lowercased(), child(of: mods, named: name) == nil,
                      !needs.contains(where: { $0.lowercased() == name.lowercased() }) else { continue }
                needs.append(name)
            }
            if !needs.isEmpty { out.append(Missing(mod: mod.lastPathComponent, needs: needs)) }
        }
        return out
    }

    /// The mod a launch starts (`+game FHSW`), if its options name one.
    public static func launchedMod(arguments: String) -> String? {
        let parts = CustomGames.splitArguments(arguments)
        guard let i = parts.firstIndex(where: { $0.lowercased() == "+game" }), i + 1 < parts.count else { return nil }
        return parts[i + 1]
    }

    /// Paths from `game.addModPath` lines (case-insensitive, comments and quotes ignored).
    static func modPaths(in text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.lowercased().hasPrefix("rem"), line.lowercased().hasPrefix("game.addmodpath") else { return nil }
            let rest = line.dropFirst("game.addmodpath".count).trimmingCharacters(in: .whitespaces)
            let path = rest.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
            return path.isEmpty ? nil : path
        }
    }

    /// Windows file names are case-insensitive; so is Wine. Find `name` in `dir` the same way.
    public static func child(of dir: URL, named name: String) -> URL? {
        let exact = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        let lower = name.lowercased()
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .first { $0.lowercased() == lower }.map { dir.appendingPathComponent($0) }
    }
}
