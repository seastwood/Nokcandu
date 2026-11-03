import Foundation
import Darwin

/// Persist desired changes independently of the Windows session that currently uses the old values.
public enum PendingSettings {
    public enum Change: Codable {
        case wine(String), performance(Performance.Settings), lowLatency(Bool), frameCap(Int?), audioBuffer(Int)
        case display([Int]?), windowStyle(GameWindowStyle), graphics(GraphicsPreset)
        case custom(CustomGameConfig, force: Bool, changeProgram: Bool), recipe(RecipeSettings.Settings), hosted(HostedSettings.Settings)
        case nativeAdapter(String), nativeFrame(Int), compatibility(CompatibilityFix, undo: Bool)
        case cinematic(undo: Bool, zips: [String: String]), bc2(undo: Bool, resolution: [Int]?, settings: HostedSettings.Settings?)
        var key: String {
            switch self {
            case .wine: return "wine"; case .performance: return "performance"; case .lowLatency: return "lowLatency"
            case .frameCap: return "frameCap"; case .audioBuffer: return "audioBuffer"; case .display: return "display"
            case .windowStyle: return "windowStyle"; case .graphics: return "graphics"; case .custom: return "custom"
            case .recipe: return "recipe"; case .hosted: return "hosted"; case .nativeAdapter: return "nativeAdapter"
            case .nativeFrame: return "nativeFrame"; case .compatibility(let fix, _): return "fix-" + fix.id
            case .cinematic: return "cinematic"; case .bc2: return "bc2"
            }
        }
        func apply(to game: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
            switch self {
            case .wine(let id): try await EngineUpdate.apply(game, runtimeID: id, explicitChoice: true, log: log)
            case .performance(let value): try Performance.apply(value, for: game)
            case .lowLatency(let value): try LowLatency.apply(value, to: game)
            case .frameCap(let value): try LowLatency.applyCap(value, to: game)
            case .audioBuffer(let value): try AudioBuffer.apply(value, for: game)
            case .display(let value): try GameDisplay.apply(value, to: game, library: GameLibrary.scan())
            case .windowStyle(let value): try await GameWindowStyle.apply(value, to: game, log: log)
            case .graphics(let value):
                guard var config = game.custom else { throw NokError("This game has no managed graphics settings.") }
                config.graphics = value; try CustomGames.save(config, to: game)
            case .custom(var value, let force, let changeProgram):
                value.microphone = GameMicrophone.isOn(game)
                if changeProgram, let previous = game.custom {
                    let missed = try await CompatibilityFixes.changeProgram(to: value, from: previous, for: game, log: log)
                    if !missed.isEmpty { throw NokError("Program changed, but some fixes need attention: " + missed.map { $0.0.title + ": " + $0.1 }.joined(separator: "; ")) }
                }
                else { try CustomGames.saveAll(value, to: game, force: force) }
            case .recipe(var value): value.microphone = GameMicrophone.isOn(game); try RecipeSettings.save(value, for: game)
            case .hosted(var value): value.microphone = GameMicrophone.isOn(game); try HostedSettings.save(value, for: game)
            case .nativeAdapter(let value): try NativeIPXNetworking.setAdapter(value, for: game)
            case .nativeFrame(let value): try NativeIPXNetworking.setFrame(value, for: game)
            case .compatibility(let fix, let undo):
                if undo { try CompatibilityFixes.undo(fix, for: game, log: log) }
                else { try await CompatibilityFixes.install(fix, for: game, log: log) }
            case .cinematic(let undo, let paths):
                if undo { try await CinematicFix.undo(for: game, log: log) }
                else {
                    var zips: [CinematicFix.Arch: URL] = [:]
                    for (name, path) in paths { if let arch = CinematicFix.Arch(rawValue: name) { zips[arch] = URL(fileURLWithPath: path) } }
                    try await CinematicFix.install(for: game, localZips: zips, log: log)
                }
            case .bc2(let undo, let resolution, let settings):
                if undo { try BC2DisplaySettings.undo(game) }
                else { try BC2DisplaySettings.apply(game, resolution: resolution ?? BC2DisplaySettings.desktop) }
                if var settings { settings.microphone = GameMicrophone.isOn(game); try HostedSettings.save(settings, for: game) }
            }
        }
    }
    public struct Entry: Codable, Identifiable {
        public var id = UUID().uuidString
        public var created = Date()
        public var gamePath: String
        public var identity: String
        public var title: String
        public var change: Change
    }
    public enum Activity: Equatable { case closed, backgroundOnly, active, unknown }
    public enum Outcome: Equatable { case applied, deferred }
    static func identity(_ game: InstalledGame) -> String { game.custom?.id ?? game.bundleIdentifier ?? game.appURL.path }
    /// Outside game bundles: macOS may refuse writes inside a bundle while its programs are running.
    nonisolated(unsafe) public static var stateRootOverride: URL?
    static var stateRoot: URL { (stateRootOverride ?? NokPaths.support.appendingPathComponent("Pending Settings")).resolvingSymlinksInPath() }
    struct Owner: Codable { var path: String; var identity: String }
    static func hostIdentity(_ contents: URL) -> String {
        GameLibrary.inspect(contents.deletingLastPathComponent()).map(identity) ?? contents.path
    }
    static func directory(_ contents: URL) -> URL {
        let path = contents.resolvingSymlinksInPath().path, identity = hostIdentity(contents)
        let key = Hashing.sha256(data: Data((path + "\n" + identity).utf8))
        let direct = stateRoot.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // A move carries the game identity; never adopt a different existing copy's requests.
        let folders = (try? FileManager.default.contentsOfDirectory(at: stateRoot, includingPropertiesForKeys: nil)) ?? []
        return folders.first { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("owner")),
                  let owner = try? JSONDecoder().decode(Owner.self, from: data), owner.identity == identity else { return false }
            return owner.path == path || !FileManager.default.fileExists(atPath: owner.path)
        } ?? direct
    }
    static func files(_ contents: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory(contents), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }
    static func validateDirectory(_ contents: URL) throws {
        let folder = directory(contents)
        guard folder.resolvingSymlinksInPath().path == stateRoot.appendingPathComponent(folder.lastPathComponent).path,
              folder.deletingLastPathComponent().resolvingSymlinksInPath().path == stateRoot.path else {
            throw NokError("The saved-settings folder is linked; it was preserved.")
        }
    }
    static func read(_ contents: URL) throws -> [Entry] {
        try validateDirectory(contents)
        return try files(contents).map { file in
            guard (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) != .typeSymbolicLink,
                  file.deletingLastPathComponent().resolvingSymlinksInPath().path == directory(contents).resolvingSymlinksInPath().path else { throw NokError("A saved setting is linked; it was preserved.") }
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
            guard UUID(uuidString: entry.id) != nil, entry.id == file.deletingPathExtension().lastPathComponent else { throw NokError("A saved-setting identity is invalid; it was preserved.") }
            return entry
        }.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }
    public static func lastError(for game: InstalledGame) -> String? {
        WineTools.hostContents(for: game).flatMap { try? String(contentsOf: directory($0).appendingPathComponent("last-error.txt"), encoding: .utf8) }
    }
    public static func hasPending(for game: InstalledGame) -> Bool {
        WineTools.hostContents(for: game).map { !files($0).isEmpty } ?? false
    }
    public static func entries(for game: InstalledGame) -> [Entry] {
        WineTools.hostContents(for: game).flatMap { try? read($0) } ?? []
    }
    @discardableResult
    public static func save(_ change: Change, title: String, for game: InstalledGame) throws -> Entry {
        guard let contents = WineTools.hostContents(for: game) else { throw NokError("This game has no Windows environment.") }
        let folder = directory(contents)
        try validateDirectory(contents)
        let previous = try read(contents).filter { $0.identity == identity(game) && $0.change.key == change.key }
        let entry = Entry(gamePath: game.appURL.standardizedFileURL.path == contents.deletingLastPathComponent().standardizedFileURL.path ? "." : game.appURL.path,
                          identity: identity(game), title: title, change: change)
        try NokPaths.ensure(folder)
        let owner = Owner(path: contents.resolvingSymlinksInPath().path, identity: hostIdentity(contents))
        try JSONEncoder().encode(owner).write(to: folder.appendingPathComponent("owner"), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("last-error.txt"))
        try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent(entry.id + ".json"), options: .atomic)
        for old in previous { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.id + ".json")) }
        return entry
    }
    public static func discard(for game: InstalledGame) throws {
        guard let contents = WineTools.hostContents(for: game) else { return }
        try validateDirectory(contents)
        guard !files(contents).isEmpty else { return }
        let fd = open(directory(contents).appendingPathComponent("apply.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NokError("Couldn't open the saved-settings lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NokError("Saved settings are already being applied. You can still save another change.") }
        defer { flock(fd, LOCK_UN) }
        for file in files(contents) { try FileManager.default.removeItem(at: file) }
    }
    static func backgroundCommand(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "/", with: "\\")
        if text.hasPrefix(#"c:\windows\"#) {
            let executable = String(text.split(separator: " ").first ?? "").components(separatedBy: "\\").last ?? ""
            return ["services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "explorer.exe"].contains(executable)
        }
        return text.range(of: #"\\wine\\bin\\wineserver(?:\s|$)"#, options: .regularExpression) != nil
    }
    static func activity(reliable: Bool, ownedCommands: [String]) -> Activity {
        guard reliable else { return .unknown }
        if ownedCommands.isEmpty { return .closed }
        return ownedCommands.allSatisfy(backgroundCommand) ? .backgroundOnly : .active
    }
    public static func activity(for game: InstalledGame) -> Activity {
        guard let contents = WineTools.hostContents(for: game) else { return .closed }
        let snapshot = GameLauncher.freshProcessStatus()
        guard snapshot.reliable else { return .unknown }
        let peers = GameLibrary.scan().filter { WineTools.hostContents(for: $0)?.standardizedFileURL.path == contents.standardizedFileURL.path }
        for peer in peers + [game] {
            if case .launcherRunning(let pid) = GameLauncher.runState(of: peer, processes: snapshot.rows),
               let command = snapshot.rows.first(where: { $0.0 == pid })?.1, !backgroundCommand(command) { return .active }
        }
        return activity(reliable: true, ownedCommands: snapshot.rows.filter { WineTools.owns(pid: $0.0, contents: contents) }.map(\.1))
    }
    /// Cross-process lock covers application only; saving another desired change never waits for Wine.
    public static func apply(for game: InstalledGame, waitForApplication: Bool = false, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        do {
            let result = try await applyPending(for: game, waitForApplication: waitForApplication, observe: { activity(for: $0) }, stopIdle: { try await WineTools.stopAll(for: $0) },
                                               execute: { entry, selected in try await entry.change.apply(to: selected, log: log) }, log: log)
            if result == .applied, let contents = WineTools.hostContents(for: game) { try? FileManager.default.removeItem(at: directory(contents).appendingPathComponent("last-error.txt")) }
            return result
        } catch {
            if let contents = WineTools.hostContents(for: game) {
                let file = directory(contents).appendingPathComponent("last-error.txt")
                try? Data(error.localizedDescription.utf8).write(to: file, options: .atomic)
            }
            throw error
        }
    }
    static func applyPending(for game: InstalledGame, waitForApplication: Bool = false, observe: (InstalledGame) -> Activity,
                             stopIdle: (InstalledGame) async throws -> Void,
                             execute: (Entry, InstalledGame) async throws -> Void,
                             log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Outcome {
        guard let contents = WineTools.hostContents(for: game), !files(contents).isEmpty else { return .applied }
        try validateDirectory(contents)
        let lock = directory(contents).appendingPathComponent("apply.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NokError("Couldn't open the saved-settings lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | (waitForApplication ? 0 : LOCK_NB)) == 0 else { return .deferred }
        defer { flock(fd, LOCK_UN) }
        switch observe(game) {
        case .active, .unknown: return .deferred
        case .backgroundOnly: try await stopIdle(game)
        case .closed: break
        }
        for _ in 0..<8 {
            let pending = try read(contents)
            if pending.isEmpty { return .applied }
            var appliedAny = false
            for entry in pending {
                let file = directory(contents).appendingPathComponent(entry.id + ".json")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let path = entry.gamePath == "." ? contents.deletingLastPathComponent() : URL(fileURLWithPath: entry.gamePath)
                if LauncherInstallation.presence(at: path.deletingLastPathComponent()) == .offline { continue }
                let selected = GameLibrary.inspect(path) ?? GameLibrary.scan().first { identity($0) == entry.identity && WineTools.hostContents(for: $0) == contents }
                guard let selected, identity(selected) == entry.identity, WineTools.hostContents(for: selected) == contents else {
                    throw NokError("The game for saved setting ‘\(entry.title)’ is unavailable. Its change was kept.")
                }
                log("Applying saved \(entry.title)…")
                try await execute(entry, selected)
                appliedAny = true
                do { try FileManager.default.removeItem(at: file) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { /* A newer save superseded this exact request. */ }
            }
            if !appliedAny, try read(contents).map(\.id) == pending.map(\.id) { return .deferred }
        }
        return .deferred
    }
    public static let helperName = "nokcandu-settings"
    @discardableResult
    public static func ensureHelper(for game: InstalledGame, source: URL? = nil) throws -> Bool {
        guard let source = source ?? NokPaths.bundledResource(helperName, executable: true) else { return false }
        guard FileManager.default.fileExists(atPath: game.appURL.path) else { throw NokError("The game's app is unavailable. Its saved changes were kept; connect its drive before starting it.") }
        let target = game.nokcanduState.appendingPathComponent(helperName)
        guard target.resolvingSymlinksInPath().path == target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(helperName).path else { throw NokError("The saved-settings helper is linked; it was preserved.") }
        let data = try Data(contentsOf: source), hash = Hashing.sha256(data: data)
        let marker = game.nokcanduState.appendingPathComponent("settings-helper.json")
        let prior = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        let existing = try? Hashing.sha256(file: target)
        guard existing == nil || existing == hash || existing == prior?["sha256"] else { throw NokError("The saved-settings helper was edited; it was preserved.") }
        try NokPaths.ensure(game.nokcanduState)
        let changed = existing != hash
        if changed { try data.write(to: target, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        let record = ["sha256": hash, "resources": source.deletingLastPathComponent().path]
        if record != prior { try JSONEncoder().encode(record).write(to: marker, options: .atomic) }
        return changed
    }
    public static func resourceRoot(for game: InstalledGame) -> URL? {
        let file = game.nokcanduState.appendingPathComponent("settings-helper.json")
        guard let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([String: String].self, from: data),
              let root = values["resources"] else { return nil }
        return URL(fileURLWithPath: root)
    }
    public static func performance(for game: InstalledGame) -> Performance.Settings? {
        entries(for: game).compactMap { entry in
            guard case .performance(let settings) = entry.change else { return nil }
            let app = entry.gamePath == "." ? WineTools.hostContents(for: game)?.deletingLastPathComponent() : URL(fileURLWithPath: entry.gamePath)
            guard let app, let owner = GameLibrary.inspect(app), Performance.settingsContents(owner) == Performance.settingsContents(game) else { return nil }
            return settings
        }.last
    }
    public static func audioBuffer(for game: InstalledGame) -> Int? {
        entries(for: game).compactMap { if case .audioBuffer(let ms) = $0.change { return ms }; return nil }.last
    }
    public static func hosted(for game: InstalledGame) -> HostedSettings.Settings? {
        entries(for: game).filter { $0.identity == identity(game) }.compactMap {
            switch $0.change { case .hosted(let settings): return settings; case .bc2(_, _, let settings): return settings; default: return nil }
        }.last
    }
    public static func recipe(for game: InstalledGame) -> RecipeSettings.Settings? {
        entries(for: game).filter { $0.identity == identity(game) }.compactMap { if case .recipe(let settings) = $0.change { return settings }; return nil }.last
    }

    public static func nativeFrame(for game: InstalledGame) -> Int? {
        entries(for: game).filter { $0.identity == identity(game) }.compactMap { if case .nativeFrame(let value) = $0.change { return value }; return nil }.last
    }
    public static func nativeAdapter(for game: InstalledGame) -> String? {
        entries(for: game).filter { $0.identity == identity(game) }.compactMap { if case .nativeAdapter(let value) = $0.change { return value }; return nil }.last
    }
    public static func requestedWine(for game: InstalledGame) -> String? {
        entries(for: game).compactMap { if case .wine(let id) = $0.change { return RuntimeManager.manifest(for: id).flatMap { EngineVersion(versionString: $0.wineVersion)?.tag } }; return nil }.last
    }
    public static func preview(_ game: InstalledGame) -> InstalledGame {
        var result = game
        for entry in entries(for: game) where entry.identity == identity(game) {
            switch entry.change {
            case .custom(let config, _, _): result.custom = config
            case .graphics(let value): result.custom?.graphics = value
            case .lowLatency(let value): if let config = result.custom { result.custom = LowLatency.set(value, config) }
            case .frameCap(let value): if let config = result.custom { result.custom = LowLatency.setCap(value, config) }
            case .display(let value): result.custom?.displayPixels = value
            case .windowStyle(let value): result.custom?.borderless = value == .gameDefault ? nil : true; result.custom?.macFullScreen = value == .fullScreen ? true : nil
            default: break
            }
        }
        result.custom?.microphone = GameMicrophone.isOn(game)
        return result
    }
}
