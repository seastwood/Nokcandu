import Foundation

/// Windows drive letters inside an app's Windows environment (dosdevices symlinks), e.g. E: → an
/// external SSD. Steam games use the shared Steam's environment.
public enum Drives {
    public struct Drive: Identifiable, Hashable {
        public var id: String { letter }
        public var letter: String          // "E"
        public var target: String          // Mac path the letter points to
        public var connected: Bool         // target currently exists (external drives can be unplugged)
        public var builtIn: Bool           // C: and Z: are Wine's own
        public var gameDisc = false        // D: of a game set up from a disc image: its launcher links it each start
    }

    static func folder(_ g: InstalledGame) -> URL? {
        WineTools.hostContents(for: g).map { $0.appendingPathComponent("SharedSupport/prefix/dosdevices", isDirectory: true) }
    }

    public static func list(for g: InstalledGame) -> [Drive] {
        guard let dir = folder(g), let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [Drive] = []
        let discGame = g.custom?.disc != nil || g.recipe?.disc != nil
        for n in names.sorted() where n.count == 2 && n.hasSuffix(":") {
            let link = dir.appendingPathComponent(n)
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let abs = dest.hasPrefix("/") ? dest : dir.appendingPathComponent(dest).standardizedFileURL.path
            let letter = String(n.prefix(1)).uppercased()
            out.append(Drive(letter: letter, target: abs, connected: FileManager.default.fileExists(atPath: abs),
                             builtIn: letter == "C" || letter == "Z", gameDisc: discGame && letter == "D"))
        }
        return out
    }

    public static func freeLetters(for g: InstalledGame) -> [String] {
        let used = Set(list(for: g).map(\.letter))
        return "DEFGHIJKLMNOPQRSTUVWXY".map(String.init).filter { !used.contains($0) }
    }

    /// Makes `letter`: point at a Mac folder or drive. Takes effect the next time the game starts.
    public static func add(_ letter: String, to url: URL, for g: InstalledGame) throws {
        guard let dir = folder(g) else { throw NokError("This game has no Windows environment.") }
        let l = letter.uppercased()
        guard l.count == 1, "DEFGHIJKLMNOPQRSTUVWXY".contains(l) else { throw NokError("Choose a letter from D to Y.") }
        guard freeLetters(for: g).contains(l) else { throw NokError("\(l): is already used.") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(l.lowercased() + ":").path,
                                                   withDestinationPath: url.standardizedFileURL.path)
    }

    /// Removes a drive letter (the files it points to are not touched).
    public static func remove(_ letter: String, for g: InstalledGame) throws {
        guard let dir = folder(g) else { return }
        let l = letter.uppercased()
        guard l != "C", l != "Z" else { throw NokError("C: and Z: are part of Wine and can't be removed.") }
        let link = dir.appendingPathComponent(l.lowercased() + ":")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try FileManager.default.removeItem(at: link)
    }
}
