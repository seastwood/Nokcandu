import Foundation

/// Drains durable requests while the app is open, independently of launching a game.
/// Active/unknown sessions remain untouched; the existing apply lock handles other processes.
public actor PendingSettingsMonitor {
    public struct Report {
        public var applied: [String] = []
        public var failures: [String] = []
        public var activities: [String: PendingSettings.Activity] = [:]
    }
    private var busy = false
    private var failed: [String: String] = [:]
    public init() {}
    public func retry() { failed.removeAll() }

    public func drain(_ games: [InstalledGame],
                      observe: @Sendable (InstalledGame) -> PendingSettings.Activity = { PendingSettings.activity(for: $0) },
                      apply: (@Sendable (InstalledGame) async throws -> PendingSettings.Outcome)? = nil,
                      prepareWindow: (@Sendable (InstalledGame) async throws -> Bool)? = nil) async -> Report {
        guard !busy else { return Report() }
        busy = true; defer { busy = false }
        var report = Report(), seen = Set<String>()
        for game in games where game.native == nil {
            guard let host = WineTools.hostContents(for: game) else { continue }
            let key = host.resolvingSymlinksInPath().path
            let entries = PendingSettings.entries(for: game)
            let windowPending = WindowedPresentation.needsIdleApply(for: game)
            guard PendingSettings.hasPending(for: game) || windowPending else { failed[key] = nil; continue }
            guard seen.insert(key).inserted else { continue }
            let activity = observe(game)
            for peer in games where WineTools.hostContents(for: peer)?.resolvingSymlinksInPath().path == key {
                report.activities[peer.id] = activity
            }
            guard activity == .closed || activity == .backgroundOnly else { failed[key] = nil; continue }
            let fingerprint = entries.map(\.id).joined(separator: ",") + "|" + String(describing: WindowedPresentation.setting(for: game))
            guard failed[key] != fingerprint else { continue }
            do {
                // Rechecks session activity under its cross-process lock before mutation.
                let outcome: PendingSettings.Outcome
                if let apply { outcome = try await apply(game) }
                else { outcome = try await PendingSettings.apply(for: game) }
                guard outcome == .applied else { continue }
                if windowPending {
                    // With no queued requests there may still be idle Wine services.
                    // prepareForLaunch refuses to replace a running environment's driver.
                    let ready: Bool
                    if let prepareWindow { ready = try await prepareWindow(game) }
                    else { ready = try await WindowedPresentation.applyWhenIdle(game) }
                    guard ready else { continue }
                }
                failed[key] = nil
                report.applied.append(game.name)
            } catch {
                failed[key] = fingerprint
                report.failures.append("\(game.name): \(error.localizedDescription)")
            }
        }
        return report
    }
}
