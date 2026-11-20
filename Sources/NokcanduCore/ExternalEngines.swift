import Foundation

/// Wine engines from other projects, used exactly as they come: native Apple silicon (ARM64) builds with an x86
/// emulator such as FEX, which run Intel Windows programs without Rosetta.
///
/// Nothing here is tied to one project. A source is a GitHub repository and a pattern for the release file;
/// MetalSharp Wine is the first built-in one, and more can be added (Settings → Updates) or an engine can be added
/// from a file. Each engine is kept untouched in its own runtime folder (`Runtimes/<id>/Engine/…`): signed engines
/// rely on Apple's cross-architecture entitlement, which is tied to the app's own signature and location, so a
/// copied or changed engine is killed by macOS (tested 2026-11-20). A game's `SharedSupport/wine` is a small folder
/// of links into the engine (`bin`, `lib`, `share`) with Nokcandu's own `version` and `engine.json` beside them;
/// `EngineLayout.isSealed` tells the rest of Nokcandu never to write into it.
public enum ExternalEngines {
    // MARK: Sources

    public struct Source: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// "owner/repository" on GitHub.
        public var repo: String
        /// Regular expression the release file's name matches (.zip, .tar.xz or .tar.gz).
        public var asset: String
        public var homepage: String
        public var license: String
        public var note: String?
        public init(id: String, name: String, repo: String, asset: String, homepage: String, license: String, note: String? = nil) {
            self.id = id; self.name = name; self.repo = repo; self.asset = asset; self.homepage = homepage; self.license = license; self.note = note
        }
    }

    public static let builtIn: [Source] = [
        Source(id: "metalsharp", name: "MetalSharp Wine", repo: "metalsharp/MetalSharp-Wine",
               asset: #"^MetalSharp-Wine-[0-9.]+-arm64\.zip$"#, homepage: "https://github.com/metalsharp/MetalSharp-Wine",
               license: "Wine and Mullion: LGPL-2.1-or-later; FEX: MIT; MetalSharp's own scripts: AGPL-3.0",
               note: "Wine 11 with FEX for 32- and 64-bit Intel programs; Mullion (based on DXMT) for Direct3D 9–12."),
    ]

    static var sourcesFile: URL { NokPaths.support.appendingPathComponent("Engine Sources.json") }

    /// The built-in sources and the ones added here (an added source with a built-in's id replaces it).
    public static func sources() -> [Source] {
        let added = (try? JSONDecoder().decode([Source].self, from: Data(contentsOf: sourcesFile))) ?? []
        return builtIn.filter { b in !added.contains { $0.id == b.id } } + added
    }
    public static func addSource(_ s: Source) throws {
        guard s.repo.split(separator: "/").count == 2 else { throw NokError("Enter the repository as owner/name, as on GitHub.") }
        guard (try? Regex(s.asset)) != nil else { throw NokError("The file pattern isn't a valid regular expression.") }
        var added = (try? JSONDecoder().decode([Source].self, from: Data(contentsOf: sourcesFile))) ?? []
        added.removeAll { $0.id == s.id }; added.append(s)
        try NokPaths.ensure(NokPaths.support)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(added).write(to: sourcesFile, options: .atomic)
    }
    public static func removeSource(_ id: String) throws {
        var added = (try? JSONDecoder().decode([Source].self, from: Data(contentsOf: sourcesFile))) ?? []
        added.removeAll { $0.id == id }
        try JSONEncoder().encode(added).write(to: sourcesFile, options: .atomic)
    }
    public static func slug(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.")
        let lowered = s.lowercased().map { allowed.contains($0) ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }

    // MARK: Installed engines

    public struct Info: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var source: String?
        public var release: String
        /// Wine's own version ("11.20").
        public var wineVersion: String
        public var installedAt: Date
        /// The engine's root (with bin/wine and lib/wine), relative to the runtime folder.
        public var engine: String
        public var from: String
        public var license: String?
        public var title: String { "\(name) \(release)" }
    }
    static let infoName = "engine.json"

    public static func info(id: String) -> Info? {
        let url = RuntimeManager.folder(for: id).appendingPathComponent("Contents/SharedSupport/wine/\(infoName)")
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Info.self, from: d)
    }
    public static func installed() -> [Info] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: NokPaths.runtimes.path)) ?? []
        return ids.filter { !$0.hasPrefix(".") }.compactMap(info(id:)).sorted { $0.installedAt > $1.installedAt }
    }
    /// The version-file text that identifies an external engine (read back by `EngineVersion(versionString:)`).
    public static func versionString(id: String, wine: String) -> String { "wine external \(id) \(wine)" }

    // MARK: Finding and installing

    public struct Release: Sendable {
        public var source: Source
        public var tag: String
        public var asset: ReleaseAsset
    }

    /// The newest release of a source with a file matching its pattern and a published SHA-256 (GitHub's own, or a
    /// SHA256SUMS file beside it).
    public static func latest(_ s: Source) async throws -> Release {
        let pattern = try Regex(s.asset)
        for r in try await Updates.releases(s.repo, perPage: 10) where r.prerelease != true {
            guard let a = r.assets.first(where: { $0.name.wholeMatch(of: pattern) != nil }) else { continue }
            var sha = a.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
            if sha == nil, let sums = r.assets.first(where: { $0.name.uppercased().hasPrefix("SHA256SUMS") }) {
                let (data, _) = try await URLSession.shared.data(from: sums.browser_download_url)
                sha = String(decoding: data, as: UTF8.self).split(separator: "\n")
                    .first { $0.hasSuffix(" " + a.name) || $0.hasSuffix("*" + a.name) }
                    .map { String($0.prefix(64)) }
            }
            return Release(source: s, tag: r.tag_name, asset: ReleaseAsset(name: a.name, size: a.size, url: a.browser_download_url, sha256: sha, updated: a.updated_at))
        }
        throw NokError("\(s.name) has no release with a file matching \(s.asset).")
    }

    /// Downloads (checking the published SHA-256) and installs a release. Returns the runtime id.
    public static func install(_ r: Release, log: @escaping @Sendable (String) -> Void) async throws -> String {
        let file = try await Updates.download(r.asset, log: log)
        let id = "ext-" + slug(r.source.id + "-" + r.tag)
        return try await install(file: file, id: id, name: r.source.name, source: r.source.id, release: r.tag,
                                 from: r.asset.url.absoluteString, license: r.source.license, log: log)
    }

    /// Installs an engine from a file or folder: an app, a .zip, a .tar.xz/.tar.gz, or a folder with bin/wine.
    public static func install(file: URL, name: String? = nil, log: @escaping @Sendable (String) -> Void) async throws -> String {
        let base = name ?? file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".tar", with: "")
        let id = "ext-" + slug(base)
        return try await install(file: file, id: id, name: base, source: nil, release: base, from: file.path, license: nil, log: log)
    }

    static func install(file: URL, id: String, name: String, source: String?, release: String, from: String,
                        license: String?, log: @escaping @Sendable (String) -> Void) async throws -> String {
        let fm = FileManager.default
        try NokPaths.ensure(NokPaths.runtimes)
        let final = RuntimeManager.folder(for: id)
        let staging = NokPaths.runtimes.appendingPathComponent(".\(id)-incoming")
        try? fm.removeItem(at: staging)
        let engineDir = staging.appendingPathComponent("Engine")
        try fm.createDirectory(at: engineDir, withIntermediateDirectories: true)
        log("Unpacking \(file.lastPathComponent)…")
        let lower = file.lastPathComponent.lowercased()
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: file.path, isDirectory: &isDir)
        let r: ShellResult
        if isDir.boolValue {
            // ditto keeps signatures, links and extended attributes exactly.
            r = try await Shell.runAsync("/usr/bin/ditto", [file.path, engineDir.appendingPathComponent(file.lastPathComponent).path], timeout: 900)
        } else if lower.hasSuffix(".zip") {
            r = try await Shell.runAsync("/usr/bin/ditto", ["-x", "-k", file.path, engineDir.path], timeout: 900)
        } else if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            r = try await Shell.runAsync("/usr/bin/tar", ["-xf", file.path, "-C", engineDir.path], timeout: 900)
        } else { throw NokError("Choose an app, a .zip, a .tar.xz or a folder with Wine in it.") }
        guard r.ok else { try? fm.removeItem(at: staging); throw NokError("Couldn't unpack \(file.lastPathComponent): \(r.combined.suffix(200))") }
        do {
            guard let root = findRoot(engineDir) else { throw NokError("No Wine engine found inside (looked for bin/wine with lib/wine beside it).") }
            let layout = EngineLayout(wine: root)
            guard layout.arch == .arm64 else { throw NokError("That's an Intel (x86_64) engine. This is for native Apple silicon engines; Intel ones come from Updates.") }
            guard layout.runs64BitX86 else { throw NokError("This engine has no x86 emulator (FEX), so it can't run Intel Windows programs.") }
            // Where the engine sits inside the runtime folder (both paths resolved: /var and /private/var are one).
            let rootPath = root.resolvingSymlinksInPath().path, stagingPath = staging.resolvingSymlinksInPath().path
            guard rootPath.hasPrefix(stagingPath + "/") else { throw NokError("The engine's folder couldn't be located after unpacking.") }
            let relative = String(rootPath.dropFirst(stagingPath.count + 1))
            let finalRoot = final.appendingPathComponent(relative)
            let wineVersion = try await version(of: root)
            log("Found \(name) with Wine \(wineVersion)\(layout.runs32BitX86 ? ", 32- and 64-bit" : ", 64-bit only").")
            // The runtime: the parts every game gets, empty where the engine brings its own (graphics, frameworks).
            let contents = staging.appendingPathComponent("Contents")
            for part in ["Frameworks", "SharedSupport/renderer", "Resources/vulkan"] {
                try fm.createDirectory(at: contents.appendingPathComponent(part), withIntermediateDirectories: true)
            }
            let wine = contents.appendingPathComponent("SharedSupport/wine")
            try fm.createDirectory(at: wine, withIntermediateDirectories: true)
            for part in ["bin", "lib", "share"] where fm.fileExists(atPath: root.appendingPathComponent(part).path) {
                try fm.createSymbolicLink(atPath: wine.appendingPathComponent(part).path, withDestinationPath: finalRoot.appendingPathComponent(part).path)
            }
            let versionText = versionString(id: id, wine: wineVersion)
            try Data((versionText + "\n").utf8).write(to: wine.appendingPathComponent("version"))
            let info = Info(id: id, name: name, source: source, release: release, wineVersion: wineVersion, installedAt: Date(),
                            engine: relative, from: from, license: license)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(info).write(to: wine.appendingPathComponent(infoName))
            let manifest = RuntimeManifest(id: id, engine: name, wineVersion: versionText, template: "the engine's own",
                                           importedFrom: from, importedAt: Date(),
                                           verifiedHashes: ["bin/wine": try Hashing.sha256(file: root.appendingPathComponent("bin/wine"))],
                                           licenses: ["\(name) \(release): \(license ?? "see the engine's own license files")"])
            try ChangeJournal.encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
            if fm.fileExists(atPath: final.path) { try SystemIntegration.trash(final) }
            try fm.moveItem(at: staging, to: final)
        } catch { try? fm.removeItem(at: staging); throw error }
        log("Checking that it runs Windows programs…")
        let ok = await selfTest(id: id)
        var m = RuntimeManager.manifest(for: id)
        m?.selfTest = ok
        if let m { try? ChangeJournal.encoder.encode(m).write(to: final.appendingPathComponent("manifest.json")) }
        if !ok { log("\(name) didn't pass the startup check on this Mac; it stays installed but can't be chosen.") }
        else { log("\(name) is ready. Choose it in a game's Wine settings.") }
        return id
    }

    /// The folder holding bin/wine and lib/wine (the app's Contents for an app), up to four levels down.
    static func findRoot(_ dir: URL, depth: Int = 0) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("bin/wine").path), fm.fileExists(atPath: dir.appendingPathComponent("lib/wine").path) { return dir }
        guard depth < 4, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let found = findRoot(u, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Wine's version from `wine --version` ("wine-11.20 (…)" → "11.20").
    static func version(of root: URL) async throws -> String {
        let r = try await Shell.runAsync(root.appendingPathComponent("bin/wine").path, ["--version"], timeout: 60)
        guard let m = (r.stdout + r.stderr).firstMatch(of: #/wine-(\d+\.\d+)/#) else {
            throw NokError("The engine didn't start (\((r.stdout + r.stderr).suffix(160))). macOS 26.5 or later is needed for Apple silicon engines.")
        }
        return String(m.1)
    }

    /// Runs `cmd /c ver` in a throwaway Windows environment.
    public static func selfTest(id: String) async -> Bool {
        let fm = FileManager.default
        let contents = RuntimeManager.folder(for: id).appendingPathComponent("Contents")
        let prefix = fm.temporaryDirectory.appendingPathComponent("nokcandu-engine-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: prefix) }
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path; env["WINEDEBUG"] = "-all"; env["WINEBOOT_HIDE_DIALOG"] = "1"
        let wine = contents.appendingPathComponent("SharedSupport/wine/bin/wine").path
        let r = try? await Shell.runAsync(wine, ["cmd", "/c", "ver"], env: env, timeout: 300)
        _ = try? await Shell.runAsync(contents.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-k"], env: env, timeout: 60)
        return r?.stdout.contains("Windows") == true
    }

    /// Removes an installed engine, unless a game still uses it.
    public static func remove(id: String, games: [InstalledGame]) throws {
        guard let info = info(id: id) else { return }
        let text = versionString(id: id, wine: info.wineVersion)
        if let g = games.first(where: { $0.wineVersion == text }) { throw NokError("\(g.name) uses \(info.title). Choose another Wine version for it first.") }
        try SystemIntegration.trash(RuntimeManager.folder(for: id))
    }
}
