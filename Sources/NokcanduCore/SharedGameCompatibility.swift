import Foundation
import Darwin

/// Components belong to the game shortcut and its registered content, never to the client.
/// The helper reads exact-program routes before Wine initializes its DLL search paths.
enum SharedGameCompatibility {
    private static let discoveryLock = NSLock()
    private static var discovered: [String: URL] = [:]
    private static func discoveredProgram(in root: URL, name: String) -> URL? {
        let stamp = (try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = root.path + "|" + name + "|" + String(stamp)
        discoveryLock.lock(); let cached = discovered[key]; discoveryLock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let program = SharedSteam.mainExecutable(in: root, gameName: name) else { return nil }
        discoveryLock.lock(); discovered[key] = program; discoveryLock.unlock()
        return program
    }
    struct Target {
        var host: InstalledGame
        var root: URL
        var program: URL
        var windows: String
    }
    static func isShared(_ g: InstalledGame) -> Bool { g.usesSharedSteam || g.hosted != nil || g.battleNet != nil }
    static func location(_ g: InstalledGame) -> LauncherInstallation.Location? {
        guard let location = LauncherInstallation.location(for: g), LauncherInstallation.presence(at: location.folder) == .present else { return nil }
        let root = location.folder.resolvingSymlinksInPath().standardizedFileURL
        let sharedNames: Set<String> = ["games", "ea games", "ea app games", "gog games", "steamapps", "common", "program files", "program files (x86)", "applications", "users", "windows", "programdata", "documents", "downloads", "desktop"]
        guard root.path != "/", !(root.path.hasPrefix("/Volumes/") && root.pathComponents.count <= 3), !sharedNames.contains(root.lastPathComponent.lowercased()) else { return nil }
        let boundaries = [FileManager.default.homeDirectoryForCurrentUser, location.host.appURL, location.host.prefix] + GameFolders.all + Drives.list(for: location.host).map { URL(fileURLWithPath: $0.target) }
        guard !boundaries.contains(where: { boundary in
            let path = boundary.resolvingSymlinksInPath().path
            return root.path == path || path.hasPrefix(root.path + "/")
        }) else { return nil }
        let protected = ["windows", "ProgramData", "nokcandu", "Program Files/Common Files", "Program Files (x86)/Common Files"].map { location.host.prefix.appendingPathComponent("drive_c/" + $0) }
        guard !protected.contains(where: { LauncherInstallation.overlap(root, $0) }),
              !location.otherFolders.contains(where: { LauncherInstallation.overlap(root, $0) }) else { return nil }
        // Games installed under a client's games/ subfolder are valid. Reject only
        // roots containing the client itself, not descendants of its container.
        let client = location.host.custom.flatMap { LauncherInstallation.windowsFolder($0.exe, prefix: location.host.prefix) }
            ?? location.host.recipe.flatMap { recipe in location.host.gameDirectory?.appendingPathComponent(recipe.primaryExecutable) }
        if let client, client.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") { return nil }
        return location
    }
    static func windowsPaths(_ file: URL, host: InstalledGame) -> Set<String> {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return Set(Drives.list(for: host).compactMap { drive in
            let root = URL(fileURLWithPath: drive.target).resolvingSymlinksInPath().standardizedFileURL.path
            guard root == "/" || path.hasPrefix(root + "/") else { return nil }
            let relative = path.dropFirst(root == "/" ? 1 : root.count + 1)
            return drive.letter + ":\\" + relative.replacingOccurrences(of: "/", with: "\\")
        })
    }
    static func target(_ g: InstalledGame) -> Target? {
        guard isShared(g), let location = location(g) else { return nil }
        let root = location.folder.resolvingSymlinksInPath().standardizedFileURL
        let selected = try? String(contentsOf: g.nokcanduState.appendingPathComponent("compatibility-program"), encoding: .utf8)
        let boundPrograms = Set(CompatibilityFix.allCases.compactMap { CompatibilityFixes.state($0, g)?.executable })
        guard boundPrograms.count <= 1 else { return nil }
        let bound = selected ?? boundPrograms.first
        let registered = g.battleNet.flatMap { link in BattleNet.registeredGames(host: location.host).first { $0.uid == link.uid }?.exe }
        var windows = bound ?? g.hosted?.exe ?? registered
        if let old = windows {
            windows = old.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if windows?.hasSuffix(",0") == true { windows = String(windows!.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        var program = windows.flatMap { LauncherInstallation.windowsFolder($0, prefix: location.host.prefix) }
        if bound != nil, program == nil { return nil }
        if program == nil, let found = discoveredProgram(in: root, name: g.name) {
            program = found; windows = windowsPaths(found, host: location.host).sorted().first
        }
        guard let program, let windows, PEFile.inspect(program) != nil,
              program.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.path + "/") else { return nil }
        return Target(host: location.host, root: root, program: program, windows: windows)
    }
    static func configuration(_ g: InstalledGame, target: Target) -> CustomGameConfig {
        let hosted = g.hosted == nil ? nil : HostedSettings.load(g)
        var config = g.custom ?? CustomGameConfig(id: g.bundleIdentifier ?? g.id, name: g.name, source: .folder,
                                                  exe: target.windows, graphics: .classic3D)
        config.exe = target.windows
        if let hosted { config.graphics = hosted.graphics ?? target.host.custom?.graphics ?? .classic3D; config.environment = hosted.environment; config.arguments = hosted.arguments; config.borderless = hosted.borderless; config.macFullScreen = hosted.macFullScreen; config.launcherSHA = hosted.launcherSHA }
        if g.battleNet != nil { config.graphics = BattleNetGraphics.choice(g) ?? target.host.custom?.graphics ?? .classic3D; config.environment = (target.host.custom?.environment ?? [:]).merging(BattleNetGraphics.environment(g)) { _, gameValue in gameValue } }
        if g.custom == nil { config.createdAt = Date(timeIntervalSince1970: 0) }
        return config
    }
    static func unavailable(_ fix: CompatibilityFix, for g: InstalledGame, graphics: GraphicsPreset? = nil) -> String? {
        guard let target = target(g) else { return "The launcher's registered game folder and Windows program must be available. Choose the game's program for fixes below if it cannot be identified." }
        var config = configuration(g, target: target)
        if let graphics { config.graphics = graphics }
        switch fix {
        case .bf2DeploymentUI:
            return "This BF2 workaround currently requires its own Windows environment. Shared launchers are left unchanged."
        case .ipxNetworking, .nativeIPXNetworking:
            return "This networking component currently needs a private Windows environment; it cannot change a shared launcher's networking for only one game."
        case .ubisoftBrowser: return "Install this on the Ubisoft Connect launcher itself."
        case .borderless where g.hosted?.launcher != .ea:
            return "This launch method cannot yet wrap an individual game's start for this component. Per-game DLL and renderer fixes are available."
        case .bf1942SoftwareAudio where !BF1942AudioFix.supports(g): return "BF1942's active-player sound settings could not be identified."
        case .openUA where !OpenUASettings.supports(g): return "Requires OpenUA's program, NUCLEUS.INI and game data."
        case .bundledVC where CompatibilityFixes.bundledVCRules(g).isEmpty: return "No matching Visual C++ libraries were found beside this game."
        case .crossProcessWindows where config.graphics != .dxmt, .dxmtLowMemory where config.graphics != .dxmt:
            return "Choose Metal for DirectX 10–11 (DXMT) for this game first."
        case .cursorVisibility where BF1942DisplayFix.folder(g) != nil: return "Temporarily unavailable for BF1942 because it can flicker."
        case .dgVoodoo: return "Not yet available for games inside a shared launcher; it's for games with their own Nokcandu Windows environment."
        case .d3d8to9:
            guard CompatibilityFixes.directX8Program(g) != nil else { return "Requires a 32-bit game or one identifiable adjacent 32-bit DirectX 8 program." }
            guard config.graphics == .classic3D else { return "Choose Older 3D games for this game first." }
            guard FileManager.default.fileExists(atPath: target.host.support.appendingPathComponent("renderer/dxvk/wine/i386-windows/d3d9.dll").path) else { return "The shared engine is missing its DirectX 9 compatibility renderer. Repair the launcher first." }
        default: break
        }
        return nil
    }
    static func install(_ fix: CompatibilityFix, for g: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        try CompatibilityFixes.requireClosed(g)
        guard !CompatibilityFixes.isInstalled(fix, for: g) else { throw NokError("Undo this component before installing it again.") }
        if let reason = unavailable(fix, for: g) { throw NokError(reason) }
        guard let before = target(g) else { throw NokError("The game program is unavailable.") }
        let config = configuration(g, target: before)
        let executableHash = try Hashing.sha256(file: before.program)
        if g.hosted?.launcher == .ea { try HostedSettings.validateLauncher(g) }
        let (files, rules, environment) = try await CompatibilityFixes.payload(fix, for: g, log: log)
        try CompatibilityFixes.requireClosed(g)
        let current = CompatibilityFixes.fresh(g)
        guard let after = target(current), after.program.resolvingSymlinksInPath() == before.program.resolvingSymlinksInPath(),
              configuration(current, target: after) == config, (try? Hashing.sha256(file: after.program)) == executableHash else { throw NokError("Game settings changed during the download. Try again.") }
        if g.hosted?.launcher == .ea { try HostedSettings.validateLauncher(g) }
        var state = CompatibilityFixes.State(executable: before.windows, previousOverrides: CompatibilityFixes.overrides(config.environment?["WINEDLLOVERRIDES"]),
                                             appliedOverrides: rules, previousLegacy: nil, previousBorderless: config.borderless, appliedEnvironment: environment, sharedActive: false)
        let marker = CompatibilityFixes.marker(fix, g), journal = CompatibilityFixes.journal(fix, g)
        try NokPaths.ensure(g.nokcanduState)
        try JSONEncoder().encode(state).write(to: marker, options: .atomic)
        do {
            for (url, data) in files {
                if fix == .bf1942SoftwareAudio { try journal.writeSettings(data, to: url, keys: [BF1942AudioFix.key], reason: fix.title) }
                else if fix == .openUA { try journal.writeSettings(data, to: url, keys: ["gfx.vbo", "menu.windowed", "gfx.custommodes"], reason: fix.title) }
                else { try journal.write(data, to: url, reason: fix.title) }
            }
            state.sharedActive = true
            try JSONEncoder().encode(state).write(to: marker, options: .atomic)
            try refresh(g)
        } catch {
            state.sharedActive = false
            try? JSONEncoder().encode(state).write(to: marker, options: .atomic)
            try? refresh(g)
            log("The component did not finish. \(journal.revertAll().summary) Use Undo to clear its recovery record.")
            throw error
        }
        CompanionRepair.snapshot(g)
        log("Installed \(fix.title) for \(g.name) only. Undo is available in Fixes.")
    }
    static func undo(_ fix: CompatibilityFix, for g: InstalledGame, log: @escaping @Sendable (String) -> Void) throws {
        try CompatibilityFixes.requireClosed(g)
        guard let state = CompatibilityFixes.state(fix, g), let target = target(g),
              let original = LauncherInstallation.windowsFolder(state.executable, prefix: target.host.prefix),
              original.resolvingSymlinksInPath() == target.program.resolvingSymlinksInPath() else {
            throw NokError("The game's program or registered location changed. Locate the original installation before Undo; its files were preserved.")
        }
        if g.hosted?.launcher == .ea { try HostedSettings.validateLauncher(g) }
        let journal = CompatibilityFixes.journal(fix, g)
        let roots = [target.root.path + "/", g.nokcanduState.resolvingSymlinksInPath().path + "/"]
        guard journal.touchedPaths.allSatisfy({ path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return roots.contains { resolved.hasPrefix($0) }
        }) else { throw NokError("The component's recorded folder no longer matches this game. Its files were preserved.") }
        try journal.validateForUndo()
        let report = journal.revertAll(); log(report.summary)
        guard report.skipped.isEmpty else { throw NokError(report.summary) }
        try FileManager.default.removeItem(at: CompatibilityFixes.marker(fix, g))
        if fix == .borderless, g.hosted != nil {
            var settings = HostedSettings.load(g)
            if settings.borderless == true { settings.borderless = state.previousBorderless; try HostedSettings.save(settings, for: g) }
        }
        try refresh(g)
    }
    /// Merge component-owned rules with the game's own environment, without saving them into the client.
    static func environment(_ g: InstalledGame, base: [String: String], support: URL) -> [String: String] {
        var result = base, rules = CompatibilityFixes.overrides(base["WINEDLLOVERRIDES"])
        for fix in CompatibilityFix.allCases {
            guard let state = CompatibilityFixes.state(fix, g), state.sharedActive != false else { continue }
            for (key, value) in state.appliedOverrides { rules[key] = value }
            for (key, value) in state.appliedEnvironment ?? [:] { result[key] = value }
        }
        if !rules.isEmpty { result["WINEDLLOVERRIDES"] = rules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";") }
        if isActive(.d3d8to9, g) { result["WINEDLLPATH_D9VK"] = support.appendingPathComponent("renderer/dxvk/wine").path }
        result["NOKCANDU_GAME_FIX_STATE"] = g.nokcanduState.path
        if GameMicrophone.supported(g) { result["NOKCANDU_NO_MICROPHONE"] = GameMicrophone.isOn(g) ? "0" : "1" }
        return result
    }
    static func isActive(_ fix: CompatibilityFix, _ g: InstalledGame) -> Bool {
        guard let state = CompatibilityFixes.state(fix, g) else { return false }
        return state.sharedActive != false
    }
    static func refresh(_ g: InstalledGame) throws {
        try writeRoutes(g)
        if g.hosted?.launcher == .ea { try HostedSettings.save(HostedSettings.load(g), for: g) }
    }
    static func writeRoutes(_ g: InstalledGame) throws {
        guard isShared(g), let host = WineTools.hostContents(for: g) else { return }
        let file = host.appendingPathComponent("SharedSupport/nokcandu/program-fixes.tsv")
        let owner = Hashing.sha256(data: Data((g.bundleIdentifier ?? g.id).utf8))
        // Serialize updates from independently running apps, preserving other games' rows.
        try NokPaths.ensure(file.deletingLastPathComponent())
        guard file.resolvingSymlinksInPath() == file else { throw NokError("The game-fix routing file was linked; it was preserved.") }
        let fd = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NokError("Couldn't lock the per-game fix routes.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NokError("Couldn't reserve the per-game fix routes.") }
        defer { flock(fd, LOCK_UN) }
        var lines = ((try? String(contentsOf: file)) ?? "").split(separator: "\n").map(String.init).filter { !$0.hasPrefix(owner + "\t") }
        if g.battleNet != nil || (g.usesSharedSteam && !(g.custom?.environment?.isEmpty ?? true)) || CompatibilityFix.allCases.contains(where: { isActive($0, g) }), let target = target(g) {
            let config = configuration(g, target: target)
            let graphics: GraphicsPreset = isActive(.d3d8to9, g) ? .classic3D : config.graphics
            var base = graphics.programEnvironment(support: target.host.support.path, contents: target.host.contents.path)
            try NokPaths.ensure(g.logs)
            base["DXVK_LOG_PATH"] = g.logs.path; base["DXMT_LOG_PATH"] = g.logs.path
            for (key, value) in config.environment ?? [:] where CustomGames.isValidEnvName(key) { base[key] = value }
            // Preserve the renderer's built-in DLL rules while applying game-specific ones.
            base["WINEDLLOVERRIDES"] = graphics.mergedDLLOverrides(config.environment?["WINEDLLOVERRIDES"] ?? "")
            let fields = environment(g, base: base, support: target.host.support).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            var paths = Set([target.windows, target.program.path, target.program.resolvingSymlinksInPath().path,
                             "Z:" + target.program.resolvingSymlinksInPath().path.replacingOccurrences(of: "/", with: "\\")])
            paths.formUnion(windowsPaths(target.program, host: target.host))
            if let cPath = CustomGames.windowsPath(forUnix: target.program, prefix: target.host.prefix) { paths.insert(cPath) }
            for path in [g.hosted?.exe, g.battleNet.flatMap { link in BattleNet.registeredGames(host: target.host).first { $0.uid == link.uid }?.exe }].compactMap({ $0 }) {
                if let file = LauncherInstallation.windowsFolder(path, prefix: target.host.prefix), file.resolvingSymlinksInPath() == target.program.resolvingSymlinksInPath() { paths.insert(path) }
            }
            if isActive(.d3d8to9, g), let renderer = CompatibilityFixes.directX8Program(g), renderer != target.program {
                paths.insert(renderer.path)
                paths.formUnion(windowsPaths(renderer, host: target.host))
                paths.insert("Z:" + renderer.resolvingSymlinksInPath().path.replacingOccurrences(of: "/", with: "\\"))
                if let slash = target.windows.lastIndex(of: "\\") { paths.insert(String(target.windows[...slash]) + renderer.lastPathComponent) }
            }
            for path in paths.sorted() {
                let values = [owner, path] + fields
                guard values.allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }), values.joined(separator: "\t").utf8.count < 8190 else { throw NokError("Game-fix routing settings are too long or contain control characters.") }
                lines.append(values.joined(separator: "\t"))
            }
        }
        let data = Data((lines.isEmpty ? "" : lines.sorted().joined(separator: "\n") + "\n").utf8)
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
    }
}
