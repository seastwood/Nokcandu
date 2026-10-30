import Foundation

/// Windows setups made by other Mac Wine apps that Nokcandu can bring a game over from:
/// the game's folder is copied (an instant clone on the same drive) and the saves and settings it kept
/// in the bottle's user folders come along. Nothing in the other app is changed.
public struct Bottle: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case whisky = "Whisky", crossover = "CrossOver"
        /// How the app shows where a bottle came from.
        public var title: String { self == .whisky ? "Whisky" : "other Wine app" }
    }
    public var kind: Kind
    public var name: String
    /// The folder holding drive_c.
    public var url: URL
    public var id: String { url.path }

    public struct Game: Identifiable, Hashable, Sendable {
        public var name: String
        /// The game's own folder (copied into the new app).
        public var folder: URL
        public var exe: URL
        public var id: String { folder.path }
    }
}

public enum Bottles {
    public static func all(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [Bottle] {
        let fm = FileManager.default
        var out: [Bottle] = []
        func scan(_ dir: URL, _ kind: Bottle.Kind) {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for b in items where fm.fileExists(atPath: b.appendingPathComponent("drive_c").path) {
                var name = b.lastPathComponent
                if kind == .whisky, let meta = NSDictionary(contentsOf: b.appendingPathComponent("Metadata.plist")) as? [String: Any],
                   let info = meta["info"] as? [String: Any], let n = info["name"] as? String, !n.isEmpty { name = n }
                out.append(Bottle(kind: kind, name: name, url: b))
            }
        }
        scan(home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles"), .whisky)
        scan(home.appendingPathComponent("Library/Application Support/CrossOver/Bottles"), .crossover)
        return out.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    static let containers: Set<String> = ["program files", "program files (x86)", "games", "gog games", "epic games"]

    /// The game's own folder for a program in a bottle (e.g. drive_c/Program Files/Foo for …/Foo/bin/foo.exe).
    public static func gameFolder(for exe: URL, in bottle: URL) -> URL? {
        let driveC = bottle.appendingPathComponent("drive_c").standardizedFileURL.path
        let path = exe.standardizedFileURL.path
        guard path.hasPrefix(driveC + "/") else { return nil }
        let parts = path.dropFirst(driveC.count + 1).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var take = 1
        if containers.contains(parts[0].lowercased()) { take = 2 }
        if take == 2, parts.count >= 4, ["steam", "steamapps"].contains(parts[1].lowercased()) { return nil }   // Steam itself, not a game
        guard parts.count > take else { return nil }
        return URL(fileURLWithPath: driveC).appendingPathComponent(parts.prefix(take).joined(separator: "/"), isDirectory: true)
    }

    public static func games(in b: Bottle) -> [Bottle.Game] {
        let cands = CustomGames.findExecutables(prefix: b.url, nameHint: "", limit: 60)
        var best: [String: Bottle.Game] = [:]
        for c in cands.sorted(by: { $0.score > $1.score }) {
            guard let folder = gameFolder(for: c.url, in: b.url), best[folder.path] == nil else { continue }
            best[folder.path] = Bottle.Game(name: folder.lastPathComponent, folder: folder, exe: c.url)
        }
        return best.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copies saves and settings from the bottle's user folders into the new prefix's user folder,
    /// never replacing a file that's already there.
    public static func importUserData(from bottle: URL, into prefix: URL, log: (String) -> Void) {
        let fm = FileManager.default
        let users = bottle.appendingPathComponent("drive_c/users")
        let skip: Set<String> = ["public", "crossover"]
        guard let me = (try? fm.contentsOfDirectory(atPath: users.path))?.first(where: { !skip.contains($0.lowercased()) && !$0.hasPrefix(".") }) else { return }
        let dest = prefix.appendingPathComponent("drive_c/users/\(NSUserName())", isDirectory: true)
        for sub in ["AppData", "Application Data", "Local Settings", "Saved Games", "Documents", "My Documents"] {
            let src = users.appendingPathComponent(me).appendingPathComponent(sub)
            // Documents is often a link to the Mac's own Documents: nothing to copy then.
            guard fm.fileExists(atPath: src.path), (try? fm.destinationOfSymbolicLink(atPath: src.path)) == nil else { continue }
            let target = dest.appendingPathComponent(sub == "My Documents" ? "Documents" : sub)
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            let r = try? Shell.run("/bin/cp", ["-Rnc", src.path + "/.", target.path], timeout: 600)
            if r?.ok == true { log("Brought over \(sub) from the old bottle.") }
            else { _ = try? Shell.run("/bin/cp", ["-Rn", src.path + "/.", target.path], timeout: 600); log("Brought over \(sub).") }
        }
    }
}
