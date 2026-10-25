import Foundation

/// "Raw mouse for aiming": a small library (Resources/rawmouse) that Wine loads at start. While a game
/// is in mouse-look it feeds the game the mouse's own movement (hundreds of updates a second, no macOS
/// acceleration) instead of Wine's pointer-derived moves. The switch lives with the app that owns the
/// Wine engine — for Steam games that's the shared Steam, so it applies to all of them.
public enum RawMouse {
    public static let dylibName = "nokcandu-rawmouse.dylib"

    public struct Settings: Equatable {
        public var enabled: Bool
        public var scale: Double
        public init(enabled: Bool, scale: Double) { self.enabled = enabled; self.scale = scale }
    }

    static func folder(_ host: URL) -> URL { host.appendingPathComponent("SharedSupport/nokcandu", isDirectory: true) }
    static func flag(_ host: URL) -> URL { folder(host).appendingPathComponent("raw-mouse") }

    public static func settings(for g: InstalledGame) -> Settings {
        guard let h = WineTools.hostContents(for: g) else { return Settings(enabled: false, scale: 1) }
        guard let text = try? String(contentsOf: flag(h), encoding: .utf8) else { return Settings(enabled: false, scale: 1) }
        let s = Double(text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") ?? 1
        return Settings(enabled: true, scale: s)
    }

    public static var bundledLibrary: URL? { NokPaths.bundledResource(dylibName) }

    /// Turns it on (copying the current library into the app) or off. Takes effect the next time the
    /// game — or for Steam games, Steam — starts.
    public static func apply(_ s: Settings, for g: InstalledGame) throws {
        guard let h = WineTools.hostContents(for: g) else { throw NokError("This game has no Windows environment.") }
        let fm = FileManager.default
        try fm.createDirectory(at: folder(h), withIntermediateDirectories: true)
        if s.enabled {
            guard let lib = bundledLibrary else { throw NokError("Nokcandu's raw-mouse library is missing; rebuild Nokcandu.") }
            let dst = folder(h).appendingPathComponent(dylibName)
            if (try? Hashing.sha256(file: dst)) != (try? Hashing.sha256(file: lib)) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: lib, to: dst)
            }
            let scale = min(max(s.scale, 0.1), 10)
            try Data(String(format: "%.2f\n", scale).utf8).write(to: flag(h), options: .atomic)
        } else {
            try? fm.removeItem(at: flag(h))
        }
    }

    /// Keeps the copied library current after Nokcandu is rebuilt (called on refresh).
    public static func refreshLibraries(_ games: [InstalledGame]) {
        guard let lib = bundledLibrary, let want = try? Hashing.sha256(file: lib) else { return }
        for g in games where !g.usesSharedSteam {
            guard let h = WineTools.hostContents(for: g), FileManager.default.fileExists(atPath: flag(h).path) else { continue }
            let dst = folder(h).appendingPathComponent(dylibName)
            if (try? Hashing.sha256(file: dst)) != want {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: lib, to: dst)
            }
        }
    }

    /// What the library said in the last run (it logs "nokcandu-rawmouse: …" lines to the game's log).
    public static func lastStatus(for g: InstalledGame) -> String? {
        guard let h = WineTools.hostContents(for: g) else { return nil }
        let log = h.appendingPathComponent(g.usesSharedSteam || g.isSteamHost ? "SharedSupport/Logs/steam.log" : "SharedSupport/Logs/launch.log")
        guard let tail = tailOfFile(log, maxLines: 4000) else { return nil }
        return tail.components(separatedBy: .newlines).last { $0.hasPrefix("nokcandu-rawmouse:") }
            .map { String($0.dropFirst("nokcandu-rawmouse: ".count)) }
    }
}
