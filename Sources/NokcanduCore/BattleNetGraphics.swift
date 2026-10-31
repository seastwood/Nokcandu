import Foundation

/// Graphics per Battle.net game. Battle.net starts its games itself, so they inherit Battle.net's environment;
/// Nokcandu's helper library re-selects the renderer for each game's own program as it starts
/// (program-renderers.tsv in the Battle.net app, read by browser-renderer.h). The choice lives in the game's app.
/// The renderer's DLL search path and overrides apply this way; settings a renderer reads from the Windows
/// environment (DXVK_CONFIG and the like) keep Battle.net's values.
public enum BattleNetGraphics {
    static func file(_ g: InstalledGame) -> URL { g.contents.appendingPathComponent("SharedSupport/nokcandu/graphics") }
    static let mapName = "program-renderers.tsv"

    /// nil = same as the Battle.net app.
    public static func choice(_ g: InstalledGame) -> GraphicsPreset? {
        (try? String(contentsOf: file(g), encoding: .utf8)).flatMap { GraphicsPreset(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func host(of g: InstalledGame, in games: [InstalledGame]) -> InstalledGame? {
        games.first { $0.appURL.path == g.battleNet?.hostApp }
    }

    public static func set(_ p: GraphicsPreset?, for g: InstalledGame, games: [InstalledGame]) throws {
        let f = file(g)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let p { try Data(p.rawValue.utf8).write(to: f, options: .atomic) } else { try? FileManager.default.removeItem(at: f) }
        if let h = host(of: g, in: games) { try writeMap(host: h, games: games) }
    }

    /// The game's program name (e.g. D2R.exe), from Battle.net's install records.
    static func program(_ g: InstalledGame, host: InstalledGame) -> String? {
        guard let uid = g.battleNet?.uid,
              let exe = BattleNet.installedGames(host: host).first(where: { $0.uid.lowercased() == uid.lowercased() })?.exe else { return nil }
        let name = exe.replacingOccurrences(of: "\"", with: "").split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
        return name.flatMap { $0.split(separator: ",").first.map(String.init) }     // "D2R.exe,0" icon index
    }

    /// Rewrites the Battle.net app's program list from its games' choices (graphics and virtual screen size).
    public static func writeMap(host h: InstalledGame, games: [InstalledGame]) throws {
        for g in games where g.battleNet?.hostApp == h.appURL.path {
            guard let exe = program(g, host: h) else { continue }
            try ProgramSettings.update(launcher: h.contents, key: exe, graphics: choice(g), game: g)
        }
    }
}

/// program-renderers.tsv in a launcher app (Battle.net, Steam): each game's own graphics mode and virtual screen
/// size, applied by the helper library as the launcher starts the game — no launcher restart to switch games.
public enum ProgramSettings {
    static func file(_ launcher: URL) -> URL { launcher.appendingPathComponent("SharedSupport/nokcandu/program-renderers.tsv") }

    public static func update(launcher: URL, key: String, graphics: GraphicsPreset?, game: InstalledGame) throws {
        let support = launcher.appendingPathComponent("SharedSupport").path
        var fields: [String] = []
        if let p = graphics {
            fields += p.programEnvironment(support: support, contents: launcher.path).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        if let size = WindowedPresentation.setting(for: game), size != WindowedPresentation.automatic, size.count == 2 {
            fields.append("NOKCANDU_VIRTUAL_SCREEN=\(size[0])x\(size[1])")
        }
        let f = file(launcher)
        var lines = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            .filter { $0.split(separator: "\t").first.map(String.init)?.lowercased() != key.lowercased() }
        if !fields.isEmpty { lines.append(([key] + fields).joined(separator: "\t")) }
        if lines.isEmpty { try? FileManager.default.removeItem(at: f); return }
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: f, options: .atomic)
    }

    /// Before a game starts (or its settings change): its line in its launcher's list.
    public static func refresh(_ g: InstalledGame, games: [InstalledGame]) {
        if g.battleNet != nil, let h = BattleNetGraphics.host(of: g, in: games) {
            try? BattleNetGraphics.writeMap(host: h, games: games)
        } else if g.usesSharedSteam, let c = g.custom, let id = c.steamAppID {
            try? update(launcher: SharedSteam.appURL.appendingPathComponent("Contents"), key: "steam:\(id)", graphics: c.graphics, game: g)
        }
    }
}

extension GraphicsPreset {
    /// The renderer's launcher variables with paths filled in (for a program started by another program).
    /// Variables that only take effect when a process starts (dyld's) are left out.
    func programEnvironment(support: String, contents: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in launcherExports {
            var l = line
            if l.hasPrefix("[ -f "), let r = l.range(of: "&& ") {
                let test = String(l[l.index(l.startIndex, offsetBy: 5)..<r.lowerBound]).replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "$SUPPORT", with: support)
                guard FileManager.default.fileExists(atPath: test) else { continue }
                l = String(l[r.upperBound...])
            }
            guard l.hasPrefix("export "), let eq = l.firstIndex(of: "=") else { continue }
            let key = String(l[l.index(l.startIndex, offsetBy: 7)..<eq])
            var value = String(l[l.index(after: eq)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            value = value.replacingOccurrences(of: "${DXMT_CONFIG:+$DXMT_CONFIG;}", with: "")
                .replacingOccurrences(of: "$SUPPORT", with: support).replacingOccurrences(of: "$CONTENTS", with: contents)
            guard !key.hasPrefix("DYLD_"), !value.contains("$"), !value.contains("\t"), !value.contains("\n") else { continue }
            out[key] = value
        }
        return out
    }
}
