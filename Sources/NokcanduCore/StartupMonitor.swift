import Foundation

/// Observe an actual Play attempt; preflight and old logs never count as a new failure.
public enum StartupMonitor {
    struct Receipt: Codable {
        var startedAt: Double
        var phase: String
        var exitCode: Int
        var pid: Int32
    }
    public enum Observation: Equatable {
        case pending
        case opened
        case failed(String)
        case waiting(String)
    }
    static func evaluate(name: String, receipt: Receipt?, since: Date, elapsed: TimeInterval,
                         running: Bool, window: Bool, handoff: Bool, detail: String) -> Observation {
        if window { return .opened }
        let fresh = receipt.flatMap { $0.startedAt.isFinite && $0.startedAt >= since.timeIntervalSince1970 - 0.5 ? $0 : nil }
        if let fresh, fresh.phase == "exited", !running, fresh.exitCode != 0 {
            return .failed("\(name) couldn't start (launcher exit \(fresh.exitCode)). " + detail)
        }
        if let fresh, fresh.phase == "exited", !running, !handoff, elapsed >= 3 {
            return .failed("\(name) closed before startup was confirmed. " + detail)
        }
        if elapsed >= 12 {
            if fresh == nil && !running && !handoff {
                return .failed("\(name) didn't start. " + detail)
            }
            return .waiting("\(name) is still starting. Check for macOS permission or store sign-in dialogs. If no game window appears, open Health → Diagnostics to inspect the launch log.")
        }
        return .pending
    }
    public static func observe(_ g: InstalledGame, since: Date, elapsed: TimeInterval) -> Observation {
        let receipt = (try? Data(contentsOf: g.logs.appendingPathComponent("launcher-status.json")))
            .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        let host = WineTools.hostContents(for: g)
        let runtime = StuckGames.running(g).filter { process in host.map { WineTools.owns(pid: process.pid, contents: $0) } ?? false }
        let windows = StuckGames.pidsWithWindows()
        // A Wine virtual desktop may own the Mac window on behalf of the game.
        let window = !runtime.isEmpty && (runtime.contains { windows.contains($0.pid) } ||
            host.map { h in windows.contains { WineTools.owns(pid: $0, contents: h) } } == true)
        let running: Bool
        if case .launcherRunning = GameLauncher.runState(of: g) { running = true } else { running = !runtime.isEmpty }
        let log = g.logs.appendingPathComponent("launch.log")
        var detail = "Open Health → Diagnostics for the launch log."
        if let date = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           date >= since.addingTimeInterval(-0.5), let handle = try? FileHandle(forReadingFrom: log) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
            let tail = (try? handle.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if tail.localizedCaseInsensitiveContains("operation not permitted") || tail.localizedCaseInsensitiveContains("permission denied") {
                detail = "macOS denied access to the game's files. Check this game's access to external drives in System Settings → Privacy & Security → Files and Folders. " + detail
            } else if let line = tail.components(separatedBy: .newlines).last(where: { $0.contains("Nokcandu:") || $0.lowercased().contains("error:") }) {
                detail = String(line.prefix(400)) + " " + detail
            }
        }
        return evaluate(name: g.name, receipt: receipt, since: since, elapsed: elapsed, running: running,
                        window: window, handoff: g.usesSharedSteam || g.hosted != nil || g.battleNet != nil || g.isSteamHost,
                        detail: detail)
    }
}
