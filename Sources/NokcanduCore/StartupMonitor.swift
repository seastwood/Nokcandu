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
                // Nothing has started yet. macOS checks an app the first time it opens after its files changed
                // (a move, an engine update, shared engine files), which can hold the launch for a while.
                if elapsed >= 60 { return .failed("\(name) didn't start. " + detail) }
                return .waiting("\(name) is taking a while to start. macOS checks a game the first time it opens after its files changed; this can take up to a minute.")
            }
            return .waiting("\(name) is still starting. Check for macOS permission or store sign-in dialogs. If no game window appears, open Health → Diagnostics to inspect the launch log.")
        }
        return .pending
    }
    public static func observe(_ g: InstalledGame, since: Date, elapsed: TimeInterval) -> Observation {
        let receipt = (try? Data(contentsOf: g.logs.appendingPathComponent("launcher-status.json")))
            .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        let host = WineTools.hostContents(for: g)
        var runtime = StuckGames.running(g).filter { process in host.map { WineTools.owns(pid: process.pid, contents: $0) } ?? false }
        if GameLauncher.hasPrivateGamePrefix(g), let host {
            for (pid, command) in GameLauncher.processSnapshot() where GameLauncher.privateGameCommand(command) && WineTools.owns(pid: pid, contents: host) {
                if !runtime.contains(where: { $0.pid == pid }) { runtime.append(.init(pid: pid, program: command, seconds: 0)) }
            }
        }
        let windows = StuckGames.pidsWithWindows()
        // A Wine virtual desktop may own the Mac window on behalf of the game.
        let window = !runtime.isEmpty && (runtime.contains { windows.contains($0.pid) } ||
            host.map { h in windows.contains { WineTools.owns(pid: $0, contents: h) } } == true)
        var running: Bool
        if GameLauncher.runState(of: g) != .notRunning { running = true } else { running = !runtime.isEmpty }
        // macOS may hold the app's own launcher while it checks changed files (seen for minutes when its online
        // check is slow): as long as that process exists, the game is still starting.
        if !running {
            let entry = g.contents.resolvingSymlinksInPath().appendingPathComponent("MacOS").path + "/"
            running = GameLauncher.processSnapshot().contains { $0.1.hasPrefix(entry) || $0.1.contains(entry) }
        }
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

    /// What a starting game is doing right now, in words, for the progress line under Play.
    /// nil once there's nothing to say (the window is open, or nothing is starting).
    public static func stage(_ g: InstalledGame, since: Date, elapsed: TimeInterval) -> String? {
        let receipt = (try? Data(contentsOf: g.logs.appendingPathComponent("launcher-status.json")))
            .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
            .flatMap { $0.startedAt >= since.timeIntervalSince1970 - 0.5 ? $0 : nil }
        let snapshot = GameLauncher.processSnapshot()
        let entry = g.contents.resolvingSymlinksInPath().appendingPathComponent("MacOS").path + "/"
        let launcherAlive = snapshot.contains { $0.1.contains(entry) }
        let host = WineTools.hostContents(for: g)
        let windowsUp = host.map { !WineTools.ownedProcesses(contents: $0).isEmpty } ?? false
        let gameUp = !StuckGames.running(g).isEmpty
        if gameUp { return "Starting \(g.name)…" }
        if receipt == nil {
            if launcherAlive && elapsed > 5 { return "macOS is checking \(g.name) before it opens (this can take a while the first time after a change)…" }
            return "Opening \(g.name)…"
        }
        if g.battleNet != nil { return windowsUp ? "Waiting for Battle.net to start the game (sign in if it asks)…" : "Starting Battle.net…" }
        if g.usesSharedSteam { return windowsUp ? "Waiting for Steam to start the game (sign in if it asks)…" : "Starting Steam…" }
        if let link = g.hosted { return windowsUp ? "Waiting for \(link.launcher.title) to start the game…" : "Starting \(link.launcher.title)…" }
        return windowsUp ? "Starting Windows programs…" : "Starting Windows…"
    }
}
