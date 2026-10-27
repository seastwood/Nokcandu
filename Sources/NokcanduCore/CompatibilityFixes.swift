import Foundation

/// Optional, app-owned components. Community profiles can reference these IDs, never supply code,
/// downloads or patch bytes. DLLs are private to the selected executable's folder; Wine's system DLLs
/// and registry are untouched. File undo uses the same conflict-aware journal as other Nokcandu edits.
public enum CompatibilityFix: String, CaseIterable, Codable, Identifiable {
    case directx9Extras = "directx9-extras", d3d8to9, borderless
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .directx9Extras: "DirectX 9 extras"
        case .d3d8to9: "DirectX 8 compatibility"
        case .borderless: "Fullscreen (Borderless)"
        }
    }
    public var detail: String {
        switch self {
        case .directx9Extras: "Downloads Microsoft's shader libraries (d3dx9_43 and d3dcompiler_43) for missing effects or crashes while loading a match."
        case .d3d8to9: "Downloads d3d8to9 1.16.0 and uses the bundled DXVK 2.3 renderer. Try this when Older 3D games has visual glitches. For 32-bit DirectX 8 games."
        case .borderless: "Makes the game's window fill its screen without changing the Mac's display mode. Select Windowed inside the game first."
        }
    }
}

public enum CompatibilityFixes {
    private static let operationLock = NSLock()
    private static var activeApps: Set<String> = []
    static func begin(_ g: InstalledGame) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard activeApps.insert(g.id).inserted else { throw NokError("Another compatibility fix is still working on this game.") }
    }
    static func end(_ g: InstalledGame) {
        operationLock.lock(); defer { operationLock.unlock() }
        activeApps.remove(g.id)
    }
    struct State: Codable {
        var executable: String
        var previousOverrides: [String: String]
        var appliedOverrides: [String: String]
        var previousLegacy: Bool?
        var previousBorderless: Bool?
    }
    static func marker(_ fix: CompatibilityFix, _ g: InstalledGame) -> URL {
        g.nokcanduState.appendingPathComponent("fix-\(fix.rawValue).json")
    }
    static func journal(_ fix: CompatibilityFix, _ g: InstalledGame) -> ChangeJournal {
        ChangeJournal(scope: fix.rawValue, root: g.nokcanduState, portableRoot: g.appURL)
    }
    static func state(_ fix: CompatibilityFix, _ g: InstalledGame) -> State? {
        (try? Data(contentsOf: marker(fix, g))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }
    public static func isInstalled(_ fix: CompatibilityFix, for g: InstalledGame) -> Bool { state(fix, g) != nil }
    public static func installedIDs(for g: InstalledGame) -> [String] {
        CompatibilityFix.allCases.filter { isInstalled($0, for: g) }.map(\.rawValue)
    }
    static func fresh(_ g: InstalledGame) -> InstalledGame { GameLibrary.inspect(g.appURL) ?? g }
    static func program(_ g: InstalledGame) -> URL? {
        g.custom.flatMap { BattleNet.unixPath($0.exe, prefix: g.prefix) }
    }
    /// Restrict changes to standalone managed apps: shared launcher environments need per-program
    /// routing before these can safely be offered there.
    public static func unavailable(_ fix: CompatibilityFix, for g: InstalledGame) -> String? {
        guard g.custom != nil, !g.usesSharedSteam, g.battleNet == nil, g.hosted == nil,
              g.native == nil else { return "Available for games with their own Nokcandu Windows environment." }
        guard let exe = program(g), PEFile.inspect(exe) != nil,
              exe.resolvingSymlinksInPath().path.hasPrefix(g.prefix.appendingPathComponent("drive_c").resolvingSymlinksInPath().path + "/") else {
            return "Choose the game's program inside its own C: drive first."
        }
        if fix == .d3d8to9 {
            if PEFile.inspect(exe)?.is64Bit != false { return "This fix is for 32-bit DirectX 8 games." }
            if g.custom?.graphics != .classic3D { return "Choose Older 3D games in Settings first." }
            if !FileManager.default.fileExists(atPath: g.support.appendingPathComponent("renderer/dxvk/wine/i386-windows/d3d9.dll").path) {
                return "This Windows environment doesn't include the DXVK 2.3 compatibility renderer."
            }
        }
        return nil
    }
    static func requireClosed(_ g: InstalledGame) throws {
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit \(g.name) first.") }
    }
    /// Expand grouped Wine rules so changing d3d8 never accidentally removes a d3d9 rule.
    static func overrides(_ text: String?) -> [String: String] {
        var result: [String: String] = [:]
        for rule in (text ?? "").split(separator: ";") {
            let pair = rule.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            for dll in pair[0].split(separator: ",") {
                result[dll.trimmingCharacters(in: .whitespaces).lowercased()] = String(pair[1])
            }
        }
        return result
    }
    static func setOverrides(_ rules: [String: String], in c: inout CustomGameConfig) {
        var env = c.environment ?? [:]
        env["WINEDLLOVERRIDES"] = rules.isEmpty ? nil : rules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        c.environment = env.isEmpty ? nil : env
    }
    static func verifiedDownload(_ name: String, url: String, sha: String, log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let cached = NokPaths.downloads.appendingPathComponent(name)
        if (try? Hashing.sha256(file: cached)) == sha { return cached }
        log("Downloading \(name)…")
        let (temp, response) = try await URLSession.shared.download(from: URL(string: url)!)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, try Hashing.sha256(file: temp) == sha else {
            throw NokError("The download failed or didn't match the expected release. Nothing was installed.")
        }
        try NokPaths.ensure(NokPaths.downloads)
        try Data(contentsOf: temp).write(to: cached, options: .atomic)
        return cached
    }
    static func extras(for g: InstalledGame, work: URL, log: @escaping @Sendable (String) -> Void) async throws -> [String: Data] {
        // Pin for the current Microsoft-hosted June 2010 redistributable. Fetch from Microsoft;
        // extract only these two libraries, rather than installing the entire DirectX runtime.
        let redist = try await verifiedDownload("directx_Jun2010_redist.exe",
            url: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
            sha: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b", log: log)
        guard let cab = NokPaths.bundledResource("cabextract") else { throw NokError("Nokcandu is missing cabextract. Rebuild or update Nokcandu first.") }
        let arch = program(g).flatMap(PEFile.inspect)?.is64Bit == true ? "x64" : "x86"
        var files: [String: Data] = [:]
        for name in ["d3dx9_43", "d3dcompiler_43"] {
            let unpack = work.appendingPathComponent(name); try NokPaths.ensure(unpack)
            let outer = try await Shell.runAsync(cab.path, ["-q", "-L", "-F", "*\(name)*\(arch)*", "-d", unpack.path, redist.path], timeout: 120)
            guard outer.ok, let inner = try FileManager.default.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "cab" }) else {
                throw NokError("Couldn't extract Microsoft's \(name) package.")
            }
            let r = try await Shell.runAsync(cab.path, ["-q", "-L", "-F", "\(name).dll", "-d", unpack.path, inner.path], timeout: 120)
            guard r.ok else { throw NokError("Couldn't extract \(name).dll.") }
            files["\(name).dll"] = try Data(contentsOf: unpack.appendingPathComponent("\(name).dll"))
        }
        return files
    }
    /// Profile settings cannot silently disable components still installed on disk.
    static func preservingInstalledSettings(_ config: CustomGameConfig, for g: InstalledGame) -> CustomGameConfig {
        var c = config, rules = overrides(c.environment?["WINEDLLOVERRIDES"])
        if BF1942DisplayFix.isRecommended(for: g) { c.bf1942MenuCopy = true }
        for fix in CompatibilityFix.allCases {
            guard let st = state(fix, g) else { continue }
            for (name, order) in st.appliedOverrides { rules[name] = order }
            if fix == .borderless { c.borderless = true }
            if fix == .d3d8to9 { c.legacyD3D9 = true; c.graphics = .classic3D }
        }
        if CompatibilityFix.allCases.contains(where: { !(state($0, g)?.appliedOverrides.isEmpty ?? true) }) {
            setOverrides(rules, in: &c)
        }
        return c
    }
    public static func install(_ fix: CompatibilityFix, for game: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        let g = fresh(game)
        try begin(g); defer { end(g) }
        try await installReserved(fix, for: g, log: log)
    }
    static func installReserved(_ fix: CompatibilityFix, for g: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        try requireClosed(g)
        if isInstalled(fix, for: g) { throw NokError("This fix already has an installation record. Undo it before installing again.") }
        if let reason = unavailable(fix, for: g) { throw NokError(reason) }
        guard var c = g.custom, let exe = program(g) else { throw NokError("Choose the game's program first.") }
        let work = NokPaths.support.appendingPathComponent("Work/fix-\(UUID().uuidString)")
        try NokPaths.ensure(work); defer { try? FileManager.default.removeItem(at: work) }
        var files: [URL: Data] = [:], applied: [String: String] = [:]
        switch fix {
        case .directx9Extras:
            for (name, data) in try await extras(for: g, work: work, log: log) { files[exe.deletingLastPathComponent().appendingPathComponent(name)] = data }
            applied = ["d3dx9_43": "n,b", "d3dcompiler_43": "n,b"]
        case .d3d8to9:
            let dll = try await verifiedDownload("d3d8to9-1.16.0.dll", url: "https://github.com/crosire/d3d8to9/releases/download/v1.16.0/d3d8.dll",
                sha: "122928cfe225c25d30decf7184a5d37e490cecf3b58256ba3206c7e1853f8ab8", log: log)
            files[exe.deletingLastPathComponent().appendingPathComponent("d3d8.dll")] = try Data(contentsOf: dll)
            applied = ["d3d8": "n", "d3d9": "b"]
        case .borderless:
            let arch = PEFile.inspect(exe)?.is64Bit == true ? "x86_64" : "x86"
            for (name, ext) in [("launcher", "exe"), ("window", "dll")] {
                guard let source = NokPaths.bundledResource("borderless-\(arch).\(ext)") else { throw NokError("The borderless helper is missing. Rebuild or update Nokcandu first.") }
                files[g.prefix.appendingPathComponent("drive_c/nokcandu/borderless/\(name).\(ext)")] = try Data(contentsOf: source)
            }
        }
        // Downloads happen before mutation; recheck because the user could have started the game.
        try requireClosed(fresh(g))
        guard CustomGameConfig.load(contents: g.contents) == g.custom else { throw NokError("Game settings changed during download. Try again.") }
        let previous = overrides(c.environment?["WINEDLLOVERRIDES"])
        let st = State(executable: c.exe, previousOverrides: previous, appliedOverrides: applied,
                       previousLegacy: c.legacyD3D9, previousBorderless: c.borderless)
        let record = marker(fix, g)
        try NokPaths.ensure(record.deletingLastPathComponent())
        try JSONEncoder().encode(st).write(to: record, options: .atomic) // retain recovery if interrupted
        let j = journal(fix, g)
        do {
            for (url, data) in files { try j.write(data, to: url, reason: fix.title) }
            var rules = previous; for (dll, order) in applied { rules[dll] = order }
            if !applied.isEmpty { setOverrides(rules, in: &c) }
            if fix == .d3d8to9 { c.legacyD3D9 = true }
            if fix == .borderless { c.borderless = true }
            try CustomGames.save(c, to: g)
        } catch {
            let report = j.revertAll()
            log("Installation did not finish. \(report.summary) Use Undo to clear the recovery record.")
            throw error
        }
        log("Installed \(fix.title). Undo is available in Fixes.")
    }
    public static func undo(_ fix: CompatibilityFix, for game: InstalledGame, log: @escaping @Sendable (String) -> Void) throws {
        let g = fresh(game)
        try begin(g); defer { end(g) }
        try undoReserved(fix, for: g, log: log)
    }
    static func undoReserved(_ fix: CompatibilityFix, for g: InstalledGame, log: @escaping @Sendable (String) -> Void) throws {
        try requireClosed(g)
        guard let st = state(fix, g), var c = g.custom else { throw NokError("No installation record for this fix.") }
        // Restore only settings still owned by this fix; preserve later manual edits and other fixes.
        var rules = overrides(c.environment?["WINEDLLOVERRIDES"])
        for (dll, applied) in st.appliedOverrides {
            guard rules[dll] == applied || rules[dll] == st.previousOverrides[dll] else { throw NokError("The \(dll) setting changed after installation. Restore that setting before Undo; files were left alone.") }
            rules[dll] = st.previousOverrides[dll]
        }
        if !st.appliedOverrides.isEmpty { setOverrides(rules, in: &c) }
        if fix == .d3d8to9, c.legacyD3D9 == true { c.legacyD3D9 = st.previousLegacy }
        if fix == .borderless, c.borderless == true { c.borderless = st.previousBorderless }
        let j = journal(fix, g)
        // Check every owned file before changing settings or moving any files.
        for path in j.touchedPaths {
            if let last = j.entries.last(where: { $0.path == path }), let sha = last.shaAfter,
               (try? Hashing.sha256(file: URL(fileURLWithPath: path))) != sha {
                throw NokError("\((path as NSString).lastPathComponent) changed after installation. Undo kept your files and settings.")
            }
        }
        try CustomGames.save(c, to: g)
        let report = j.revertAll(); log(report.summary)
        guard report.skipped.isEmpty else { throw NokError(report.summary) }
        try FileManager.default.removeItem(at: marker(fix, g))
        log("Removed \(fix.title).")
    }
}
