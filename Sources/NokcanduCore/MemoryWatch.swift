import Foundation
import Darwin

/// How much memory a game used while it ran (its physical footprint, what Activity Monitor shows as "Memory"),
/// kept per game so its page can show the last session's peak and point at a lower-memory setup when a game
/// came close to what the Mac has. Samples are cheap (one system call); they're written at most once a minute
/// unless the peak grows noticeably.
public enum MemoryWatch {
    public struct Session: Codable, Equatable, Sendable {
        public var pid: Int32
        public var started: Date
        public var updated: Date
        /// Footprint at the first sample and the highest seen, in bytes.
        public var first: UInt64
        public var peak: UInt64
        public var growth: UInt64 { peak > first ? peak - first : 0 }
    }

    static func url(_ g: InstalledGame) -> URL { g.contents.appendingPathComponent("SharedSupport/nokcandu/memory.json") }

    public static func last(_ g: InstalledGame) -> Session? {
        (try? Data(contentsOf: url(g))).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    /// A process's physical footprint in bytes.
    public static func footprint(pid: Int32) -> UInt64? {
        guard pid > 1 else { return nil }
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// The game's own Windows program (not its launcher script or the store client it was started from).
    static func gameProcess(_ g: InstalledGame) -> Int32? {
        guard g.native == nil, !g.isSteamHost, !BattleNet.isHost(g), PCLaunchers.kind(of: g) == nil else { return nil }
        return GameLauncher.launchedGameProcess(g)
    }

    private static let written = LockedCache<String, Session>(limit: 256)

    /// Takes one sample of a running game. A different game process starts a new session. Call off the main thread.
    @discardableResult
    public static func sample(_ g: InstalledGame, now: Date = Date()) -> Session? {
        guard let pid = gameProcess(g), let bytes = footprint(pid: pid) else { return nil }
        return record(g, pid: pid, bytes: bytes, now: now)
    }

    static func record(_ g: InstalledGame, pid: Int32, bytes: UInt64, now: Date) -> Session {
        let saved = written[g.id] ?? last(g)
        var s: Session
        if let saved, saved.pid == pid, now.timeIntervalSince(saved.updated) < 6 * 3600 {
            s = saved; s.peak = max(s.peak, bytes); s.updated = now
        } else {
            s = Session(pid: pid, started: now, updated: now, first: bytes, peak: bytes)
        }
        let previous = written[g.id]
        let grewEnough = previous.map { s.peak >= $0.peak + 256 << 20 } ?? true
        let stale = previous.map { now.timeIntervalSince($0.updated) >= 60 } ?? true
        if previous?.pid != s.pid || grewEnough || stale {
            if let data = try? JSONEncoder().encode(s) {
                try? FileManager.default.createDirectory(at: url(g).deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url(g), options: .atomic)
            }
            written[g.id] = s
        }
        return s
    }

    /// A game used most of the Mac's memory: past 45% of it, and at least 4 GB.
    public static func isHeavy(_ s: Session, physical: UInt64 = physicalMemory) -> Bool {
        s.peak >= 4 << 30 && Double(s.peak) >= Double(physical) * 0.45
    }

    public static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
    }

    public struct Advice: Equatable, Sendable {
        public var title: String
        public var detail: String
        /// The low-memory DXMT build can be installed for this game.
        public var offersLowMemoryDXMT: Bool
    }

    /// What to say after a heavy session.
    public static func advice(_ g: InstalledGame, session s: Session, physical: UInt64 = physicalMemory) -> Advice? {
        guard isHeavy(s, physical: physical) else { return nil }
        let used = "\(g.name) used \(gigabytes(s.peak)) of this Mac's \(gigabytes(physical)) memory"
        let growing = s.growth >= 2 << 30 ? " It grew by \(gigabytes(s.growth)) while it ran, so long sessions can run out of memory and crash or stutter." : " When the Mac runs short the game can stutter or crash."
        let canLowMemory = !CompatibilityFixes.isInstalled(.dxmtLowMemory, for: g) && CompatibilityFixes.unavailable(.dxmtLowMemory, for: g) == nil
        if canLowMemory {
            return Advice(title: used, detail: growing.trimmingCharacters(in: .whitespaces) + " Low-memory DXMT frees each shader's parsed form once it's compiled, which can cut that a lot. Undo is in Fixes if the game looks wrong.", offersLowMemoryDXMT: true)
        }
        return Advice(title: used, detail: growing.trimmingCharacters(in: .whitespaces) + " Lowering texture quality in the game's settings and closing other apps before playing helps most.", offersLowMemoryDXMT: false)
    }
}
