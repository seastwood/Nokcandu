import Foundation

// MARK: - Versions

/// A Sikarugir Wine engine version, e.g. WS12WineSikarugir11.0_1 = "wine sikarugir 11.0 (revision 1)".
public struct EngineVersion: Comparable, Hashable, Codable, CustomStringConvertible {
    public var major: Int, minor: Int, revision: Int

    public init(major: Int, minor: Int, revision: Int) { self.major = major; self.minor = minor; self.revision = revision }

    /// From a release asset name like "WS12WineSikarugir11.0_1.tar.xz" (other engine families are ignored).
    public init?(assetName: String) {
        guard let m = assetName.firstMatch(of: #/^WS12WineSikarugir(\d+)\.(\d+)(?:_(\d+))?\.tar\.xz$/#) else { return nil }
        major = Int(m.1)!; minor = Int(m.2)!; revision = m.3.flatMap { Int($0) } ?? 0
    }

    /// From an engine's version file: "wine sikarugir 10.0 (revision 8)" or "wine sikarugir 10.0".
    public init?(versionString: String) {
        guard let m = versionString.firstMatch(of: #/sikarugir (\d+)\.(\d+)(?: \(revision (\d+)\))?/#) else { return nil }
        major = Int(m.1)!; minor = Int(m.2)!; revision = m.3.flatMap { Int($0) } ?? 0
    }

    public var tag: String { "\(major).\(minor)" + (revision > 0 ? "_\(revision)" : "") }
    public var engineName: String { "WS12WineSikarugir" + tag }
    public var versionString: String { "wine sikarugir \(major).\(minor)" + (revision > 0 ? " (revision \(revision))" : "") }
    public var description: String { "Wine \(major).\(minor)" + (revision > 0 ? " r\(revision)" : "") }

    public static func < (a: Self, b: Self) -> Bool { (a.major, a.minor, a.revision) < (b.major, b.minor, b.revision) }

    /// The engine Nokcandu's recipes were validated with.
    public static let tested = EngineVersion(versionString: RecipeCatalog.sikarugirWine10.wineVersionString)!
}

/// Sikarugir wrapper template version (Frameworks, graphics translators, Vulkan driver), e.g. 1.0.24.
public struct TemplateVersion: Comparable, Hashable, Codable, CustomStringConvertible {
    public var parts: [Int]
    public init(_ parts: [Int]) { self.parts = parts }
    public init?(assetName: String) {
        guard let m = assetName.firstMatch(of: #/^Template-(\d+(?:\.\d+)+)\.tar\.xz$/#) else { return nil }
        parts = m.1.split(separator: ".").compactMap { Int($0) }
    }
    public init?(string: String) {
        guard let m = string.firstMatch(of: #/(\d+(?:\.\d+)+)/#) else { return nil }
        parts = m.1.split(separator: ".").compactMap { Int($0) }
    }
    public var description: String { parts.map(String.init).joined(separator: ".") }
    public static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public static let tested = TemplateVersion(string: RecipeCatalog.sikarugirWine10.template)!
}

public struct ReleaseAsset: Codable, Hashable {
    public var name: String
    public var size: Int64
    public var url: URL
    /// SHA-256 published by GitHub for the asset. Assets without one are never installed.
    public var sha256: String?
    public var updated: Date?
}

// MARK: - Update catalog

/// What's available upstream. Fetched from GitHub's public release API at most once a day (or on demand).
public struct UpdateCatalog: Codable {
    public var checkedAt: Date
    public var engines: [ReleaseAsset]
    public var templates: [ReleaseAsset]
    public var lav: CinematicFix.Release?
    /// Engine builds that run natively on Apple silicon (none exist yet; watched for macOS 28).
    public var nativeEngines: [String]

    public var latestEngine: (version: EngineVersion, asset: ReleaseAsset)? {
        engines.compactMap { a in EngineVersion(assetName: a.name).map { ($0, a) } }
            .filter { $0.1.sha256 != nil }.max { $0.0 < $1.0 }
    }
    public var latestTemplate: (version: TemplateVersion, asset: ReleaseAsset)? {
        templates.compactMap { a in TemplateVersion(assetName: a.name).map { ($0, a) } }
            .filter { $0.1.sha256 != nil }.max { $0.0 < $1.0 }
    }
    public func template(_ v: TemplateVersion) -> ReleaseAsset? { templates.first { TemplateVersion(assetName: $0.name) == v && $0.sha256 != nil } }
    public func engine(_ v: EngineVersion) -> ReleaseAsset? { engines.first { EngineVersion(assetName: $0.name) == v && $0.sha256 != nil } }
}

public enum Updates {
    static var catalogURL: URL { NokPaths.support.appendingPathComponent("updates.json") }

    public static func cached() -> UpdateCatalog? {
        guard let d = try? Data(contentsOf: catalogURL) else { return nil }
        return try? ChangeJournal.decoder.decode(UpdateCatalog.self, from: d)
    }

    public static var isStale: Bool { (cached()?.checkedAt).map { Date().timeIntervalSince($0) > 86_400 } ?? true }

    struct GHRelease: Decodable { var tag_name: String; var assets: [GHAsset] }
    struct GHAsset: Decodable { var name: String; var size: Int64; var browser_download_url: URL; var digest: String?; var updated_at: Date? }

    static func releases(_ repo: String, perPage: Int = 5) async throws -> [GHRelease] {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=\(perPage)")!)
        req.setValue("Nokcandu", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw NokError("GitHub answered \(code) for \(repo)" + (code == 403 ? " (rate limit; try again in an hour)." : ".")) }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([GHRelease].self, from: data)
    }

    static func asset(_ a: GHAsset) -> ReleaseAsset {
        var sha: String?
        if let d = a.digest, d.hasPrefix("sha256:") { sha = String(d.dropFirst(7)).lowercased() }
        return ReleaseAsset(name: a.name, size: a.size, url: a.browser_download_url, sha256: sha, updated: a.updated_at)
    }

    /// Asks GitHub what's new. Saves the result for the next launch.
    @discardableResult
    public static func check() async throws -> UpdateCatalog {
        async let eng = releases("Sikarugir-App/Engines", perPage: 3)
        async let tpl = releases("Sikarugir-App/Template", perPage: 3)
        async let lav = releases("Nevcairiel/LAVFilters", perPage: 1)
        let engines = try await eng.flatMap(\.assets).map(asset)
        let templates = try await tpl.flatMap(\.assets).map(asset)
        var lavRelease: CinematicFix.Release?
        if let r = (try? await lav)?.first {
            var sha: [String: String] = [:]
            for a in r.assets.map(asset) {
                for arch in CinematicFix.Arch.allCases where a.name == "LAVFilters-\(r.tag_name)-\(arch.rawValue).zip" { sha[arch.rawValue] = a.sha256 }
            }
            if sha.count == CinematicFix.Arch.allCases.count { lavRelease = CinematicFix.Release(version: r.tag_name, sha: sha) }
        }
        let native = engines.map(\.name).filter { $0.range(of: #"arm64|aarch64|native"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let cat = UpdateCatalog(checkedAt: Date(), engines: engines, templates: templates, lav: lavRelease, nativeEngines: native)
        try NokPaths.ensure(NokPaths.support)
        try ChangeJournal.encoder.encode(cat).write(to: catalogURL, options: .atomic)
        return cat
    }

    /// Downloads a release asset into Nokcandu's Downloads (reused if already there) and checks its SHA-256.
    static func download(_ a: ReleaseAsset, log: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard let want = a.sha256 else { throw NokError("\(a.name) has no published checksum; Nokcandu won't install it.") }
        try NokPaths.ensure(NokPaths.downloads)
        let dest = NokPaths.downloads.appendingPathComponent(a.name)
        if FileManager.default.fileExists(atPath: dest.path), (try? Hashing.sha256(file: dest)) == want { return dest }
        log("Downloading \(a.name) (\(ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file)))…")
        let (tmp, resp) = try await URLSession.shared.download(from: a.url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NokError("Download of \(a.name) failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)).") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        guard (try? Hashing.sha256(file: dest)) == want else {
            try? FileManager.default.removeItem(at: dest)
            throw NokError("\(a.name) didn't match its published checksum; it was deleted and nothing changed.")
        }
        log("Verified \(a.name).")
        return dest
    }
}

// MARK: - Building a runtime from an engine + template

extension RuntimeManager {
    public static func runtimeID(engine: EngineVersion, template: TemplateVersion) -> String { "sikarugir-\(template)-wine-\(engine.tag)" }

    public static func isCached(id: String) -> Bool {
        manifest(for: id) != nil &&
        components.allSatisfy { FileManager.default.fileExists(atPath: folder(for: id).appendingPathComponent("Contents/\($0)").path) }
    }

    /// Runtimes in the cache, newest engine first.
    public static func cachedRuntimes() -> [RuntimeManifest] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: NokPaths.runtimes.path)) ?? []
        return ids.filter { !$0.hasPrefix(".") && isCached(id: $0) }.compactMap(manifest(for:))
            .sorted { (EngineVersion(versionString: $0.wineVersion) ?? .tested) > (EngineVersion(versionString: $1.wineVersion) ?? .tested) }
    }

    public static let templateParts = ["Frameworks", "SharedSupport/renderer", "Resources/vulkan"]

    /// Assembles engine + template into Nokcandu's runtime cache (downloads only what's missing; reuses the
    /// template parts of an already-cached runtime with the same template version).
    public static func build(engine: EngineVersion, template: TemplateVersion, catalog: UpdateCatalog,
                             log: @escaping @Sendable (String) -> Void) async throws -> String {
        let id = runtimeID(engine: engine, template: template)
        if isCached(id: id) {
            if manifest(for: id)?.selfTest == nil { try await runSelfTest(id: id, log: log) }
            return id
        }
        if EngineSelfTests.failed(id) { throw NokError("\(engine) with template \(template) already failed Nokcandu's test on this Mac. It isn't offered until a newer build appears.") }
        let fm = FileManager.default
        let work = NokPaths.support.appendingPathComponent("Work/runtime-\(UUID().uuidString.prefix(6))")
        let staging = NokPaths.runtimes.appendingPathComponent(".\(id)-incoming")
        try NokPaths.ensure(work); try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: work) }

        // Engine
        guard let engAsset = catalog.engine(engine) else { throw NokError("\(engine) isn't in the latest release list. Check for updates again.") }
        let engZip = try await Updates.download(engAsset, log: log)
        log("Unpacking \(engine)…")
        let ex = work.appendingPathComponent("engine")
        try NokPaths.ensure(ex)
        let r1 = try await Shell.runAsync("/usr/bin/tar", ["-xJf", engZip.path, "-C", ex.path], timeout: 900)
        guard r1.ok else { throw NokError("Couldn't unpack the engine: \(r1.combined.suffix(300))") }
        let bundle = ex.appendingPathComponent("wswine.bundle")
        let verText = (try? String(contentsOf: bundle.appendingPathComponent("version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard EngineVersion(versionString: verText) == engine, fm.isExecutableFile(atPath: bundle.appendingPathComponent("bin/wine").path) else {
            throw NokError("The downloaded engine doesn't look like \(engine) (version file says \"\(verText)\"). Nothing changed.")
        }
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/SharedSupport"), withIntermediateDirectories: true)
        try fm.moveItem(at: bundle, to: staging.appendingPathComponent("Contents/SharedSupport/wine"))

        // Template parts
        if let donor = cachedRuntimes().first(where: { TemplateVersion(string: $0.template) == template }) {
            log("Reusing graphics/wrapper files from template \(template).")
            for p in templateParts {
                try fm.cloneItem(at: folder(for: donor.id).appendingPathComponent("Contents/\(p)"), to: staging.appendingPathComponent("Contents/\(p)"))
            }
        } else {
            guard let tAsset = catalog.template(template) else { throw NokError("Template \(template) isn't available. Check for updates again.") }
            let tZip = try await Updates.download(tAsset, log: log)
            log("Unpacking template \(template)…")
            let tx = work.appendingPathComponent("template")
            try NokPaths.ensure(tx)
            let r2 = try await Shell.runAsync("/usr/bin/tar", ["-xJf", tZip.path, "-C", tx.path], timeout: 900)
            guard r2.ok else { throw NokError("Couldn't unpack the template: \(r2.combined.suffix(300))") }
            guard let app = try fm.contentsOfDirectory(at: tx, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                throw NokError("The template download has no app inside.")
            }
            for p in templateParts {
                let src = app.appendingPathComponent("Contents/\(p)")
                guard fm.fileExists(atPath: src.path) else { throw NokError("Template \(template) is missing \(p).") }
                try fm.createDirectory(at: staging.appendingPathComponent("Contents/\(p)").deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: staging.appendingPathComponent("Contents/\(p)"))
            }
        }
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])

        let wineSHA = try Hashing.sha256(file: staging.appendingPathComponent("Contents/SharedSupport/wine/bin/wine"))
        let m = RuntimeManifest(id: id, engine: engine.engineName, wineVersion: engine.versionString, template: "Sikarugir \(template)",
                                importedFrom: engAsset.url.absoluteString, importedAt: Date(),
                                verifiedHashes: ["SharedSupport/wine/bin/wine": wineSHA],
                                licenses: ["Wine (Sikarugir engine \(engine.engineName)): LGPL-2.1-or-later — https://github.com/Sikarugir-App/Engines",
                                           "Sikarugir wrapper template \(template): see the Sikarugir project licenses"])
        try ChangeJournal.encoder.encode(m).write(to: staging.appendingPathComponent("manifest.json"))
        let dest = folder(for: id)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)
        try? fm.removeItem(at: engZip)          // the unpacked cache is what counts; free the space
        try await runSelfTest(id: id, log: log)
        log("\(engine) with template \(template) is ready.")
        return id
    }

    /// Runs `cmd /c ver` with this runtime in a throwaway Windows environment. A runtime that can't run a
    /// Windows program is removed from the cache and remembered as failed, so no game is offered it.
    static func runSelfTest(id: String, log: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let c = folder(for: id).appendingPathComponent("Contents")
        let scratch = NokPaths.support.appendingPathComponent("Work/selftest-\(UUID().uuidString.prefix(6))")
        try NokPaths.ensure(scratch)
        defer { try? fm.removeItem(at: scratch) }
        var env = WineTools.environment(contents: c)
        env["WINEPREFIX"] = scratch.appendingPathComponent("prefix").path
        log("Testing \(id) in a scratch Windows environment…")
        let wine = c.appendingPathComponent("SharedSupport/wine/bin/wine").path
        let r = try await Shell.runAsync(wine, ["cmd", "/c", "ver"], env: env, timeout: 300)
        _ = try? await Shell.runAsync(c.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-k"], env: env, timeout: 60)
        let ok = r.stdout.contains("Windows")
        if ok, var m = manifest(for: id) {
            m.selfTest = true
            try ChangeJournal.encoder.encode(m).write(to: folder(for: id).appendingPathComponent("manifest.json"))
            EngineSelfTests.record(id, passed: true)
            log("Self-test passed: \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
            // Nokcandu's audio fixes find exact bytes in Wine's audio driver; say so if a new engine changed them.
            switch AudioBuffer.status(host: c) {
            case .needsFix, .fixed: log("Audio driver recognized: microphone fix and audio buffer will apply.")
            case .unrecognized: log("⚠︎ This engine's audio driver isn't one Nokcandu knows: microphones may not work in games that switch to it, and the audio buffer setting won't be available. Please report it on GitHub.")
            case .missing: log("⚠︎ This engine has no Mac audio driver where Nokcandu expects it.")
            }
        } else {
            EngineSelfTests.record(id, passed: false)
            try? fm.removeItem(at: folder(for: id))
            throw NokError("\(id) can't run Windows programs on this Mac (self-test failed), so it was removed and won't be offered. Your games keep their current engine.")
        }
    }

    /// Removes cached runtimes no game uses (keeps the tested one). Returns bytes freed (approximate).
    public static func removeUnused(games: [InstalledGame]) -> [String] {
        let inUse = Set(games.compactMap { EngineUpdate.state(for: $0)?.runtimeID } + [RecipeCatalog.sikarugirWine10.id])
            .union(games.compactMap { EngineUpdate.state(for: $0)?.previousRuntimeID })
        var removed: [String] = []
        for m in cachedRuntimes() where !inUse.contains(m.id) {
            if (try? FileManager.default.removeItem(at: folder(for: m.id))) != nil { removed.append(m.id) }
        }
        return removed
    }
}

// MARK: - Per-game engine update with rollback

/// Moves one app (a game, Battle.net, or the shared Steam) to a different engine + template, keeping the old
/// one and the old Windows system files so it can be rolled back exactly. Saves, game files and settings
/// are never touched.
public enum EngineUpdate {
    public struct State: Codable, Equatable {
        public enum Status: String, Codable { case trying, kept }
        public var runtimeID: String
        public var engine: String              // version string now in use
        public var previousEngine: String
        public var previousRuntimeID: String?
        public var appliedAt: Date
        public var status: Status
    }

    static func stateURL(_ c: URL) -> URL { c.appendingPathComponent("SharedSupport/nokcandu/engine.json") }
    static func rollbackDir(_ c: URL) -> URL { c.appendingPathComponent("SharedSupport/nokcandu/engine-rollback", isDirectory: true) }
    /// Parts of the prefix a Wine update rewrites (wineboot -u). Everything else in drive_c stays.
    static let prefixParts = ["drive_c/windows", "system.reg", "user.reg", "userdef.reg", ".update-timestamp"]

    public static func state(for g: InstalledGame) -> State? {
        guard !g.usesSharedSteam, let d = try? Data(contentsOf: stateURL(g.contents)) else { return nil }
        return try? ChangeJournal.decoder.decode(State.self, from: d)
    }

    public static func current(_ g: InstalledGame) -> EngineVersion? { g.wineVersion.flatMap(EngineVersion.init(versionString:)) }

    /// Apps that have their own engine (games, Battle.net, the shared Steam). Steam games use the shared Steam's.
    public static func hosts(in games: [InstalledGame]) -> [InstalledGame] {
        games.filter { !$0.usesSharedSteam && WineTools.hostContents(for: $0) == $0.contents }
    }

    static func wineEnv(_ c: URL) -> [String: String] { WineTools.environment(contents: c) }

    public static func apply(_ g: InstalledGame, runtimeID: String, log: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let c = g.contents
        guard WineTools.hostContents(for: g) == c else { throw NokError("Change the engine from this game's launcher app. Its shortcut has no engine of its own.") }
        guard let m = RuntimeManager.manifest(for: runtimeID), RuntimeManager.isCached(id: runtimeID) else { throw NokError("That engine isn't downloaded yet.") }
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit \(g.name) first.") }
        if state(for: g)?.status == .trying { throw NokError("\(g.name) is already trying an engine. Keep it or roll back first.") }
        let previous = g.wineVersion ?? "unknown"
        let previousID = state(for: g)?.runtimeID ?? (previous == RecipeCatalog.sikarugirWine10.wineVersionString ? RecipeCatalog.sikarugirWine10.id : nil)

        // Include native clients that survived their Wine server.
        try await WineTools.stopAll(for: g)

        let rb = rollbackDir(c)
        if fm.fileExists(atPath: rb.path) { try fm.removeItem(at: rb) }
        try fm.createDirectory(at: rb, withIntermediateDirectories: true)
        log("Keeping the current engine (\(previous)) so you can roll back…")
        var moved: [String] = []
        do {
            try prepareAudioBaseline(c, rollback: rb)
            for comp in RuntimeManager.components where fm.fileExists(atPath: c.appendingPathComponent(comp).path) {
                let dst = rb.appendingPathComponent("Contents/\(comp)")
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: c.appendingPathComponent(comp), to: dst)
                moved.append(comp)
            }
            for p in prefixParts where fm.fileExists(atPath: g.prefix.appendingPathComponent(p).path) {
                try fm.cloneItem(at: g.prefix.appendingPathComponent(p), to: rb.appendingPathComponent("prefix/\(p)"))
            }
            log("Installing \(m.engine) + \(m.template)…")
            let src = RuntimeManager.folder(for: runtimeID).appendingPathComponent("Contents")
            for comp in RuntimeManager.components {
                try fm.cloneItem(at: src.appendingPathComponent(comp), to: c.appendingPathComponent(comp))
            }
            let st = State(runtimeID: runtimeID, engine: m.wineVersion, previousEngine: previous, previousRuntimeID: previousID,
                           appliedAt: Date(), status: .trying)
            try fm.createDirectory(at: stateURL(c).deletingLastPathComponent(), withIntermediateDirectories: true)
            try ChangeJournal.encoder.encode(st).write(to: stateURL(c))

            log("Updating the Windows environment for the new engine (wineboot)…")
            let wine = c.appendingPathComponent("SharedSupport/wine/bin/wine").path
            let r = try await Shell.runAsync(wine, ["wineboot", "-u"], env: wineEnv(c), timeout: 600)
            _ = try? await Shell.runAsync(c.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-w"], env: wineEnv(c), timeout: 300)
            if !r.ok { log("wineboot exited \(r.status); checking that Windows programs still run…") }
            // The real test: can the new engine run a Windows program in this environment?
            let v = try await Shell.runAsync(wine, ["cmd", "/c", "ver"], env: wineEnv(c), timeout: 300)
            _ = try? await Shell.runAsync(c.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-w"], env: wineEnv(c), timeout: 120)
            guard v.stdout.contains("Windows") else {
                throw NokError("The new engine couldn't run Windows programs here (wineboot \(r.status), cmd \(v.status)). \(String((r.stderr + v.stderr).suffix(300)))")
            }
        } catch {
            log("Something went wrong — putting the old engine back…")
            try? restore(c, prefix: g.prefix, log: log)
            throw error
        }
        log("Done. \(g.name) now uses \(m.wineVersion). Play it, then Keep or Roll Back.")
    }

    /// Puts the previous engine and Windows system files back.
    public static func rollBack(_ g: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit \(g.name) first.") }
        guard FileManager.default.fileExists(atPath: rollbackDir(g.contents).path) else { throw NokError("There's no previous engine kept for \(g.name).") }
        try await WineTools.stopAll(for: g)
        try restore(g.contents, prefix: g.prefix, log: log)
        log("Rolled back to \(g.reload().wineVersion ?? "the previous engine").")
    }

    /// An original audio driver belongs to one engine. Keeping it across an upgrade could
    /// make a later buffer change write the old engine's driver into the new engine.
    static func prepareAudioBaseline(_ contents: URL, rollback: URL) throws {
        let fm = FileManager.default, original = AudioBuffer.original(contents)
        let saved = rollback.appendingPathComponent("audio-original")
        let present = fm.fileExists(atPath: original.path)
        if present { try fm.copyItem(at: original, to: saved) }
        try Data((present ? "present" : "absent").utf8).write(to: rollback.appendingPathComponent("audio-baseline-state"), options: .atomic)
        if present { try fm.removeItem(at: original) }
    }
    static func restoreAudioBaseline(_ contents: URL, rollback: URL) throws {
        let fm = FileManager.default, marker = rollback.appendingPathComponent("audio-baseline-state")
        guard fm.fileExists(atPath: marker.path) else { return } // backups made by earlier Nokcandu versions
        let value = try String(contentsOf: marker, encoding: .utf8)
        guard ["present", "absent"].contains(value) else { throw NokError("The saved audio baseline record is unreadable. Its backup was kept.") }
        let original = AudioBuffer.original(contents), saved = rollback.appendingPathComponent("audio-original")
        if value == "present" {
            // Read first so a damaged backup cannot remove a current baseline.
            let data = try Data(contentsOf: saved)
            try data.write(to: original, options: .atomic)
        } else if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
    }

    static func restore(_ c: URL, prefix: URL, log: (String) -> Void) throws {
        let fm = FileManager.default
        let rb = rollbackDir(c)
        for comp in RuntimeManager.components where fm.fileExists(atPath: rb.appendingPathComponent("Contents/\(comp)").path) {
            let dst = c.appendingPathComponent(comp)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: rb.appendingPathComponent("Contents/\(comp)"), to: dst)
        }
        for p in prefixParts where fm.fileExists(atPath: rb.appendingPathComponent("prefix/\(p)").path) {
            let dst = prefix.appendingPathComponent(p)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: rb.appendingPathComponent("prefix/\(p)"), to: dst)
        }
        try restoreAudioBaseline(c, rollback: rb)
        // Back to the previous state: none if it was the tested engine, or the previous kept update.
        if let st = try? ChangeJournal.decoder.decode(State.self, from: Data(contentsOf: stateURL(c))),
           let prevID = st.previousRuntimeID, prevID != RecipeCatalog.sikarugirWine10.id,
           let pm = RuntimeManager.manifest(for: prevID) {
            let back = State(runtimeID: prevID, engine: pm.wineVersion, previousEngine: RecipeCatalog.sikarugirWine10.wineVersionString,
                             previousRuntimeID: RecipeCatalog.sikarugirWine10.id, appliedAt: Date(), status: .kept)
            try? ChangeJournal.encoder.encode(back).write(to: stateURL(c))
        } else {
            try? fm.removeItem(at: stateURL(c))
        }
        try? fm.removeItem(at: rb)
    }

    /// Keeps the new engine and frees the space used by the old one.
    public static func keep(_ g: InstalledGame) throws {
        guard var st = state(for: g) else { return }
        st.status = .kept
        try ChangeJournal.encoder.encode(st).write(to: stateURL(g.contents))
        try? FileManager.default.removeItem(at: rollbackDir(g.contents))
    }
}

extension InstalledGame {
    /// Re-reads this app from disk (after its engine changed).
    func reload() -> InstalledGame {
        GameLibrary.inspect(appURL) ?? self
    }
}

/// Remembers which engine builds failed or passed the self-test on this Mac.
public enum EngineSelfTests {
    static var url: URL { NokPaths.support.appendingPathComponent("engine-selftests.json") }
    static func load() -> [String: Bool] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
    }
    static func record(_ id: String, passed: Bool) {
        var all = load(); all[id] = passed
        try? NokPaths.ensure(NokPaths.support)
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
    public static func failed(_ id: String) -> Bool { load()[id] == false }
    public static func passed(_ id: String) -> Bool { load()[id] == true }
    public static func forget(_ id: String) { var all = load(); all[id] = nil; try? JSONEncoder().encode(all).write(to: url, options: .atomic) }
}
