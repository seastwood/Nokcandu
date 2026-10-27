import CoreGraphics
import Foundation

/// "Game resolution": while a game runs, the Mac's display switches to a 1× mode with exactly the chosen
/// number of pixels, and the game uses Fullscreen Windowed — which then matches the screen, so nothing
/// switches while you play. The bundled `screen-size` tool does the switching and puts the desktop back
/// when the game quits. (Wine's Retina mode isn't used: it mis-sizes game windows when they're recreated.)
public enum GameDisplay {
    public struct Resolution: Hashable, Identifiable {
        public var width: Int, height: Int
        public var retina: Bool          // a 2× mode exists (desktop looks normal-sized while playing)
        public var id: String { "\(width)x\(height)" }
        public var pixels: [Int] { [width, height] }
    }

    /// Classic sizes for old games, offered as Wine's virtual screen (no Mac display has most of them).
    public static let classicSizes: [[Int]] = [[640, 480], [800, 600], [1024, 768], [1152, 864], [1280, 960], [1280, 1024], [1600, 1200]]

    /// Resolutions the main display can run, largest first.
    public static func resolutions() -> [Resolution] {
        let d = CGMainDisplayID()
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = ((CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []).filter { $0.isUsableForDesktopGUI() }
        // Larger "looks like" modes are drawn bigger than the panel and shrunk onto it — never worth it for a game.
        let native = modes.filter { $0.width == $0.pixelWidth }.map { $0.pixelWidth * $0.pixelHeight }.max() ?? Int.max
        var out: [String: Resolution] = [:]
        for m in modes where m.pixelWidth * m.pixelHeight <= native && m.width == m.pixelWidth {
            let k = "\(m.pixelWidth)x\(m.pixelHeight)"
            let r = m.width * 2 == m.pixelWidth
            if var e = out[k] { e.retina = e.retina || r; out[k] = e }
            else { out[k] = Resolution(width: m.pixelWidth, height: m.pixelHeight, retina: r) }
        }
        return out.values.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// A regex for the game's process that can't match the tool's own command line (first letter in [ ]).
    public static func watchPattern(exeName: String) -> String {
        let e = NSRegularExpression.escapedPattern(for: exeName.lowercased())
        guard let f = e.first, f.isLetter || f.isNumber else { return e }
        return "[\(f)]" + e.dropFirst()
    }
    /// Any Steam game's process ("…\steamapps\common\…"). The class needs `\\` — inside [ ] a single
    /// backslash only escapes the next character in the tool's (ICU) regex, so `[\/]` matched just "/".
    public static let steamGamePattern = #"steamapps[\\/]common"#

    /// Launcher lines that start the switcher in the background (it outlives the launcher).
    static func launcherLines(_ pixels: [Int]?, tool: String, log: String, pattern: String) -> String {
        guard let p = pixels, p.count == 2 else { return "" }
        let q = CustomGames.shellQuote
        return """
        # Game resolution (Nokcandu → Display): the Mac's screen runs at \(p[0])×\(p[1]) while the game does.
        if [ -x \(tool) ]; then
         ( trap '' HUP; unset DYLD_INSERT_LIBRARIES; exec \(tool) --play \(p[0]) \(p[1]) --watch \(q(pattern)) ) </dev/null >>\(log) 2>&1 &
         disown $! 2>/dev/null || true
        fi

        """
    }

    // MARK: Wine Retina mode (per app)

    static func reg(_ prefix: URL, _ name: String) -> URL { prefix.appendingPathComponent(name) }

    public static func retinaOn(prefix: URL) -> Bool {
        ((try? String(contentsOf: reg(prefix, "user.reg"), encoding: .utf8)) ?? "").contains("\"RetinaMode\"=\"y\"")
    }

    /// Turns Wine's Retina mode on or off for one app's Windows environment (the app must not be running).
    /// With it on, Windows text and windows are drawn at 200% so programs like Steam keep their size.
    public static func setRetina(_ on: Bool, prefix: URL) throws {
        let u = reg(prefix, "user.reg"), s = reg(prefix, "system.reg")
        var user = try String(contentsOf: u, encoding: .utf8)
        var system = (try? String(contentsOf: s, encoding: .utf8)) ?? ""
        let dpiOld = on ? "\"LogPixels\"=dword:00000060" : "\"LogPixels\"=dword:000000c0"
        let dpiNew = on ? "\"LogPixels\"=dword:000000c0" : "\"LogPixels\"=dword:00000060"
        user = user.replacingOccurrences(of: dpiOld, with: dpiNew)
        system = system.replacingOccurrences(of: dpiOld, with: dpiNew)
        user = user.replacingOccurrences(of: "\"RetinaMode\"=\"y\"\n", with: "")
        if on {
            let header = "[Software\\\\Wine\\\\Mac Driver]"
            if let r = user.range(of: header) {
                // Insert after the section's header line (and its #time line, if any).
                var end = user[r.upperBound...].firstIndex(of: "\n").map { user.index(after: $0) } ?? user.endIndex
                if user[end...].hasPrefix("#time=") { end = user[end...].firstIndex(of: "\n").map { user.index(after: $0) } ?? user.endIndex }
                user.insert(contentsOf: "\"RetinaMode\"=\"y\"\n", at: end)
            } else {
                user += "\n\(header) 0\n\"RetinaMode\"=\"y\"\n"
            }
        }
        try Data(user.utf8).write(to: u, options: .atomic)
        if !system.isEmpty { try Data(system.utf8).write(to: s, options: .atomic) }
    }

    /// Runs the game on a Wine virtual screen of this size (nil = off). Turns off display switching.
    public static func applyVirtualScreen(_ size: [Int]?, to g: InstalledGame) throws {
        guard var c = g.custom, !g.usesSharedSteam else { return }
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit the game first.") }
        c.virtualScreen = size
        if size != nil { c.displayPixels = nil }
        try CustomGames.saveAll(c, to: g, force: false)
    }

    /// Saves a game's resolution choice and makes its Windows environment match.
    public static func apply(_ pixels: [Int]?, to g: InstalledGame, library: [InstalledGame]) throws {
        guard var c = g.custom else { return }
        let steam = g.usesSharedSteam
        var busy = steam && SharedSteam.isRunning
        if !steam, case .launcherRunning = GameLauncher.runState(of: g) { busy = true }
        if busy {
            throw NokError(steam ? "Quit Steam first (Steam page → Quit Steam)." : "Quit the game first.")
        }
        c.displayPixels = pixels
        c.virtualScreen = nil
        try CustomGames.saveAll(c, to: g, force: false)
        // Undo Retina mode from earlier test builds: it made game windows the wrong size.
        if let prefix = WineTools.hostContents(for: g)?.appendingPathComponent("SharedSupport/prefix"), retinaOn(prefix: prefix) {
            try setRetina(false, prefix: prefix)
        }
    }
}
