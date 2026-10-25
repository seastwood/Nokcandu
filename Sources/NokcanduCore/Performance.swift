import Foundation

/// Per-app performance switches: on-screen FPS counter, vsync and a frame-rate limit. Written as a
/// small shell file (SharedSupport/nokcandu/perf.env) that the game's launcher — or for Steam games the
/// shared Steam — reads after the graphics mode. Takes effect the next time the game (or Steam) starts.
public enum Performance {
    public struct Settings: Codable, Equatable {
        public var fpsCounter = false
        public var vsync = false
        public var fpsLimit = 0                      // 0 = no limit
        public init() {}
        public var isDefault: Bool { self == Settings() }
    }

    static func folder(_ h: URL) -> URL { h.appendingPathComponent("SharedSupport/nokcandu", isDirectory: true) }

    public static func settings(for g: InstalledGame) -> Settings {
        guard let h = WineTools.hostContents(for: g),
              let d = try? Data(contentsOf: folder(h).appendingPathComponent("perf.json")),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }

    /// The perf.env text. DXVK modes (Classic/Modern 3D) use DXVK's own HUD, vsync and limiter; Apple
    /// Metal uses Apple's Metal HUD (its frame limit and vsync aren't controllable from outside).
    static func envText(_ s: Settings) -> String {
        var out = "# Written by Nokcandu → Performance. Change it there, not here.\n"
        if s.fpsCounter {
            out += #"if [ -n "${WINEDLLPATH_D3DMETAL:-}" ]; then export MTL_HUD_ENABLED=1; else export DXVK_HUD="fps,frametimes"; fi"# + "\n"
        }
        if s.vsync {
            out += #"export DXVK_CONFIG="${DXVK_CONFIG:+$DXVK_CONFIG; }d3d9.presentInterval = 1; dxgi.syncInterval = 1""# + "\n"
        }
        if s.fpsLimit > 0 { out += "export DXVK_FRAME_RATE=\(s.fpsLimit)\n" }
        return out
    }

    public static func apply(_ s: Settings, for g: InstalledGame) throws {
        guard let h = WineTools.hostContents(for: g) else { throw NokError("This game has no Windows environment.") }
        let f = folder(h)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: f.appendingPathComponent("perf.json"), options: .atomic)
        if s.isDefault {
            try? FileManager.default.removeItem(at: f.appendingPathComponent("perf.env"))
        } else {
            try Data(envText(s).utf8).write(to: f.appendingPathComponent("perf.env"), options: .atomic)
        }
    }
}
