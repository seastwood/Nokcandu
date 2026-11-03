import Foundation

/// The usage declaration is an opt-in capability, separate from the input guard.
/// Duplex output devices can cause CoreAudio to request microphone consent while
/// initializing playback. Off must therefore omit the declaration as well as hide capture.
public enum AppPrivacy {
    static let microphoneKey = "NSMicrophoneUsageDescription"
    static let microphoneIntentKey = "NokcanduMicrophoneOptIn"
    static let microphonePurpose = "Games and Steam can use your microphone for voice chat."
    /// New games default to microphone Off. An explicit On choice adds the declaration.
    public static let keys: [String: Any] = [:]
    public static func keys(microphone: Bool) -> [String: Any] {
        microphone ? [microphoneKey: microphonePurpose] : [:]
    }
    static func setting(_ info: [String: Any], microphone: Bool) -> [String: Any] {
        var value = info
        if microphone {
            if value[microphoneKey] == nil { value[microphoneKey] = microphonePurpose }
            value[microphoneIntentKey] = true
        } else {
            value.removeValue(forKey: microphoneKey)
            value.removeValue(forKey: microphoneIntentKey)
        }
        return value
    }
    /// Update only microphone policy metadata; keep the native-entry ownership/Undo record in sync.
    @discardableResult
    static func apply(_ app: URL, microphone: Bool) throws -> Bool {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard url.resolvingSymlinksInPath() == url else { throw NokError("The app's privacy metadata is linked; it was preserved.") }
        let before = try Data(contentsOf: url)
        guard let info = try PropertyListSerialization.propertyList(from: before, format: nil) as? [String: Any], (info["NokcanduRecipe"] != nil || GameLibrary.inspect(app)?.isManaged == true) else { return false }
        let value = setting(info, microphone: microphone)
        guard !NSDictionary(dictionary: value).isEqual(to: info) else { return false }
        let after = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        let marker = app.appendingPathComponent("Contents/SharedSupport/nokcandu/" + LauncherEntry.record)
        guard marker.resolvingSymlinksInPath() == marker else { throw NokError("The app entry ownership record is linked; it was preserved.") }
        let record = try? Data(contentsOf: marker)
        var updatedRecord: Data?
        if let record {
            var state = try JSONDecoder().decode(LauncherEntry.State.self, from: record)
            let helper = app.appendingPathComponent("Contents/MacOS/" + LauncherEntry.name)
            guard before == state.installed, try Hashing.sha256(file: helper) == state.helperSHA else {
                throw NokError("This app's entry metadata was edited outside Nokcandu. It was preserved; restore its managed entry before changing microphone access.")
            }
            state.installed = after
            if let original = try PropertyListSerialization.propertyList(from: state.original, format: nil) as? [String: Any] {
                state.original = try PropertyListSerialization.data(fromPropertyList: setting(original, microphone: microphone), format: .xml, options: 0)
            }
            updatedRecord = try JSONEncoder().encode(state)
        }
        guard try Data(contentsOf: url) == before else { throw NokError("The app changed while preparing microphone access. Try again after it finishes updating.") }
        do {
            try after.write(to: url, options: .atomic)
            if let updatedRecord { try updatedRecord.write(to: marker, options: .atomic) }
        } catch {
            try? before.write(to: url, options: .atomic)
            if let record { try? record.write(to: marker, options: .atomic) }
            throw error
        }
        _ = try? Shell.run("/usr/bin/touch", [app.path])
        return true
    }
    /// Closed installations migrate from the former unconditional microphone declaration.
    @discardableResult
    public static func ensure(_ app: URL) -> Bool {
        guard let g = GameLibrary.inspect(app), GameMicrophone.supported(g), case .notRunning = GameLauncher.runState(of: g) else { return false }
        return (try? apply(app, microphone: GameMicrophone.isOn(g))) ?? false
    }
    /// A shared client's OS permission belongs to its identity. Add the declaration when
    /// launching an enabled game, keep it for other enabled games still running, and remove
    /// it for Off launches when no active opted-in game/client needs it.
    public static func prepare(_ game: InstalledGame, games: [InstalledGame]? = nil) throws {
        guard GameMicrophone.supported(game) else { return }
        let fresh = GameLibrary.inspect(game.appURL) ?? game
        _ = try apply(fresh.appURL, microphone: GameMicrophone.isOn(fresh))
        guard let host = WineTools.hostContents(for: fresh), host != fresh.contents else { return }
        let library = games ?? GameLibrary.scan()
        let hostGame = GameLibrary.inspect(host.deletingLastPathComponent())
        var needed = hostGame.map(GameMicrophone.isOn) ?? false
        // Once an enabled game opts this live client session in, keep its declaration
        // until the client closes. Do not revoke a sibling's active audio capability.
        if let hostGame, case .launcherRunning = GameLauncher.runState(of: hostGame),
           (NSDictionary(contentsOf: host.appendingPathComponent("Info.plist"))?[microphoneIntentKey] as? Bool) == true { needed = true }
        needed = needed || GameMicrophone.isOn(fresh)
        for saved in library where saved.id != fresh.id && WineTools.hostContents(for: saved) == host {
            let other = GameLibrary.inspect(saved.appURL) ?? saved
            if GameMicrophone.isOn(other), case .launcherRunning = GameLauncher.runState(of: other) { needed = true }
        }
        _ = try apply(host.deletingLastPathComponent(), microphone: needed)
        // Shortcuts can start a client without its own Play button being used.
        // Prepare its native privacy identity on the same cold-launch path.
        if let hostGame { try LauncherEntry.ensure(hostGame) }
    }
    public static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
