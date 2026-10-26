import Foundation

// Milestone 3 foundation: a resumable, journaled recipe executor.
// Stages are explicit and idempotent (each knows how to tell it is already done), progress is
// persisted after every stage, cancellation terminates child processes, and "Remove unfinished
// install" undoes everything recorded in the install's journal.

public enum StageKind: String, Codable {
    case automatic
    /// The provider's own flow (Steam sign-in, an official installer, a play test). Nokcandu opens it
    /// and then checks the result; it never collects passwords or clicks through agreements.
    case handoff
}

public struct StageInfo: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var kind: StageKind
    /// Input keys this stage needs from the user before it can run (e.g. "steamUser").
    public var needs: [String] = []
}

public enum StageStatus: Equatable {
    case pending, running, done, needsUser(String), failed(String)
}

public struct InstallState: Codable {
    public var installID: String
    public var recipeID: String
    public var targetApp: String
    public var createdTarget = false
    public var completed: [String] = []
    public var inputs: [String: String] = [:]
    public var startedAt = Date()
    public var finishedAt: Date?
}

public protocol InstallStage {
    var info: StageInfo { get }
    func isDone(_ ctx: InstallContext) -> Bool
    func run(_ ctx: InstallContext) async throws
}

public final class InstallContext: @unchecked Sendable {
    public let recipe: GameRecipe
    private let stateBox: Locked<InstallState>
    /// Thread-safe: stages run off the main thread while the UI reads progress.
    public var state: InstallState {
        get { stateBox.value }
        set { stateBox.value = newValue }
    }
    public let journal: ChangeJournal
    public let log: @Sendable (String) -> Void
    public var library: [InstalledGame]

    public var targetApp: URL { URL(fileURLWithPath: state.targetApp) }
    public var contents: URL { targetApp.appendingPathComponent("Contents") }
    public var support: URL { contents.appendingPathComponent("SharedSupport") }
    public var prefix: URL { support.appendingPathComponent("prefix") }
    public var gameFiles: URL { contents.appendingPathComponent(recipe.gameDirectory) }
    public var workDir: URL { NokPaths.installs.appendingPathComponent(state.installID) }
    public var wine: URL { support.appendingPathComponent("wine/bin/wine") }

    init(recipe: GameRecipe, state: InstallState, library: [InstalledGame], log: @escaping @Sendable (String) -> Void) {
        self.recipe = recipe
        self.stateBox = Locked(state)
        self.library = library
        self.log = log
        self.journal = ChangeJournal(scope: "install-\(state.installID)")
    }

    public func input(_ key: String) -> String? {
        let v = state.inputs[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    public var wineEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = contents.appendingPathComponent("Frameworks").path + ":/usr/lib"
        env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "1"      // same as every launcher: a wineserver started without it can't be shared
        env["PATH"] = support.appendingPathComponent("wine/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in recipe.environment where k != "WINEDLLOVERRIDES" { env[k] = v }
        return env
    }

    @discardableResult
    public func runWine(_ args: [String], cwd: URL? = nil, timeout: TimeInterval = 1800) async throws -> ShellResult {
        log("wine " + args.joined(separator: " "))
        let r = try await Shell.runAsync(wine.path, args, cwd: cwd, env: wineEnvironment, timeout: timeout) { [log] s in
            log(s.trimmingCharacters(in: .newlines))
        }
        return r
    }

    func saveState() throws {
        try NokPaths.ensure(workDir)
        try ChangeJournal.encoder.encode(state).write(to: workDir.appendingPathComponent("state.json"), options: .atomic)
    }
}

/// Drives the stages. UI-agnostic; reports through callbacks on whatever thread runs it.
public final class InstallExecutor: @unchecked Sendable {
    public let ctx: InstallContext
    public let stages: [InstallStage]
    private let statusBox = Locked<[String: StageStatus]>([:])
    public private(set) var statuses: [String: StageStatus] {
        get { statusBox.value }
        set { statusBox.value = newValue }
    }
    public var onChange: (@Sendable () -> Void)?

    public init(recipe: GameRecipe, state: InstallState, library: [InstalledGame], stages: [InstallStage],
                log: @escaping @Sendable (String) -> Void) {
        self.ctx = InstallContext(recipe: recipe, state: state, library: library, log: log)
        self.stages = stages
        refreshStatuses()
    }

    /// Start a new install, or resume one from its saved state.
    public static func make(recipe: GameRecipe, library: [InstalledGame], resume installID: String? = nil,
                            log: @escaping @Sendable (String) -> Void) throws -> InstallExecutor {
        guard recipe.id == RecipeCatalog.zeroHour.id else { throw NokError("No installer is validated for \(recipe.displayName) yet.") }
        var state: InstallState
        if let installID,
           let d = try? Data(contentsOf: NokPaths.installs.appendingPathComponent("\(installID)/state.json")),
           let s = try? ChangeJournal.decoder.decode(InstallState.self, from: d) {
            state = s
        } else {
            let id = "zh-" + String(UUID().uuidString.prefix(8)).lowercased()
            var target = NokPaths.gameAppsFolder.appendingPathComponent("\(recipe.displayName) (Nokcandu).app")
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = NokPaths.gameAppsFolder.appendingPathComponent("\(recipe.displayName) (Nokcandu) \(n).app"); n += 1
            }
            state = InstallState(installID: id, recipeID: recipe.id, targetApp: target.path)
        }
        let ex = InstallExecutor(recipe: recipe, state: state, library: library, stages: ZeroHourInstall.stages, log: log)
        try ex.ctx.saveState()
        return ex
    }

    static func loadState(_ id: String) -> InstallState? {
        (try? Data(contentsOf: NokPaths.installs.appendingPathComponent("\(id)/state.json")))
            .flatMap { try? ChangeJournal.decoder.decode(InstallState.self, from: $0) }
    }

    /// Start a general install: any owned Windows game, from the chosen source.
    public static func makeCustom(name: String, source: GameSource, library: [InstalledGame],
                                  log: @escaping @Sendable (String) -> Void) throws -> InstallExecutor {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw NokError("Give the game a name first.") }
        let appName = CustomGames.safeFolderName(clean)
        let target = try CustomGames.freeAppURL(appName)
        var state = InstallState(installID: String(CustomGames.slug(clean).prefix(16)) + "-" + String(UUID().uuidString.prefix(6)).lowercased(),
                                 recipeID: CustomInstall.recipeID, targetApp: target.path)
        state.inputs["name"] = clean
        state.inputs["source"] = source.rawValue
        return try resumeCustom(state, library: library, log: log)
    }

    static func resumeCustom(_ state: InstallState, library: [InstalledGame], log: @escaping @Sendable (String) -> Void) throws -> InstallExecutor {
        let source = state.inputs["source"].flatMap(GameSource.init(rawValue:)) ?? .installer
        let ex = InstallExecutor(recipe: CustomInstall.installRecipe(name: state.inputs["name"] ?? "Game"), state: state,
                                 library: library, stages: CustomInstall.stages(for: source), log: log)
        try ex.ctx.saveState()
        return ex
    }

    /// Resume any saved install (shipped recipe or general game).
    public static func resume(_ installID: String, library: [InstalledGame], log: @escaping @Sendable (String) -> Void) throws -> InstallExecutor {
        guard let s = loadState(installID) else { throw NokError("That install's progress file is missing.") }
        if s.recipeID == CustomInstall.recipeID { return try resumeCustom(s, library: library, log: log) }
        if s.recipeID == SharedSteam.recipeID { return try resumeSteamHost(s, library: library, log: log) }
        guard let r = RecipeCatalog.recipe(id: s.recipeID) else { throw NokError("Unknown recipe \(s.recipeID).") }
        return try make(recipe: r, library: library, resume: installID, log: log)
    }

    /// Set up the shared Windows Steam (Steam.app). Only one exists.
    public static func makeSteamHost(library: [InstalledGame], log: @escaping @Sendable (String) -> Void) throws -> InstallExecutor {
        if let existing = savedInstalls().first(where: { $0.recipeID == SharedSteam.recipeID && $0.finishedAt == nil }) {
            return try resumeSteamHost(existing, library: library, log: log)
        }
        if FileManager.default.fileExists(atPath: SharedSteam.appURL.path) {
            throw NokError("Steam.app already exists in your Sikarugir folder.")
        }
        var state = InstallState(installID: "steam-" + String(UUID().uuidString.prefix(6)).lowercased(),
                                 recipeID: SharedSteam.recipeID, targetApp: SharedSteam.appURL.path)
        state.inputs["name"] = "Steam"
        return try resumeSteamHost(state, library: library, log: log)
    }

    static func resumeSteamHost(_ state: InstallState, library: [InstalledGame], log: @escaping @Sendable (String) -> Void) throws -> InstallExecutor {
        let ex = InstallExecutor(recipe: CustomInstall.installRecipe(name: "Steam"), state: state, library: library,
                                 stages: SteamHostInstall.stages, log: log)
        try ex.ctx.saveState()
        return ex
    }

    public var isSteamHost: Bool { ctx.state.recipeID == SharedSteam.recipeID }

    public var isCustom: Bool { ctx.state.recipeID == CustomInstall.recipeID }
    public var displayName: String { isCustom ? (ctx.state.inputs["name"] ?? "Game") : ctx.recipe.displayName }

    public static func savedInstalls() -> [InstallState] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: NokPaths.installs, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            (try? Data(contentsOf: d.appendingPathComponent("state.json"))).flatMap { try? ChangeJournal.decoder.decode(InstallState.self, from: $0) }
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public func setInput(_ key: String, _ value: String) {
        ctx.state.inputs[key] = value
        try? ctx.saveState()
        refreshStatuses()
    }

    func refreshStatuses() {
        for s in stages where statuses[s.info.id] != .running {
            if ctx.state.completed.contains(s.info.id) { statuses[s.info.id] = .done }
            else if case .some(.failed) = statuses[s.info.id] { continue }
            else { statuses[s.info.id] = .pending }
        }
        onChange?()
    }

    public var nextStage: InstallStage? { stages.first { statuses[$0.info.id] != .done } }
    public var isComplete: Bool { stages.allSatisfy { statuses[$0.info.id] == .done } }

    /// Runs stages in order until one needs the user, fails, or everything is done.
    public func runUntilBlocked() async {
        while let stage = nextStage {
            if Task.isCancelled { return }
            let missing = stage.info.needs.filter { ctx.input($0) == nil }
            if !missing.isEmpty {
                statuses[stage.info.id] = .needsUser(stage.info.detail)
                onChange?()
                return
            }
            statuses[stage.info.id] = .running
            onChange?()
            ctx.log("▶︎ \(stage.info.title)")
            do {
                if !stage.isDone(ctx) {
                    try await stage.run(ctx)
                }
                guard stage.isDone(ctx) else {
                    throw NokError(stage.info.kind == .handoff
                                   ? "Not finished yet — complete the step, then press Continue."
                                   : "The step ran but its result could not be confirmed.")
                }
                ctx.state.completed.append(stage.info.id)
                if isCompleteAfterThis(stage) { ctx.state.finishedAt = Date() }
                try ctx.saveState()
                statuses[stage.info.id] = .done
                ctx.log("✓ \(stage.info.title)")
            } catch is CancellationError {
                statuses[stage.info.id] = .failed("Cancelled")
                ctx.log("Cancelled.")
                onChange?()
                return
            } catch {
                statuses[stage.info.id] = stage.info.kind == .handoff ? .needsUser(error.localizedDescription) : .failed(error.localizedDescription)
                ctx.log("✗ \(stage.info.title): \(error.localizedDescription)")
                onChange?()
                return
            }
            onChange?()
        }
    }

    private func isCompleteAfterThis(_ stage: InstallStage) -> Bool {
        stages.filter { $0.info.id != stage.info.id }.allSatisfy { ctx.state.completed.contains($0.info.id) }
    }

    /// Retry a failed stage from scratch.
    public func resetFailure(_ id: String) {
        statuses[id] = .pending
        onChange?()
    }

    /// Undo this install: revert journaled edits and move the new app (if this install created it) to the Trash.
    /// Never touches the existing game apps, the shared runtime cache, or saves.
    public func removeUnfinishedInstall() -> String {
        let report = ctx.journal.revertAll()
        var lines = [report.summary]
        if ctx.state.createdTarget, FileManager.default.fileExists(atPath: ctx.targetApp.path) {
            do {
                try FileManager.default.trashItem(at: ctx.targetApp, resultingItemURL: nil)
                lines.append("Moved \(ctx.targetApp.lastPathComponent) to the Trash.")
            } catch { lines.append("Could not move the new app to the Trash: \(error.localizedDescription)") }
        }
        try? FileManager.default.trashItem(at: ctx.workDir, resultingItemURL: nil)
        return lines.joined(separator: "\n")
    }
}

/// Minimal lock-protected box.
public final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    public init(_ v: T) { _value = v }
    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
