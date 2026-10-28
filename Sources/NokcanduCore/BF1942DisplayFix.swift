import Foundation

/// A built-in display recipe, never code or patch data supplied by a community profile.
/// The original EXE is read-only. Only two independently observed full-file fingerprints are accepted.
public enum BF1942DisplayFix {
    public static let copyName = "BF1942-Nokcandu.exe"
    static let restartCopyName = "BF194N.exe"
    static let previousCorrectedSHA = "3b8033a58197ee844f4c4238b0bb873d1fcc6ba0a0f918b4fb247c9ac1ee01f2"
    static let originalSHA = "3a3eab9af4ad711f9faf6a17d8e31a3bacbbace99fe8356a700e1071c143cd7f"
    static let correctedSHA = "e3b58cc22cd5d638b3d915cf3527b2af700f98dc97e2d6b6373601f4c3204801"
    public static let resolutions = [[800, 600], [1024, 768], [1280, 800], [1280, 960], [1440, 900], [1600, 900], [1920, 1080], [1920, 1200]]
    struct State: Codable {
        var width: Int
        var height: Int
        var previousProgram: String
        var appliedProgram: String
        var previousMenuCopy: Bool?
        var previousDisplay: [Int]?
        var recommended = false
        var ownsBorderless = false
    }
    static func record(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("bf1942-display.json") }
    static func journal(_ g: InstalledGame) -> ChangeJournal { ChangeJournal(scope: "bf1942-display", root: g.nokcanduState, portableRoot: g.appURL) }
    static func state(_ g: InstalledGame) -> State? {
        (try? Data(contentsOf: record(g))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }
    static func save(_ state: State, _ g: InstalledGame) throws {
        try NokPaths.ensure(g.nokcanduState)
        try JSONEncoder().encode(state).write(to: record(g), options: .atomic)
    }
    static func folder(_ g: InstalledGame) -> URL? {
        guard g.custom != nil, !g.usesSharedSteam, g.battleNet == nil, g.hosted == nil, g.native == nil,
              let program = CompatibilityFixes.program(g) else { return nil }
        let names = ["bf1942.exe", "bf1942borderless.exe", "bf1942-menu-test.exe", "bftest.exe", copyName.lowercased()]
        guard names.contains(program.lastPathComponent.lowercased()) else { return nil }
        let logical = program.deletingLastPathComponent()
        let folder = logical.resolvingSymlinksInPath()
        let base = g.prefix.appendingPathComponent("drive_c").resolvingSymlinksInPath().path + "/"
        let external = GameMover.externalFiles(g)?.resolvingSymlinksInPath()
        let inManagedFiles = external.map { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") } ?? false
        guard folder.path.hasPrefix(base) || inManagedFiles else { return nil }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("BF1942.exe").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("Mods/bf1942/Settings").path) else { return nil }
        return logical
    }
    public static func supports(_ g: InstalledGame) -> Bool { folder(g) != nil }
    public static func hasChanges(for g: InstalledGame) -> Bool { state(g) != nil }
    public static func isRecommended(for g: InstalledGame) -> Bool { state(g)?.recommended == true }
    public static func resolution(for g: InstalledGame) -> [Int]? { state(g).map { [$0.width, $0.height] } }
    public static func menuUnavailable(for g: InstalledGame) -> String? {
        guard let root = folder(g) else { return "Choose a standalone BF1942 installation first." }
        let sha = try? Hashing.sha256(file: root.appendingPathComponent("BF1942.exe"))
        guard sha == originalSHA || sha == previousCorrectedSHA || sha == correctedSHA else {
            return "This BF1942 executable isn't a verified version. Game resolution can still be changed; the menu correction is unavailable."
        }
        return nil
    }
    static func checkedMenuCopy(_ data: Data) throws -> Data {
        let sha = Hashing.sha256(data: data)
        if sha == correctedSHA { return data }
        guard sha == originalSHA || sha == previousCorrectedSHA else { throw NokError("This BF1942 executable doesn't match a verified version. It was left untouched.") }
        let menu = sha == previousCorrectedSHA ? data : try replacingMenuDimensions(data)
        let result = try replacingRestartName(menu)
        guard Hashing.sha256(data: result) == correctedSHA else { throw NokError("The menu correction didn't match the expected result.") }
        return result
    }
    // BF1942 hard-codes its original filename for mod activation. Keep its working directory,
    // restart arguments and original EXE, but route that restart to the verified display copy.
    // The replacement is exactly the same byte length; no sections or other strings are changed.
    static func replacingRestartName(_ input: Data) throws -> Data {
        let offset = 0x4d369c, name = Data("BF1942.exe\0".utf8)
        guard input.count == 5_648_384, input.subdata(in: offset..<(offset + name.count)) == name else {
            throw NokError("The expected BF1942 restart name wasn't found. Its executable was left untouched.")
        }
        var result = input
        result.replaceSubrange(offset..<(offset + name.count), with: Data((restartCopyName + "\0").utf8))
        return result
    }

    /// Upgrade only the owned display copies, leaving the user's chosen resolution and settings alone.
    static func refreshMenuCopies(_ g: InstalledGame) throws {
        guard g.custom?.bf1942MenuCopy == true, state(g)?.recommended == true, let root = folder(g) else { return }
        let target = try checkedURL(root.appendingPathComponent(copyName), root: root)
        let alias = try checkedURL(root.appendingPathComponent(restartCopyName), root: root)
        let current = try Hashing.sha256(file: target)
        if current == correctedSHA, (try? Hashing.sha256(file: alias)) == correctedSHA { return }
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        try CompatibilityFixes.requireClosed(g)
        try validateJournal(g)
        let ledger = journal(g)
        guard ledger.entries.contains(where: { $0.path == target.path }),
              current == previousCorrectedSHA || current == correctedSHA else {
            throw NokError("BF1942's menu copy changed. It was left untouched.")
        }
        if FileManager.default.fileExists(atPath: alias.path), (try? Hashing.sha256(file: alias)) != correctedSHA {
            throw NokError("BF194N.exe is already in use. It was left untouched.")
        }
        let data = try checkedMenuCopy(Data(contentsOf: root.appendingPathComponent("BF1942.exe")))
        try ledger.write(data, to: alias, reason: "BF1942 mod restart display copy")
        if current != correctedSHA { try ledger.write(data, to: target, reason: "BF1942 mod restart display copy") }
    }

    /// Separate, testable byte transformation after full-file verification above.
    static func replacingMenuDimensions(_ input: Data) throws -> Data {
        let width = 0x631ef, height = 0x631f7
        guard input.count == 5_648_384,
              Array(input[width..<(width + 4)]) == [0x20, 0x03, 0, 0],
              Array(input[height..<(height + 4)]) == [0x58, 0x02, 0, 0] else { throw NokError("The expected menu dimensions weren't found.") }
        var data = input
        data.replaceSubrange(width..<(width + 4), with: [0, 5, 0, 0])
        data.replaceSubrange(height..<(height + 4), with: [0x20, 3, 0, 0])
        return data
    }
    /// Exact allowlisted command, including duplicate assignments. Preserve all other text and line endings.
    static func setting(_ command: String, value: String, in text: String) -> String {
        let pattern = "(?m)^[\\t ]*" + NSRegularExpression.escapedPattern(for: command) + "[\\t ]+[^\\r\\n]*"
        let re = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let line = command + " " + value
        if re.firstMatch(in: text, range: range) != nil {
            return re.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: line))
        }
        let end = text.contains("\r\n") ? "\r\n" : "\n"
        return text + (text.isEmpty || text.hasSuffix("\n") ? "" : end) + line + end
    }
    static func checkedURL(_ path: URL, root: URL) throws -> URL {
        // Foundation leaves some symlink ancestors unresolved when the final file doesn't exist.
        // Resolve each component, including dangling links, before creating anything below it.
        func canonical(_ url: URL, depth: Int = 0) throws -> URL {
            guard depth < 128 else { throw NokError("A display settings path contains a link loop.") }
            let clean = url
            if clean.path == "/" { return clean }
            let parent = try canonical(clean.deletingLastPathComponent(), depth: depth + 1)
            if clean.lastPathComponent == "." { return parent }
            if clean.lastPathComponent == ".." { return parent.deletingLastPathComponent() }
            let candidate = parent.appendingPathComponent(clean.lastPathComponent)
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
                let target = link.hasPrefix("/") ? URL(fileURLWithPath: link) : parent.appendingPathComponent(link)
                return try canonical(target, depth: depth + 1)
            }
            return candidate
        }
        let resolved = try canonical(path), base = try canonical(root)
        guard resolved.path.hasPrefix(base.path + "/") else { throw NokError("A display settings file points outside this game. Nothing was changed.") }
        return root.appendingPathComponent(String(resolved.path.dropFirst(base.path.count + 1)))
    }
    static func plannedFiles(root: URL, size: [Int], recommended: Bool) throws -> [URL: Data] {
        guard resolutions.contains(size) else { throw NokError("Choose one of the supported game resolutions.") }
        let fm = FileManager.default
        let settings = try checkedURL(root.appendingPathComponent("Mods/bf1942/Settings"), root: root)
        let profiles = try checkedURL(settings.appendingPathComponent("Profiles"), root: root)
        let children = (try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        guard children.count <= 100 else { throw NokError("Too many BF1942 profiles to update safely.") }
        var files: [URL: Data] = [:]
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let url = try checkedURL(child.appendingPathComponent("Video.con"), root: root)
            guard fm.fileExists(atPath: url.path) else { continue }
            let old = try String(contentsOf: url, encoding: .utf8)
            files[url] = Data(setting("game.setGameDisplayMode", value: "\(size[0]) \(size[1]) 32 60", in: old).utf8)
        }
        let active = try checkedURL(settings.appendingPathComponent("Video.con"), root: root)
        let activeText = fm.fileExists(atPath: active.path) ? try String(contentsOf: active, encoding: .utf8) : ""
        if activeText.range(of: #"(?m)^[\t ]*game\.setGameDisplayMode[\t ]"#, options: .regularExpression) != nil {
            files[active] = Data(setting("game.setGameDisplayMode", value: "\(size[0]) \(size[1]) 32 60", in: activeText).utf8)
        } else if activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = try checkedURL(profiles.appendingPathComponent("Default/Video.con"), root: root)
            if files[url] == nil { files[url] = Data("game.setGameDisplayMode \(size[0]) \(size[1]) 32 60\n".utf8) }
            files[active] = Data("run Profiles/Default/Video.con\n".utf8)
        } else {
            // Existing profile routing must resolve to one of the files we are updating.
            let re = try! NSRegularExpression(pattern: #"(?im)^[\t ]*run[\t ]+Profiles/([^/\\\r\n]+)/Video\.con[\t ]*$"#)
            if let m = re.firstMatch(in: activeText, range: NSRange(activeText.startIndex..., in: activeText)),
               let r = Range(m.range(at: 1), in: activeText) {
                let name = String(activeText[r])
                guard name != ".", name != ".." else { throw NokError("BF1942's active video profile path is invalid.") }
                let url = try checkedURL(profiles.appendingPathComponent(name + "/Video.con"), root: root)
                if files[url] == nil { files[url] = Data("game.setGameDisplayMode \(size[0]) \(size[1]) 32 60\n".utf8) }
            } else { throw NokError("BF1942 uses an unfamiliar video profile layout. Its settings were left untouched.") }
        }
        if recommended {
            let url = try checkedURL(settings.appendingPathComponent("VideoDefault.con"), root: root)
            let text = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            files[url] = Data(setting("renderer.setFullScreen", value: "0", in: text).utf8)
        }
        return files
    }
    static func settingKeys(_ url: URL) -> [String]? {
        if url.lastPathComponent.lowercased() == "videodefault.con" { return ["renderer.setfullscreen"] }
        if url.lastPathComponent.lowercased() == "video.con" {
            return url.path.contains("/Profiles/") ? ["game.setgamedisplaymode"] : []
        }
        return nil
    }
    static func validateJournal(_ g: InstalledGame) throws {
        let j = journal(g)
        guard let root = folder(g) else { throw NokError("The BF1942 installation moved or its program changed. Its display files were left untouched.") }
        for path in j.touchedPaths {
            let url = try checkedURL(URL(fileURLWithPath: path), root: root)
            if let keys = settingKeys(url) { try j.manageSettings(url, keys: keys) }
            else if let sha = j.entries.last(where: { $0.path == path })?.shaAfter, (try? Hashing.sha256(file: url)) != sha {
                throw NokError("\(url.lastPathComponent) changed. Its original was kept; use Settings Backups for configuration recovery.")
            }
        }
    }
    /// `recommended` also adds the verified menu copy and borderless component. Resolution-only edits
    /// never patch an executable or change the Mac's screen. All mutations have a recovery receipt.
    public static func apply(to game: InstalledGame, size: [Int] = [1280, 800], recommended: Bool, includePresentation: Bool = true,
                             log: @escaping @Sendable (String) -> Void) async throws {
        let g = CompatibilityFixes.fresh(game)
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        try CompatibilityFixes.requireClosed(g)
        guard let root = folder(g), var c = g.custom else { throw NokError("Choose a standalone BF1942 installation first.") }
        try validateJournal(g)
        if let st = state(g), c.exe != st.appliedProgram, c.exe != st.previousProgram {
            throw NokError("The selected BF1942 program changed. Restore it before updating display settings.")
        }
        let wantsRecommended = recommended || state(g)?.recommended == true
        var files = try plannedFiles(root: root, size: size, recommended: wantsRecommended)
        var st = state(g) ?? State(width: size[0], height: size[1], previousProgram: c.exe,
                                  appliedProgram: c.exe, previousMenuCopy: c.bf1942MenuCopy, previousDisplay: c.displayPixels)
        if wantsRecommended {
            let original = root.appendingPathComponent("BF1942.exe")
            let copy = try checkedMenuCopy(Data(contentsOf: original))
            let target = try checkedURL(root.appendingPathComponent(copyName), root: root)
            if FileManager.default.fileExists(atPath: target.path),
               ![correctedSHA, previousCorrectedSHA].contains((try? Hashing.sha256(file: target)) ?? "") { throw NokError("The display-copy filename is already in use. That file was left untouched.") }
            let alias = try checkedURL(root.appendingPathComponent(restartCopyName), root: root)
            if FileManager.default.fileExists(atPath: alias.path), (try? Hashing.sha256(file: alias)) != correctedSHA {
                throw NokError("BF194N.exe is already in use. That file was left untouched.")
            }
            files[target] = copy
            files[alias] = copy
            // Normalize older manually created wrappers, while retaining the original program for Undo.
            guard let canonical = CustomGames.windowsPath(forUnix: original, prefix: g.prefix) else { throw NokError("Couldn't locate BF1942 on C:.") }
            if c.exe != canonical, !CompatibilityFixes.installedIDs(for: g).isEmpty {
                throw NokError("Undo compatibility components before replacing this older BF1942 launcher. Then apply the recommended display settings again.")
            }
            c.exe = canonical; c.bf1942MenuCopy = true
            if recommended && includePresentation { c.displayPixels = nil }
            st.appliedProgram = canonical; st.recommended = true
        }
        st.width = size[0]; st.height = size[1]
        let needsBorderless = recommended && includePresentation && !CompatibilityFixes.isInstalled(.borderless, for: g)
        if needsBorderless { st.ownsBorderless = true }
        try save(st, g)
        let ledger = journal(g)
        for (url, data) in files {
            if let keys = settingKeys(url) { try ledger.writeSettings(data, to: url, keys: keys, reason: "BF1942 display settings") }
            else { try ledger.write(data, to: url, reason: "BF1942 display settings") }
        }
        try CustomGames.save(c, to: g, allowDisplayProgramChange: true)
        if needsBorderless { try await CompatibilityFixes.installReserved(.borderless, for: CompatibilityFixes.fresh(g), log: log) }
        log(wantsRecommended ? "Applied BF1942's recommended display settings. The original executable is unchanged." : "Saved BF1942's game resolution.")
    }
    /// In-memory checkpoint for a profile's existing Undo button. The display recipe keeps its own
    /// baseline journal; restoring that ledger as well allows both Undo paths to remain independent.
    final class Checkpoint {
        struct File {
            let url: URL
            let before: Data?
            var after: String?
        }
        let game: InstalledGame
        var files: [File]
        var started = false
        private var sealed = false
        init(game: InstalledGame, urls: [URL]) throws {
            self.game = game
            files = try urls.map { File(url: $0, before: FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil) }
        }
        func seal() {
            sealed = true
            for i in files.indices {
                files[i].after = try? Hashing.sha256(file: files[i].url)
                if FileManager.default.fileExists(atPath: files[i].url.path), files[i].after == nil { sealed = false }
            }
        }
        func restore() throws {
            guard started else { return }
            try CompatibilityFixes.requireClosed(CompatibilityFixes.fresh(game))
            guard sealed else { throw NokError("The display changes couldn't be verified for Undo. Use the game's Display controls to recover them.") }
            for file in files {
                let current = try? Hashing.sha256(file: file.url)
                if let keys = BF1942DisplayFix.settingKeys(file.url) {
                    if keys.isEmpty { continue }
                    guard let text = try? TextSettings.read(file.url), TextSettings.lines(text).contains(where: { keys.contains(TextSettings.key($0) ?? "") }) else {
                        throw NokError("The expected display settings are missing. Open Settings Backups to restore a saved version.")
                    }
                    continue
                }
                guard current == file.after,
                      !FileManager.default.fileExists(atPath: file.url.path) || current != nil else {
                    throw NokError("\(file.url.lastPathComponent) changed after the profile. Undo kept your files and settings.")
                }
            }
            for file in files {
                if let keys = BF1942DisplayFix.settingKeys(file.url) {
                    if keys.isEmpty { continue }
                    let bytes = try Data(contentsOf: file.url), current = try TextSettings.decode(bytes)
                    let before = try file.before.map(TextSettings.decode) ?? ""
                    let merged = TextSettings.merge(current: current, valuesFrom: before, keys: keys)
                    try ChangeJournal(scope: "settings-recovery", root: game.nokcanduState, portableRoot: game.appURL).write(try TextSettings.encode(merged, like: bytes), to: file.url, reason: "Before undoing profile display settings")
                } else if let before = file.before {
                    try NokPaths.ensure(file.url.deletingLastPathComponent())
                    try before.write(to: file.url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: file.url.path) {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                }
            }
            started = false
        }
    }
    static func checkpoint(for g: InstalledGame, size: [Int], menuCorrection: Bool) throws -> Checkpoint {
        try CompatibilityFixes.requireClosed(g)
        guard let root = folder(g) else { throw NokError("Choose a standalone BF1942 installation first.") }
        try validateJournal(g)
        let recommended = menuCorrection || isRecommended(for: g)
        var urls = Array(try plannedFiles(root: root, size: size, recommended: recommended).keys)
        if recommended {
            urls.append(try checkedURL(root.appendingPathComponent(copyName), root: root))
            urls.append(try checkedURL(root.appendingPathComponent(restartCopyName), root: root))
        }
        urls += [record(g), g.nokcanduState.appendingPathComponent("Journals/bf1942-display.json"), g.nokcanduState.appendingPathComponent("Journals/bf1942-display.json.root")]
        return try Checkpoint(game: g, urls: urls)
    }

    public static func undo(for game: InstalledGame, log: @escaping @Sendable (String) -> Void) throws {
        var g = CompatibilityFixes.fresh(game)
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        try CompatibilityFixes.requireClosed(g)
        guard let st = state(g), var c = g.custom else { throw NokError("No BF1942 display changes to undo.") }
        try validateJournal(g)
        try journal(g).validateForUndo()
        guard c.exe == st.appliedProgram || c.exe == st.previousProgram else {
            throw NokError("The selected BF1942 program changed. Restore it before undoing display settings.")
        }
        let others = CompatibilityFixes.installedIDs(for: g).filter { $0 != CompatibilityFix.borderless.rawValue || !st.ownsBorderless }
        if c.exe == st.appliedProgram, c.exe != st.previousProgram, !others.isEmpty {
            throw NokError("Undo the other compatibility components before restoring the previous BF1942 program.")
        }
        if st.ownsBorderless, CompatibilityFixes.isInstalled(.borderless, for: g) {
            try CompatibilityFixes.undoReserved(.borderless, for: g, log: log)
            g = CompatibilityFixes.fresh(g); c = g.custom ?? c
        }
        if c.exe == st.appliedProgram { c.exe = st.previousProgram }
        if c.bf1942MenuCopy == true { c.bf1942MenuCopy = st.previousMenuCopy }
        if st.recommended, c.displayPixels == nil { c.displayPixels = st.previousDisplay }
        try CustomGames.save(c, to: g, allowDisplayProgramChange: true)
        let report = journal(g).revertAll(); log(report.summary)
        guard report.skipped.isEmpty else { throw NokError(report.summary) }
        try FileManager.default.removeItem(at: record(g))
    }
}
