import Foundation

/// Epic cloud saves (through legendary): before a game starts, a newer cloud save is downloaded; after
/// it quits, a newer local save is uploaded. legendary compares the dates and never overwrites a newer
/// save with an older one. Windows games' save folders are found inside the game's Wine prefix.
public enum CloudSaves {
    public static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "cloudSavesOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "cloudSavesOff") }
    }

    public static func supported(_ g: InstalledGame) -> StoreLink? {
        guard enabled, let (l, _) = StoreUpdates.link(g), l.store == .epic, StoreAccounts.isSignedIn(.epic) else { return nil }
        return l
    }

    public enum Result: Equatable, Sendable { case downloaded, uploaded, upToDate, none, notSupported, failed(String) }

    public static func parse(_ text: String) -> Result {
        let t = text.lowercased()
        if t.contains("does not support cloud saves") || t.contains("has not been set, skipping") { return .notSupported }
        if t.contains("downloading") && t.contains("save") { return .downloaded }
        if t.contains("uploading") { return .uploaded }
        if t.contains("is up to date") { return .upToDate }
        if t.contains("no cloud or local savegame") { return .none }
        if t.contains("error") || t.contains("failed") { return .failed(text.components(separatedBy: .newlines).last { $0.lowercased().contains("error") } ?? "sync failed") }
        return .none
    }

    @discardableResult
    public static func sync(_ g: InstalledGame, log: (@Sendable (String) -> Void)? = nil) async -> Result {
        guard let l = supported(g) else { return .notSupported }
        var env: [String: String] = [:]
        if g.native == nil, let c = WineTools.hostContents(for: g) {
            env["WINEPREFIX"] = c.appendingPathComponent("SharedSupport/prefix").path
        }
        do {
            let r = try await StoreTools.capture(.epic, ["sync-saves", l.id, "-y", "--accept-path"], timeout: 180, extraEnvironment: env)
            let text = String(decoding: r.out, as: UTF8.self) + "\n" + r.err
            let res = parse(text)
            log?("Cloud saves: \(res)")
            return res
        } catch { return .failed(error.localizedDescription) }
    }
}
