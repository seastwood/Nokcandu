import AppKit
import NokcanduCore

/// Games come to the front when they start. Since macOS 14 an app can only bring itself forward when the active
/// app lets it ("cooperative activation"), so a game's window — the resizable window included — opened behind
/// Nokcandu. After Play, Nokcandu hands activation over to the game's programs as they appear (for a minute).
@MainActor
enum ActivationHandoff {
    private static var timer: Timer?
    private static var yielded: Set<pid_t> = []

    static func expect(_ g: InstalledGame) {
        // The game's own app, and its launcher's (Battle.net, Steam…) whose Wine programs run the game.
        var roots = [g.appURL.standardizedFileURL.path + "/"]
        if let host = WineTools.hostContents(for: g) { roots.append(host.deletingLastPathComponent().standardizedFileURL.path + "/") }
        if let n = g.native { roots.append(URL(fileURLWithPath: n.appPath).standardizedFileURL.path + "/") }
        timer?.invalidate()
        yielded = []
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
            MainActor.assumeIsolated {
                if Date().timeIntervalSince(started) > 60 { t.invalidate(); timer = nil; return }
                for app in NSWorkspace.shared.runningApplications where !yielded.contains(app.processIdentifier) {
                    guard let path = (app.bundleURL ?? app.executableURL)?.standardizedFileURL.path,
                          roots.contains(where: { path.hasPrefix($0) }) else { continue }
                    yielded.insert(app.processIdentifier)
                    NSApp.yieldActivation(to: app)
                }
            }
        }
    }
}
