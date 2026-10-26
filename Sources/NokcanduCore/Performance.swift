import Foundation

/// Per-app performance switches: on-screen FPS counter, vsync and a frame-rate limit. Written as a
/// small shell file (SharedSupport/nokcandu/perf.env) that the game's launcher — or for Steam games the
/// shared Steam — reads after the graphics mode. Takes effect the next time the game (or Steam) starts.
public enum Performance {
    public struct Settings: Codable, Hashable {
        public var fpsCounter = false
        public var vsync = false
        public var fpsLimit = 0                      // 0 = no limit
        /// Overlay style: "fps" (one line), "graph" (FPS + frame-time graph) or "full". nil = "graph".
        public var hud: String? = nil
        /// Overlay size: "small", "medium" or "large" (nil = small).
        public var hudSize: String? = nil
        public init() {}
        public static let hudSizes = ["small", "medium", "large"]
        public static let hudStyles = ["fps", "graph", "full"]
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
            let style = s.hud ?? "graph"
            let metal = style == "fps" ? "fps" : style == "graph" ? "fps,frameinterval,frameintervalgraph,gputime" : ""
            let dxvk = style == "fps" ? "fps" : style == "graph" ? "fps,frametimes" : "full"
            let size = s.hudSize ?? "small"
            let metalScale = size == "small" ? "0.1" : size == "medium" ? "0.15" : "0.25"
            let dxvkScale = size == "small" ? "0.6" : size == "medium" ? "0.8" : "1.0"
            out += #"if [ -n "${WINEDLLPATH_D3DMETAL:-}" ]; then export MTL_HUD_ENABLED=1; export MTL_HUD_SCALE=\#(metalScale)"#
            if !metal.isEmpty { out += #"; export MTL_HUD_ELEMENTS="\#(metal)""# }
            out += #"; else export DXVK_HUD="\#(dxvk),scale=\#(dxvkScale)"; fi"# + "\n"
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
