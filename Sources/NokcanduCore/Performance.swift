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
        /// Low-latency mode: the graphics layer queues at most one frame ahead (DXVK modes; nil = off).
        public var lowLatency: Bool? = nil
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
            out += #"if [ -n "${WINEDLLPATH_D3DMETAL:-}${WINEDLLPATH_DXMT:-}" ]; then export MTL_HUD_ENABLED=1; export MTL_HUD_SCALE=\#(metalScale)"#
            if !metal.isEmpty { out += #"; export MTL_HUD_ELEMENTS="\#(metal)""# }
            out += #"; else export DXVK_HUD="\#(dxvk),scale=\#(dxvkScale)"; fi"# + "\n"
        }
        if s.vsync {
            out += #"export DXVK_CONFIG="${DXVK_CONFIG:+$DXVK_CONFIG; }d3d9.presentInterval = 1; dxgi.syncInterval = 1""# + "\n"
            // Metal modes (Apple Metal, DXMT): Nokcandu's library makes the game's Metal layer wait for the
            // screen's refresh with at most one frame waiting — no repeated frames, little added delay.
            out += "export NOKCANDU_METAL_VSYNC=1\n"
        }
        if s.fpsLimit > 0 {
            out += "export DXVK_FRAME_RATE=\(s.fpsLimit)\n"
            // DXMT's own limiter paces frames through Metal's presentation timing: evenly spaced frames
            // without vsync's queue of waiting frames.
            out += #"export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}d3d11.preferredMaxFrameRate=\#(s.fpsLimit)""# + "\n"
        }
        if s.lowLatency == true {
            // DXVK renders up to 3 frames ahead by default; with 1, each frame shows input from moments ago.
            out += #"export DXVK_CONFIG="${DXVK_CONFIG:+$DXVK_CONFIG; }dxgi.maxFrameLatency = 1; d3d9.maxFrameLatency = 1""# + "\n"
        }
        return out
    }

    /// Rewrites each game's perf.env from its saved settings when an older Nokcandu wrote it differently
    /// (for example before DXMT got Apple's Metal FPS counter). Runs with the launch maintenance.
    public static func refreshEnvFiles(_ games: [InstalledGame]) {
        var seen = Set<String>()
        for g in games {
            guard let h = WineTools.hostContents(for: g), seen.insert(h.path).inserted else { continue }
            let f = folder(h), env = f.appendingPathComponent("perf.env")
            guard let d = try? Data(contentsOf: f.appendingPathComponent("perf.json")),
                  let s = try? JSONDecoder().decode(Settings.self, from: d), !s.isDefault else { continue }
            let want = Data(envText(s).utf8)
            if (try? Data(contentsOf: env)) != want { try? want.write(to: env, options: .atomic) }
        }
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
