import Foundation
import CoreGraphics

/// Hot corners switched off by a game (see rawmouse.m) — restored here if that game is gone.
public enum HotCorners {
    static var savedFile: URL { NokPaths.support.appendingPathComponent("hot-corners-saved") }

    struct Saved: Equatable { var pid: Int32; var corners: [(action: Int32, modifier: Int32)]
        static func == (a: Saved, b: Saved) -> Bool { a.pid == b.pid && a.corners.map { "\($0.action)/\($0.modifier)" } == b.corners.map { "\($0.action)/\($0.modifier)" } }
    }

    static func parse(_ text: String) -> Saved? {
        let lines = text.split(separator: "\n").map { $0.split(separator: " ").compactMap { Int32($0) } }
        guard lines.count >= 5, lines[0].count == 1, lines[1...4].allSatisfy({ $0.count == 2 }) else { return nil }
        return Saved(pid: lines[0][0], corners: lines[1...4].map { ($0[0], $0[1]) })
    }

    /// Puts the hot corners back if the game that switched them off has quit or crashed.
    public static func recoverIfStale() {
        guard let text = try? String(contentsOf: savedFile, encoding: .utf8) else { return }
        guard let saved = parse(text) else { try? FileManager.default.removeItem(at: savedFile); return }
        if kill(saved.pid, 0) == 0 { return }                 // still running: it restores them itself
        typealias Set = @convention(c) (Int32, Int32, Int32) -> Void
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(h, "CoreDockSetExposeCornerActionWithModifier") else { return }
        let set = unsafeBitCast(sym, to: Set.self)
        for (i, c) in saved.corners.enumerated() where c.action > 1 && c.modifier == 0 { set(c.action, Int32(i), c.modifier) }
        try? FileManager.default.removeItem(at: savedFile)
    }
}

/// Leftover game processes: a game that didn't quit properly keeps running with no window, and its
/// launcher (Battle.net, Steam) then refuses to start it again ("already running").
public enum StuckGames {
    public struct Process: Equatable { public var pid: Int32; public var program: String; public var seconds: Int }

    /// Programs (lower-cased .exe names) that belong to this game.
    public static func programs(of g: InstalledGame) -> Set<String> {
        var out = Set<String>()
        if let exe = g.custom?.exe, g.custom?.source != .steamLibrary {
            out.insert(String(exe.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(exe)).lowercased())
        }
        if let h = WineTools.hostContents(for: g),
           let text = try? String(contentsOf: h.appendingPathComponent("SharedSupport/nokcandu/app-names.tsv"), encoding: .utf8) {
            let name = g.battleNet?.name ?? g.name
            for line in text.split(separator: "\n") {
                let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if p.count == 2, p[1] == name { out.insert(p[0].lowercased()) }
            }
        }
        out.subtract(["steam.exe", "steamwebhelper.exe", "battle.net.exe", "agent.exe", "explorer.exe"])
        return out.filter { $0.hasSuffix(".exe") }
    }

    /// "[[dd-]hh:]mm:ss" → seconds.
    static func seconds(_ etime: String) -> Int {
        var days = 0, rest = Substring(etime)
        if let d = etime.firstIndex(of: "-") { days = Int(etime[..<d]) ?? 0; rest = etime[etime.index(after: d)...] }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        return days * 86400 + parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Running Wine processes of this game (from `ps -axo pid=,etime=,command=` output).
    static func matching(_ ps: String, programs: Set<String>) -> [Process] {
        guard !programs.isEmpty else { return [] }
        var out: [Process] = []
        for line in ps.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]) else { continue }
            let cmd = String(f[2])
            guard cmd.count > 3, cmd.dropFirst().hasPrefix(":") else { continue }      // a Windows path: "D:\…"
            let lower = cmd.lowercased()
            guard let prog = programs.first(where: { lower.contains("\\" + $0) || lower.contains("/" + $0) }) else { continue }
            out.append(Process(pid: pid, program: prog, seconds: seconds(String(f[1]))))
        }
        return out
    }

    static func pidsWithWindows() -> Set<Int32> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { w -> Int32? in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: Any],
                  (b["Width"] as? Double ?? 0) > 50 else { return nil }
            return w[kCGWindowOwnerPID as String] as? Int32
        })
    }

    /// All of this game's running Windows programs.
    public static func running(_ g: InstalledGame) -> [Process] {
        let progs = programs(of: g)
        guard !progs.isEmpty, let r = try? Shell.run("/bin/ps", ["-axo", "pid=,etime=,command="], timeout: 10) else { return [] }
        return matching(r.stdout, programs: progs)
    }

    /// This game's processes that have been running for a while with no window — stuck.
    public static func stuck(_ g: InstalledGame, minimumSeconds: Int = 45) -> [Process] {
        let progs = programs(of: g)
        guard !progs.isEmpty, let r = try? Shell.run("/bin/ps", ["-axo", "pid=,etime=,command="], timeout: 10) else { return [] }
        let windows = pidsWithWindows()
        return matching(r.stdout, programs: progs).filter { $0.seconds >= minimumSeconds && !windows.contains($0.pid) }
    }

    /// Ends stuck processes (Wine cleans up after them). Returns how many were ended.
    @discardableResult
    public static func end(_ list: [Process]) -> Int {
        var n = 0
        for p in list where kill(p.pid, SIGKILL) == 0 { n += 1 }
        if n > 0 { usleep(1_500_000) }                          // let Wine and the launcher notice
        return n
    }
}
