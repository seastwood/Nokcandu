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

    /// Rewrites the Battle.net app's program → renderer list from its games' choices.
    public static func writeMap(host h: InstalledGame, games: [InstalledGame]) throws {
        let support = h.contents.appendingPathComponent("SharedSupport").path, contents = h.contents.path
        var lines: [String] = []
        for g in games where g.battleNet?.hostApp == h.appURL.path {
            guard let p = choice(g), let exe = program(g, host: h) else { continue }
            let env = p.programEnvironment(support: support, contents: contents)
            lines.append(([exe] + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "\t"))
        }
        let f = h.contents.appendingPathComponent("SharedSupport/nokcandu/\(mapName)")
        if lines.isEmpty { try? FileManager.default.removeItem(at: f); return }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: f, options: .atomic)
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
