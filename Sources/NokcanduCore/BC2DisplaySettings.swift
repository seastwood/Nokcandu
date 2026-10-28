import Foundation
import CoreGraphics

/// A built-in settings recipe; it never changes executables or game content.
public enum BC2DisplaySettings {
    /// Portable profile value: resolve the current desktop when applying on each Mac.
    public static let desktop = [0, 0]
    public static let resolutions = [[1024, 768], [1280, 800], [1440, 900], [1920, 1080], [1920, 1200]]
    public static func supports(_ game: InstalledGame) -> Bool {
        guard let contents = WineTools.hostContents(for: game),
              let exe = game.hosted?.exe ?? game.custom?.exe,
              exe.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last?.lowercased() == "bfbc2game.exe",
              let file = BattleNet.unixPath(exe, prefix: contents.appendingPathComponent("SharedSupport/prefix")) else { return false }
        return PEFile.inspect(file) != nil
    }
    static func ini(_ game: InstalledGame) throws -> URL {
        guard supports(game), let contents = WineTools.hostContents(for: game) else { throw NokError("Only available for Battlefield: Bad Company 2.") }
        let users = contents.appendingPathComponent("SharedSupport/prefix/drive_c/users")
        let name = NSUserName()
        return users.appendingPathComponent(name + "/Documents/BFBC2/settings.ini")
    }
    static let keys = ["WindowSettings/Width", "WindowSettings/Height", "WindowSettings/Fullscreen", "Graphics/DxVersion"]
    struct State: Codable {
        var previous: [String: String]
        var applied: [String: String]
        var resolution: [Int]
    }
    static func marker(_ game: InstalledGame) -> URL { game.nokcanduState.appendingPathComponent("bc2-display.json") }
    static func state(_ game: InstalledGame) -> State? { (try? Data(contentsOf: marker(game))).flatMap { try? JSONDecoder().decode(State.self, from: $0) } }
    public static func resolution(_ game: InstalledGame) -> [Int]? { state(game)?.resolution }
    static func read(_ path: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else { return "" }
        let data = try Data(contentsOf: path)
        guard data.count < 256_000, let text = String(data: data, encoding: .utf8) else { throw NokError("BC2's settings file has an unfamiliar format. It was kept unchanged.") }
        return text
    }
    static func values(_ resolution: [Int]) -> [String: String] {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let size = resolution == desktop ? [Int(bounds.width), Int(bounds.height)] : resolution
        return [keys[0]: String(size[0]), keys[1]: String(size[1]), keys[2]: resolution == desktop ? "true" : "false", keys[3]: "9"]
    }
    public static func apply(_ game: InstalledGame, resolution: [Int]) throws {
        guard resolution == desktop || resolutions.contains(resolution) else { throw NokError("Choose a supported BC2 resolution.") }
        try CompatibilityFixes.requireClosed(game)
        let path = try ini(game), text = try read(path)
        let values = values(resolution)
        let previous = state(game)?.previous ?? Dictionary(uniqueKeysWithValues: keys.compactMap { k in GameINI.value(k, in: text).map { (k, $0) } })
        let changed = GameINI.setting(values.mapValues(Optional.some), in: text)
        let journal = ChangeJournal(scope: game.journalScope)
        try journal.write(Data(changed.utf8), to: path, reason: "BC2 DirectX 9 display settings")
        try NokPaths.ensure(game.nokcanduState)
        try journal.write(try JSONEncoder().encode(State(previous: previous, applied: values, resolution: resolution)), to: marker(game), reason: "BC2 display Undo record")
    }
    public final class Checkpoint {
        let game: InstalledGame, path: URL, previous: [String: String], markerData: Data?
        let applied: [String: String]
        var started = false
        init(game: InstalledGame, size: [Int]) throws {
            self.game = game; path = try ini(game)
            let text = try read(path)
            previous = Dictionary(uniqueKeysWithValues: keys.compactMap { key in GameINI.value(key, in: text).map { (key, $0) } })
            markerData = try? Data(contentsOf: marker(game))
            applied = values(size)
        }
        func restore() throws {
            guard started else { return }
            let text = try read(path)
            var edits: [String: String?] = [:]
            for key in keys where GameINI.value(key, in: text) == applied[key] { edits[key] = .some(previous[key]) }
            let journal = ChangeJournal(scope: game.journalScope)
            try journal.write(Data(GameINI.setting(edits, in: text).utf8), to: path, reason: "Undo profile BC2 display values")
            try journal.write(markerData ?? Data("null".utf8), to: marker(game), reason: "Restore BC2 display Undo record")
        }
    }
    /// Merge only Nokcandu's settings back. Game/user edits to other values remain untouched.
    public static func undo(_ game: InstalledGame) throws {
        try CompatibilityFixes.requireClosed(game)
        guard let saved = state(game) else { return }
        let path = try ini(game), text = try read(path)
        var edits: [String: String?] = [:]
        for key in keys where GameINI.value(key, in: text) == saved.applied[key] { edits[key] = .some(saved.previous[key]) }
        let journal = ChangeJournal(scope: game.journalScope)
        try journal.write(Data(GameINI.setting(edits, in: text).utf8), to: path, reason: "Undo BC2 display settings; keep later edits")
        try journal.write(Data("null".utf8), to: marker(game), reason: "Clear BC2 display Undo record")
    }
}

/// Section-aware edits shared by built-in game recipes. Profiles never supply paths or INI keys.
enum GameINI {
    static func value(_ key: String, in text: String) -> String? {
        var section = "", result: String?
        for line in text.components(separatedBy: .newlines) {
            let trim = line.trimmingCharacters(in: .whitespaces)
            if trim.hasPrefix("["), trim.hasSuffix("]") { section = String(trim.dropFirst().dropLast()); continue }
            let pair = trim.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, (section + "/" + pair[0].trimmingCharacters(in: .whitespaces)).lowercased() == key.lowercased() { result = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }
    static func setting(_ edits: [String: String?], in text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            var section = "", matches: [Int] = [], insertAt: Int?
            for i in lines.indices {
                let trim = lines[i].trimmingCharacters(in: .whitespaces)
                if trim.hasPrefix("["), trim.hasSuffix("]") {
                    if section.caseInsensitiveCompare(parts[0]) == .orderedSame { insertAt = i }
                    section = String(trim.dropFirst().dropLast())
                } else if section.caseInsensitiveCompare(parts[0]) == .orderedSame {
                    insertAt = i + 1
                    let pair = trim.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(parts[1]) == .orderedSame { matches.append(i) }
                }
            }
            if !matches.isEmpty {
                for i in matches.reversed() { if let value { lines[i] = parts[1] + "=" + value } else { lines.remove(at: i) } }
            } else if let value {
                if let insertAt { lines.insert(parts[1] + "=" + value, at: insertAt) }
                else { lines += ["[" + parts[0] + "]", parts[1] + "=" + value] }
            }
        }
        return lines.joined(separator: newline)
    }
}
