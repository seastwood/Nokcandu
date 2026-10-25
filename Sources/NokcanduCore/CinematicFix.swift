import Foundation

/// "Fix cinematic playback": installs and registers LAV Filters (open-source DirectShow movie reader
/// [LAV Splitter], video decoder [LAV Video] and audio decoder [LAV Audio]) inside one game's private
/// Windows environment. Many older games play their intro/cutscene videos through DirectShow, which
/// Wine can't fully decode on its own. Confirmed on this Mac with Warcraft III (LAV Filters 0.83).
///
/// Official release zips from GitHub, pinned by SHA-256. Fully undoable: unregisters the filters and
/// moves the files to the Trash.
public enum CinematicFix {
    public static let version = "0.83"

    public enum Arch: String, Codable, CaseIterable {
        case x86, x64
        var zipName: String { "LAVFilters-\(CinematicFix.version)-\(rawValue).zip" }
        var url: URL { URL(string: "https://github.com/Nevcairiel/LAVFilters/releases/download/\(CinematicFix.version)/\(zipName)")! }
        var zipSHA: String {
            switch self {
            case .x86: "8189505b593f25ff939f4a070135ec09f417d1d505012f79f43cbb247c7f21b2"
            case .x64: "0126982f47157bb86a6dbb43c4f332f7f98beba9ad552c19b65f9db2e7d4f186"
            }
        }
        /// Where it goes inside drive_c, and which regsvr32 registers it in a 64-bit (WoW64) prefix.
        var programFiles: String { self == .x86 ? "Program Files (x86)" : "Program Files" }
        var regsvr32: String { self == .x86 ? "C:\\windows\\syswow64\\regsvr32.exe" : "C:\\windows\\system32\\regsvr32.exe" }
        var title: String { self == .x86 ? "32-bit" : "64-bit" }
    }

    public static let filters = ["LAVSplitter.ax", "LAVVideo.ax", "LAVAudio.ax"]

    /// A LAV Filters release: version plus the SHA-256 of each zip (from GitHub's published digests for
    /// newer releases, or the tested pin).
    public struct Release: Codable, Hashable {
        public var version: String
        public var sha: [String: String]          // Arch.rawValue → sha256
        public init(version: String, sha: [String: String]) { self.version = version; self.sha = sha }
        public static let pinned = Release(version: CinematicFix.version,
                                           sha: [Arch.x86.rawValue: Arch.x86.zipSHA, Arch.x64.rawValue: Arch.x64.zipSHA])
        func zipName(_ a: Arch) -> String { "LAVFilters-\(version)-\(a.rawValue).zip" }
        func url(_ a: Arch) -> URL { URL(string: "https://github.com/Nevcairiel/LAVFilters/releases/download/\(version)/\(zipName(a))")! }
    }

    public struct State: Codable, Equatable {
        public var version: String
        public var arches: [Arch]
        public var installedAt: Date
    }

    // MARK: Where

    /// The Wine app (Contents) whose prefix gets the fix — the game itself, or the shared Steam.
    static func host(_ g: InstalledGame) -> URL? { WineTools.hostContents(for: g) }

    static func stateURL(_ host: URL) -> URL { host.appendingPathComponent("SharedSupport/nokcandu/cinematic-fix.json") }

    static func folder(_ host: URL, _ a: Arch) -> URL {
        host.appendingPathComponent("SharedSupport/prefix/drive_c/\(a.programFiles)/LAV Filters")
    }

    public static func state(for g: InstalledGame) -> State? {
        guard let h = host(g), let d = try? Data(contentsOf: stateURL(h)) else { return nil }
        return try? ChangeJournal.decoder.decode(State.self, from: d)
    }

    /// Installed by Nokcandu, or found already present (e.g. installed by hand before this feature existed).
    public static func isPresent(for g: InstalledGame) -> Bool {
        guard let h = host(g) else { return false }
        return Arch.allCases.contains { a in filters.allSatisfy { FileManager.default.fileExists(atPath: folder(h, a).appendingPathComponent($0).path) } }
    }

    /// Which builds a game needs: its bitness if known, both otherwise (and always both for the shared Steam).
    public static func arches(for g: InstalledGame) -> [Arch] {
        if g.usesSharedSteam { return [.x86, .x64] }
        if let b = g.custom?.is64Bit { return [b ? .x64 : .x86] }
        if g.recipe?.id == RecipeCatalog.zeroHour.id || g.recipe?.id == RecipeCatalog.worms.id { return [.x86] }
        if let exe = g.custom?.exeRelativeToContents, let pe = PEFile.inspect(g.contents.appendingPathComponent(exe)) {
            return [pe.is64Bit ? .x64 : .x86]
        }
        return [.x86, .x64]
    }

    // MARK: Install / undo

    public static func install(for g: InstalledGame, localZips: [Arch: URL] = [:], release: Release = .pinned, log: @escaping @Sendable (String) -> Void) async throws {
        guard let h = host(g) else { throw NokError("This game has no Windows environment.") }
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit the game first.") }
        if g.usesSharedSteam && SharedSteam.isRunning { throw NokError("Quit Steam first (Steam menu → Exit).") }
        // Stop any idle Windows processes of this environment so tools start with matching settings.
        _ = try? await Shell.runAsync(h.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-k"],
                                      env: WineTools.environment(contents: h), timeout: 60)
        let fm = FileManager.default
        let env = WineTools.environment(contents: h)
        let wine = h.appendingPathComponent("SharedSupport/wine/bin/wine").path
        let work = NokPaths.support.appendingPathComponent("Work/lav-\(UUID().uuidString.prefix(6))")
        try NokPaths.ensure(work)
        defer { try? fm.removeItem(at: work) }
        var done: [Arch] = []
        for a in arches(for: g) {
            // 1. Get the official zip (cached in Nokcandu's Downloads) and verify it.
            let cached = NokPaths.downloads.appendingPathComponent(release.zipName(a))
            var zip = localZips[a] ?? cached
            if !fm.fileExists(atPath: zip.path) {
                log("Downloading LAV Filters \(release.version) (\(a.title)) from GitHub…")
                try NokPaths.ensure(NokPaths.downloads)
                let (tmp, resp) = try await URLSession.shared.download(from: release.url(a))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NokError("Download failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)).") }
                try? fm.removeItem(at: cached)
                try fm.moveItem(at: tmp, to: cached)
                zip = cached
            }
            guard (try? Hashing.sha256(file: zip)) == release.sha[a.rawValue] else {
                throw NokError("\(zip.lastPathComponent) doesn't match the official LAV Filters \(release.version) release; nothing was installed.")
            }
            // 2. Unpack and copy into the game's private C: drive.
            let unpack = work.appendingPathComponent(a.rawValue)
            try NokPaths.ensure(unpack)
            let r = try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])
            guard r.ok else { throw NokError("Couldn't unpack LAV Filters: \(r.combined)") }
            let dest = folder(h, a)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: unpack, to: dest)
            // 3. Register the three filters with Windows (regsvr32), like LAV's own install_*.bat.
            var debugEnv = env
            debugEnv["WINEDEBUG"] = "err+all"
            for f in filters {
                let winPath = "C:\\\(a.programFiles)\\LAV Filters\\\(f)"
                log("Registering \(f) (\(a.title))…")
                // Try the matching-bitness regsvr32, then Wine's generic one (which picks the bitness itself).
                var ok = false
                for args in [[a.regsvr32, "/s", winPath], ["regsvr32", "/s", winPath], [a.regsvr32, "/s", dest.appendingPathComponent(f).path]] {
                    let rr = try await Shell.runAsync(wine, args, cwd: dest, env: debugEnv, timeout: 120)
                    if rr.ok { ok = true; break }
                    log("  \(args[0].split(separator: "\\").last ?? "") exited \(rr.status): \(rr.stderr.split(separator: "\n").suffix(3).joined(separator: " | ").suffix(300))")
                }
                if !ok { log("  could not register \(f)") }
            }
            done.append(a)
        }
        _ = try? await Shell.runAsync(h.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-w"], env: env, timeout: 60)
        // 4. Confirm Windows now knows the filters.
        let reg = (try? String(contentsOf: h.appendingPathComponent("SharedSupport/prefix/system.reg"), encoding: .utf8)) ?? ""
        let registered = filters.filter { reg.contains("LAV Filters\\\\\($0)") }
        guard registered.count == filters.count else {
            throw NokError("Files are in place but Windows registered only \(registered.joined(separator: ", ")). Try Repair, then this fix again.")
        }
        let st = State(version: release.version, arches: done, installedAt: Date())
        try fm.createDirectory(at: stateURL(h).deletingLastPathComponent(), withIntermediateDirectories: true)
        try ChangeJournal.encoder.encode(st).write(to: stateURL(h))
        log("Cinematic fix installed (\(done.map(\.title).joined(separator: " + "))).")
    }

    public static func undo(for g: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        guard let h = host(g) else { throw NokError("This game has no Windows environment.") }
        if case .launcherRunning = GameLauncher.runState(of: g) { throw NokError("Quit the game first.") }
        if g.usesSharedSteam && SharedSteam.isRunning { throw NokError("Quit Steam first (Steam menu → Exit).") }
        // Stop any idle Windows processes of this environment so tools start with matching settings.
        _ = try? await Shell.runAsync(h.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-k"],
                                      env: WineTools.environment(contents: h), timeout: 60)
        let fm = FileManager.default
        let env = WineTools.environment(contents: h)
        let wine = h.appendingPathComponent("SharedSupport/wine/bin/wine").path
        for a in Arch.allCases where fm.fileExists(atPath: folder(h, a).path) {
            for f in filters {
                let winPath = "C:\\\(a.programFiles)\\LAV Filters\\\(f)"
                log("Unregistering \(f) (\(a.title))…")
                _ = try? await Shell.runAsync(wine, [a.regsvr32, "/u", "/s", winPath], cwd: folder(h, a), env: env, timeout: 120)
            }
            try fm.trashItem(at: folder(h, a), resultingItemURL: nil)
        }
        _ = try? await Shell.runAsync(h.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-w"], env: env, timeout: 60)
        try? fm.removeItem(at: stateURL(h))
        log("Cinematic fix removed; the LAV Filters folder is in the Trash.")
    }

    // MARK: Recognizing the problem

    /// Signs (in the launch log) that the last run stopped on a video/DirectShow error.
    static let crashSignatures = ["err:quartz", "err:strmbase", "err:qcap", "VFW_E_", "80040218", "80040265", "80040256", "8004022f",
                                  "no filter", "cannot render", "Failed to render", "Unable to play movie", "Could not play video",
                                  "IGraphBuilder", "RenderFile"]

    public struct Diagnosis: Equatable {
        public var evidence: String
        public var exitStatus: Int?
        public var seconds: Int?
    }

    /// Looks at the end of the game's last launch log. Only meaningful for apps whose own launcher writes
    /// a log (not Steam games, whose output goes to the shared Steam log).
    public static func diagnoseLastRun(_ g: InstalledGame) -> Diagnosis? {
        guard !g.usesSharedSteam, let tail = tailOfFile(g.logs.appendingPathComponent("launch.log"), maxLines: 400) else { return nil }
        let lower = tail.lowercased()
        guard let hit = crashSignatures.first(where: { lower.contains($0.lowercased()) }) else { return nil }
        let line = tail.components(separatedBy: .newlines).first { $0.lowercased().contains(hit.lowercased()) } ?? hit
        var status: Int?, secs: Int?
        if let r = tail.range(of: #"nokcandu: game exited with status (\d+) after (\d+)s"#, options: .regularExpression) {
            let nums = tail[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 2 { status = nums[0]; secs = nums[1] }
        }
        return Diagnosis(evidence: line.trimmingCharacters(in: .whitespaces), exitStatus: status, seconds: secs)
    }

    /// Hint that a game plays videos through DirectShow even before anything crashes.
    public static func likelyUsesDirectShow(_ g: InstalledGame) -> Bool {
        guard let exeRel = g.custom?.exeRelativeToContents else { return false }
        let dir = g.contents.appendingPathComponent(exeRel).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if names.contains(where: { $0.lowercased().hasSuffix(".ax") }) { return true }   // e.g. Blizzard's blizzard.ax
        if let pe = PEFile.inspect(g.contents.appendingPathComponent(exeRel)),
           pe.imports.contains(where: { ["quartz.dll", "msvfw32.dll", "strmiids.dll"].contains($0.lowercased()) }) { return true }
        return false
    }
}
