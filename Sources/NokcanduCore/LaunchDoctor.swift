import Foundation

/// "Game won't start?": goes through what usually stops a game, in the order that's quickest to fix, and ends
/// with one answer and the one thing to do. Runs Repair itself when the check finds something it can repair.
public enum LaunchDoctor {
    public enum Action: Equatable, Sendable {
        case none, play, quit, showCrash, showMods, openPrivacy, diagnostics, chooseProgram, openLauncher
    }
    public struct Finding: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var action: Action
        public var actionTitle: String?
        /// Steps taken on the way ("Checked the drive", "Repaired 2 things").
        public var steps: [String]
    }

    public static func diagnose(_ g: InstalledGame, running: Bool, recentLaunchProblem: String?,
                                progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Finding {
        var steps: [String] = []
        // 1. Its drive.
        progress("Checking the drive…")
        if let m = GameMover.missingDrive(g) {
            return Finding(title: "Its drive isn't connected", detail: m, action: .none, actionTitle: nil, steps: ["Checked where the game's files are"])
        }
        steps.append("The game's files are reachable")
        // 2. Already running (a stuck copy keeps a second one from starting).
        if running {
            return Finding(title: "\(g.name) is already running", detail: "A copy is still running, which keeps another from starting. If you can't see its window, quit it and press Play again.", action: .quit, actionTitle: "Quit \(g.name)", steps: steps)
        }
        steps.append("No copy is still running")
        // 3. A store client that didn't start it.
        if let problem = recentLaunchProblem {
            return Finding(title: "\(StartupMonitor.storeName(g)) didn't start it", detail: problem, action: .openLauncher, actionTitle: "Show \(StartupMonitor.storeName(g))", steps: steps)
        }
        // 4. A recent crash.
        progress("Looking at the last run…")
        if let c = CrashReports.lastCrash(g), Date().timeIntervalSince(c.date) < 2 * 86_400 {
            return Finding(title: c.title, detail: c.detail, action: c.missingMod != nil ? .showMods : .showCrash,
                           actionTitle: c.missingMod != nil ? "Show Mods Folder" : "Show Report", steps: steps + ["Found a crash from \(c.date.formatted(.relative(presentation: .named)))"])
        }
        if !ModDependencies.missing(g).isEmpty, let m = ModDependencies.missing(g).first {
            return Finding(title: "\(m.mod) is missing a mod it needs", detail: m.message, action: .showMods, actionTitle: "Show Mods Folder", steps: steps)
        }
        steps.append("No recent crash")
        // 5. The game's launcher, engine and program.
        progress("Checking the game's launcher and engine…")
        let check = await GameLauncher.preflight(g)
        if !check.ok {
            progress("Repairing…")
            let repaired = Repair.run(g)
            let fixed = repaired.filter { $0.outcome == .fixed }, failed = repaired.filter { $0.outcome == .failed }
            steps.append("The self-check failed: \(check.combined.split(separator: "\n").last.map(String.init) ?? "no details")")
            if !failed.isEmpty {
                return Finding(title: "Something needs fixing by hand", detail: failed.map { "\($0.title): \($0.detail)" }.joined(separator: "\n"), action: .diagnostics, actionTitle: "Open Diagnostics", steps: steps)
            }
            let again = await GameLauncher.preflight(GameLibrary.inspect(g.appURL) ?? g)
            if again.ok {
                return Finding(title: "Fixed — try Play again", detail: fixed.isEmpty ? "The check passes now." : "Repair fixed: " + fixed.map(\.title).joined(separator: ", ") + ".", action: .play, actionTitle: "Play", steps: steps + ["Repaired \(fixed.count) thing\(fixed.count == 1 ? "" : "s")"])
            }
            if again.combined.localizedCaseInsensitiveContains("program") || again.combined.localizedCaseInsensitiveContains(".exe") {
                return Finding(title: "The game's program is missing", detail: again.combined.trimmingCharacters(in: .whitespacesAndNewlines) + " Choose it again under Wine & Fixes → Program.", action: .chooseProgram, actionTitle: "Choose Program", steps: steps)
            }
            return Finding(title: "The game's launcher still fails its check", detail: again.combined.trimmingCharacters(in: .whitespacesAndNewlines), action: .diagnostics, actionTitle: "Open Diagnostics", steps: steps)
        }
        steps.append("The launcher, engine and program check out")
        // 6. What the last launch said.
        let log = g.logs.appendingPathComponent("launch.log")
        if let text = (try? String(contentsOf: log, encoding: .utf8))?.suffix(8000).lowercased() {
            if text.contains("operation not permitted") || text.contains("permission denied") {
                return Finding(title: "macOS blocked the game's files", detail: "The last launch was refused access to files. Allow \(g.name) under System Settings → Privacy & Security → Files and Folders (or Full Disk Access for games on external drives), then press Play.", action: .openPrivacy, actionTitle: "Open Privacy Settings", steps: steps)
            }
        }
        steps.append("The last launch log shows nothing blocking it")
        return Finding(title: "Nothing wrong found", detail: "Everything Nokcandu can check looks fine. Press Play and watch the line under it; if the game still doesn't appear, Diagnostics has its full launch log, and Report a Problem sends it with your game's details.", action: .diagnostics, actionTitle: "Open Diagnostics", steps: steps)
    }
}
