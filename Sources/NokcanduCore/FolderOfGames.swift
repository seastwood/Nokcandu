import Foundation

/// "Add a Folder of Games": every game folder inside one folder, each with its likeliest program,
/// added where it is (nothing copied) one after another.
public enum FolderOfGames {
    public struct Candidate: Identifiable, Hashable, Sendable {
        public var id: String { folder.path }
        public let folder: URL
        public var name: String
        /// The program, relative to `folder` ("Bin/Game.exe").
        public var program: String
        /// Other programs found, for the picker (relative, best first).
        public let others: [String]
        /// Named after its folder or big enough to be a game; others start unticked.
        public let likely: Bool
        public init(folder: URL, name: String, program: String, others: [String] = [], likely: Bool = true) {
            self.folder = folder; self.name = name; self.program = program; self.others = others; self.likely = likely
        }
    }

    /// The game folders inside `root`, looking up to three folders down: a folder whose own top level (or bin, System,
    /// _retail_…) has a game program is one game; any other folder is looked inside. Folders already in the library
    /// are left out. `likely` is false for folders that look more like downloads or tools than a game.
    public static func scan(_ root: URL, library: [InstalledGame] = [], depth: Int = 3) -> [Candidate] {
        let fm = FileManager.default
        let known = knownFolders(library)
        var out: [Candidate] = []
        func visit(_ dir: URL, _ level: Int) {
            let key = dir.resolvingSymlinksInPath().standardizedFileURL.path
            if known.contains(key) || skipFolder(dir) { return }
            if hasOwnProgram(dir) {
                let name = displayName(dir.lastPathComponent)
                let found = programs(in: dir, gameName: name)
                if let best = found.ranked.first {
                    out.append(Candidate(folder: dir, name: name, program: best, others: Array(found.ranked.dropFirst().prefix(5)),
                                         likely: looksLikeGame(program: best, folderName: name, bytes: found.bytes)))
                }
                return
            }
            guard level < depth else { return }
            let subs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { fm.isDirectory($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for s in subs { visit(s, level + 1) }
        }
        visit(root, 0)
        return out
    }

    /// Folders the library already uses: ones used where they are, and copies kept outside a game's app.
    static func knownFolders(_ library: [InstalledGame]) -> Set<String> {
        let fm = FileManager.default
        var known = Set<String>()
        for g in library {
            if let f = OriginalFiles.folder(g) { known.insert(f.resolvingSymlinksInPath().standardizedFileURL.path) }
            let games = g.prefix.appendingPathComponent("drive_c/Games")
            for n in (try? fm.contentsOfDirectory(atPath: games.path)) ?? [] {
                let u = games.appendingPathComponent(n)
                if (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil { known.insert(u.resolvingSymlinksInPath().standardizedFileURL.path) }
            }
        }
        return known
    }

    static let programFolders: Set<String> = ["bin", "bin32", "bin64", "binaries", "system", "x64", "x86", "win32", "win64", "_retail_", "game", "exe", "program"]

    /// A game program at the top, or one folder down in a usual program folder.
    public static func hasOwnProgram(_ dir: URL) -> Bool {
        let fm = FileManager.default
        func programsHere(_ d: URL) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).contains { isGameProgramName($0.lowercased()) }
        }
        if programsHere(dir) { return true }
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return subs.contains { programFolders.contains($0.lastPathComponent.lowercased()) && programsHere($0) }
    }

    static func skipFolder(_ dir: URL) -> Bool {
        let n = dir.lastPathComponent.lowercased()
        return n.hasPrefix("$") || n.hasSuffix(".app") || n.hasSuffix(".sparsebundle") || n.hasPrefix("found.")
            || ["system volume information", "windows", "program files", "programdata", "drive_c", "prefixes", "temp", "tmp"].contains(n)
    }

    static func isGameProgramName(_ n: String) -> Bool {
        n.hasSuffix(".exe") && !CustomGames.skipNamePrefixes.contains { n.hasPrefix($0) } && !isTool(n)
    }

    static func isTool(_ n: String) -> Bool {
        ["server", "dedicated", "_ded", "editor", "crash", "report", "redist", "unins", "setup", "set-up", "installer", "config",
         "benchmark", "updater", "patch", "-windows-", "_win_", "uninstall", "backup"].contains { n.contains($0) } || n.hasSuffix("ded.exe")
    }

    /// Named after its folder, or a folder big enough to hold a game.
    static func looksLikeGame(program: String, folderName: String, bytes: Int) -> Bool {
        let exe = URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent.lowercased()
        let tokens = folderName.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        let squashed = folderName.lowercased().filter { $0.isLetter || $0.isNumber }
        let named = tokens.contains { exe.contains($0) } || (exe.count >= 3 && squashed.contains(exe.filter { $0.isLetter || $0.isNumber }))
        if named { return true }
        let folder = folderName.lowercased()
        if ["download", "installer", "setup", "driver", "backup", "files", "unsorted"].contains(where: { folder.contains($0) }) { return false }
        if exe.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil { return false }   // "rufus-4.4": a versioned tool
        return bytes >= 50_000_000
    }

    /// "Battlefield_1942" → "Battlefield 1942".
    public static func displayName(_ folder: String) -> String {
        folder.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Programs worth starting, best first (the same choice as Steam games, then the rest by size), and the bytes seen.
    static func programs(in dir: URL, gameName: String) -> (ranked: [String], bytes: Int) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return ([], 0) }
        var all: [(String, Int)] = []
        var bytes = 0, seen = 0
        for case let u as URL in en {
            if en.level > 3 { en.skipDescendants(); continue }
            seen += 1
            if seen > 20_000 { break }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += size
            let n = u.lastPathComponent.lowercased()
            guard isGameProgramName(n) else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))
            all.append((rel, size + (en.level == 1 ? 50_000_000 : 0)))   // top level first, then by size
        }
        guard !all.isEmpty else { return ([], bytes) }
        var ranked = all.sorted { $0.1 > $1.1 }.map(\.0)
        if let best = SharedSteam.mainExecutable(in: dir, gameName: gameName) {
            let rel = String(best.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))
            if let i = ranked.firstIndex(of: rel) { ranked.remove(at: i); ranked.insert(rel, at: 0) }
        }
        return (ranked, bytes)
    }

    public enum Outcome: Equatable, Sendable { case added(URL), failed(String) }

    /// Adds one game where it is, with its program already chosen. Stops before the play test,
    /// which stays for you to do from the game's page.
    public static func add(_ c: Candidate, library: [InstalledGame], folder: URL = GameFolders.installFolder,
                           log: @escaping @Sendable (String) -> Void) async -> Outcome {
        do {
            let ex = try InstallExecutor.makeCustom(name: c.name, source: .folder, library: library, folder: folder,
                                                    inputs: ["folderMode": "existing", "folderPath": c.folder.path, "copyDestination": ""],
                                                    log: log)
            for _ in 0..<3 {
                await ex.runUntilBlocked()
                if ex.statuses["check"] == .done || ex.isComplete { return .added(ex.ctx.targetApp) }
                guard let s = ex.nextStage else { break }
                if case .failed(let why) = ex.statuses[s.info.id] ?? .pending { return .failed(why) }
                if s.info.id == "exe" {
                    let unix = CustomInstall.gamesFolder(ex.ctx).appendingPathComponent(c.program)
                    guard let w = CustomGames.windowsPath(forUnix: unix, prefix: ex.ctx.prefix) else { return .failed("Couldn't find \(c.program).") }
                    ex.setInput("exe", w)
                    continue
                }
                if case .needsUser(let why) = ex.statuses[s.info.id] ?? .pending { return .failed("\(s.info.title): \(why)") }
            }
            return .failed("Setup stopped before finishing. Open Add a Game to continue it.")
        } catch { return .failed(error.localizedDescription) }
    }
}
