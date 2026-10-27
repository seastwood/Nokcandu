import Foundation

/// A built-in display recipe, never code or patch data supplied by a community profile.
/// The original EXE is read-only. Only two independently observed full-file fingerprints are accepted.
public enum BF1942DisplayFix {
    public static let copyName = "BF1942-Nokcandu.exe"
    static let originalSHA = "3a3eab9af4ad711f9faf6a17d8e31a3bacbbace99fe8356a700e1071c143cd7f"
    static let correctedSHA = "3b8033a58197ee844f4c4238b0bb873d1fcc6ba0a0f918b4fb247c9ac1ee01f2"
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
    static func journal(_ g: InstalledGame) -> ChangeJournal { ChangeJournal(scope: "bf1942-display", root: g.nokcanduState) }
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
        let folder = program.deletingLastPathComponent().resolvingSymlinksInPath()
        let base = g.prefix.appendingPathComponent("drive_c").resolvingSymlinksInPath().path + "/"
        guard folder.path.hasPrefix(base),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("BF1942.exe").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("Mods/bf1942/Settings").path) else { return nil }
        return folder
    }
    public static func supports(_ g: InstalledGame) -> Bool { folder(g) != nil }
    public static func hasChanges(for g: InstalledGame) -> Bool { state(g) != nil }
    public static func isRecommended(for g: InstalledGame) -> Bool { state(g)?.recommended == true }
    public static func resolution(for g: InstalledGame) -> [Int]? { state(g).map { [$0.width, $0.height] } }
    public static func menuUnavailable(for g: InstalledGame) -> String? {
        guard let root = folder(g) else { return "Choose a standalone BF1942 installation first." }
        let sha = try? Hashing.sha256(file: root.appendingPathComponent("BF1942.exe"))
        guard sha == originalSHA || sha == correctedSHA else {
            return "This BF1942 executable isn't a verified version. Game resolution can still be changed; the menu correction is unavailable."
        }
        return nil
    }
    static func checkedMenuCopy(_ data: Data) throws -> Data {
        let sha = Hashing.sha256(data: data)
        if sha == correctedSHA { return data }
        guard sha == originalSHA else { throw NokError("This BF1942 executable doesn't match a verified version. It was left untouched.") }
        let result = try replacingMenuDimensions(data)
        guard Hashing.sha256(data: result) == correctedSHA else { throw NokError("The menu correction didn't match the expected result.") }
        return result
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
        return resolved
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
    static func validateJournal(_ g: InstalledGame) throws {
        let j = journal(g)
        guard let root = folder(g) else { throw NokError("The BF1942 installation moved or its program changed. Its display files were left untouched.") }
        for path in j.touchedPaths {
            _ = try checkedURL(URL(fileURLWithPath: path), root: root)
            if let sha = j.entries.last(where: { $0.path == path })?.shaAfter,
               (try? Hashing.sha256(file: URL(fileURLWithPath: path))) != sha {
                throw NokError("\((path as NSString).lastPathComponent) changed after the display fix. Your changes were kept; restore that file before applying or undoing these settings.")
            }
        }
    }
    /// `recommended` also adds the verified menu copy and borderless component. Resolution-only edits
    /// never patch an executable or change the Mac's screen. All mutations have a recovery receipt.
    public static func apply(to game: InstalledGame, size: [Int] = [1280, 800], recommended: Bool,
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
               (try? Hashing.sha256(file: target)) != correctedSHA { throw NokError("The display-copy filename is already in use. That file was left untouched.") }
            files[target] = copy
            // Normalize older manually created wrappers, while retaining the original program for Undo.
            guard let canonical = CustomGames.windowsPath(forUnix: original, prefix: g.prefix.resolvingSymlinksInPath()) else { throw NokError("Couldn't locate BF1942 on C:.") }
            if c.exe != canonical, !CompatibilityFixes.installedIDs(for: g).isEmpty {
                throw NokError("Undo compatibility components before replacing this older BF1942 launcher. Then apply the recommended display settings again.")
            }
            c.exe = canonical; c.bf1942MenuCopy = true
            if recommended { c.displayPixels = nil }
            st.appliedProgram = canonical; st.recommended = true
        }
        st.width = size[0]; st.height = size[1]
        let needsBorderless = recommended && !CompatibilityFixes.isInstalled(.borderless, for: g)
        if needsBorderless { st.ownsBorderless = true }
        try save(st, g)
        for (url, data) in files { try journal(g).write(data, to: url, reason: "BF1942 display settings") }
        try CustomGames.save(c, to: g, allowDisplayProgramChange: true)
        if needsBorderless { try await CompatibilityFixes.installReserved(.borderless, for: CompatibilityFixes.fresh(g), log: log) }
        log(wantsRecommended ? "Applied BF1942's recommended display settings. The original executable is unchanged." : "Saved BF1942's game resolution.")
    }
    public static func undo(for game: InstalledGame, log: @escaping @Sendable (String) -> Void) throws {
        var g = CompatibilityFixes.fresh(game)
        try CompatibilityFixes.begin(g); defer { CompatibilityFixes.end(g) }
        try CompatibilityFixes.requireClosed(g)
        guard let st = state(g), var c = g.custom else { throw NokError("No BF1942 display changes to undo.") }
        try validateJournal(g)
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
