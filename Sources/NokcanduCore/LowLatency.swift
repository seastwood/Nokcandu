import Foundation

/// Two settings for shooters on Valve's engines, both kept in the game's own launch options (so they're
/// visible, editable and travel with shared profiles):
/// - Low-latency aiming: the game's vsync off (the Mac's compositor never tears and always shows the
///   newest frame) and, in CS2, the mouse sampled as late as possible before each frame.
/// - Frame cap (+fps_max): rendering above the screen's refresh keeps every shown frame's input fresh.
public enum LowLatency {
    /// Recommended frame cap: twice the screen's refresh (60 Hz → 120, 120 Hz ProMotion → 240), so every
    /// displayed frame carries recent input. Capped at 240 to keep laptops cool.
    public static func autoFPS(refresh: Int) -> Int { min(max(refresh, 60) * 2, 240) }
    public static let caps = [60, 90, 120, 144, 180, 240, 0]    // 0 = unlimited
    static let cs2 = 730
    static let source1: Set<Int> = [220, 240, 300, 320, 380, 400, 420, 440, 500, 550, 620, 4000]

    public static func supported(_ c: CustomGameConfig) -> Bool {
        guard let id = c.steamAppID else { return false }
        return id == cs2 || source1.contains(id)
    }

    /// The switch's launch options: CS2 samples the mouse right before drawing; Source games turn vsync off
    /// (CS2's vsync lives in its video config instead, see `cs2Vsync`).
    static func marker(appID: Int) -> [String] {
        appID == cs2 ? ["+engine_low_latency_sleep_after_client_tick", "true"] : ["+mat_vsync", "0"]
    }

    static func tokens(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }

    /// Launch options without the given "+cvar value" pairs.
    static func removing(_ names: Set<String>, from args: String) -> [String] {
        let t = tokens(args)
        var out: [String] = [], i = 0
        while i < t.count {
            if names.contains(t[i].lowercased()) {
                i += (i + 1 < t.count && !t[i + 1].hasPrefix("+") && !t[i + 1].hasPrefix("-")) ? 2 : 1
                continue
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    static func value(_ t: [String], _ name: String) -> String? {
        guard let i = t.lastIndex(where: { $0.lowercased() == name }), i + 1 < t.count else { return nil }
        return t[i + 1]
    }

    public static func isOn(_ c: CustomGameConfig) -> Bool {
        guard supported(c), let id = c.steamAppID else { return false }
        let m = marker(appID: id)
        return value(tokens(c.arguments), m[0])?.lowercased() == m[1]
    }

    /// The config with low-latency aiming switched on or off (launch options rewritten).
    public static func set(_ on: Bool, _ c: CustomGameConfig) -> CustomGameConfig {
        guard supported(c), let id = c.steamAppID else { return c }
        let m = marker(appID: id)
        var c = c
        c.arguments = (removing([m[0]], from: c.arguments) + (on ? m : [])).joined(separator: " ")
        return c
    }

    /// The frame cap in the launch options: nil = the game's default, 0 = unlimited.
    public static func cap(_ c: CustomGameConfig) -> Int? {
        guard supported(c) else { return nil }
        return value(tokens(c.arguments), "+fps_max").flatMap { Int($0) }
    }

    public static func setCap(_ fps: Int?, _ c: CustomGameConfig) -> CustomGameConfig {
        guard supported(c) else { return c }
        var c = c
        c.arguments = (removing(["+fps_max"], from: c.arguments) + (fps.map { ["+fps_max", "\($0)"] } ?? [])).joined(separator: " ")
        return c
    }

    /// Saves low-latency aiming: launch options (regenerating the launcher) and, for CS2, its vsync setting.
    public static func apply(_ on: Bool, to g: InstalledGame) throws {
        guard let c = g.custom, supported(c) else { return }
        try CustomGames.saveAll(set(on, c), to: g, force: false)
        if c.steamAppID == cs2 { cs2Vsync(on: !on) }
    }

    public static func applyCap(_ fps: Int?, to g: InstalledGame) throws {
        guard let c = g.custom, supported(c) else { return }
        try CustomGames.saveAll(setCap(fps, c), to: g, force: false)
    }

    /// CS2 keeps vsync in its per-account video config, not on the command line.
    static func cs2Vsync(on: Bool, steamDir: URL = SharedSteam.steamDir) {
        let users = steamDir.appendingPathComponent("userdata")
        for u in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let f = u.appendingPathComponent("730/local/cfg/cs2_video.txt")
            guard var s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let r = s.replacing(#/("setting\.mat_vsync"\s+")\d(")/#) { m in "\(m.output.1)\(on ? 1 : 0)\(m.output.2)" }
            guard r != s else { continue }
            s = r
            try? Data(s.utf8).write(to: f, options: .atomic)
        }
    }
}
