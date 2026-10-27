import Foundation

/// Per-game notebook: things tried, what works, what crashes, findings from the web.
/// Stored in Application Support (not inside the game app), so notes survive reinstalling or
/// removing a game — reinstall it and the notes are still there.
public struct GameNote: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case tried, works, crashes, info
        public var id: String { rawValue }
        public var title: String {
            switch self { case .tried: "Tried"; case .works: "Works"; case .crashes: "Crashes / broken"; case .info: "Info / link" }
        }
        public var symbol: String {
            switch self { case .tried: "flask"; case .works: "checkmark.circle"; case .crashes: "exclamationmark.octagon"; case .info: "link" }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var text: String
    public var link: String?
    public var created = Date()
    public var edited: Date?
    /// The game's setup when the note was written (graphics, program, options), so "this worked" stays meaningful.
    public var setup: String?
    /// The full setup at that time, so it can be looked at in detail and restored.
    public var snapshot: GameProfile?

    public init(kind: Kind, text: String, link: String? = nil, setup: String? = nil) {
        self.kind = kind; self.text = text; self.link = link; self.setup = setup
    }
}

public enum GameNotes {
    static var folder: URL { NokPaths.support.appendingPathComponent("Notes", isDirectory: true) }

    /// Stable key for a game, independent of where its app lives or what it's called.
    public static func key(for g: InstalledGame) -> String {
        if let c = g.custom {
            if let id = c.steamAppID { return "steam-\(id)" }
            return "custom-\(c.id)"
        }
        if let r = g.recipe { return r.id }
        return "app-" + (g.bundleIdentifier ?? g.name).replacingOccurrences(of: "/", with: "_")
    }

    static func url(_ key: String) -> URL { folder.appendingPathComponent("\(key).json") }

    public static func load(for g: InstalledGame) -> [GameNote] {
        guard let d = try? Data(contentsOf: url(key(for: g))),
              let notes = try? ChangeJournal.decoder.decode([GameNote].self, from: d) else { return [] }
        return notes.sorted { $0.created > $1.created }
    }

    public static func save(_ notes: [GameNote], for g: InstalledGame) throws {
        try NokPaths.ensure(folder)
        try ChangeJournal.encoder.encode(notes).write(to: url(key(for: g)), options: .atomic)
    }

    /// One-line summary of the current setup, attached to new notes.
    public static func currentSetup(_ g: InstalledGame) -> String {
        var parts: [String] = []
        if let c = g.custom {
            parts.append("Graphics: \(c.graphics.title)")
            if c.source != .steamLibrary { parts.append("Program: \(c.exe.split(separator: "\\").last.map(String.init) ?? c.exe)") }
            if !c.arguments.isEmpty { parts.append("Options: \(c.arguments)") }
            if let env = c.environment, !env.isEmpty { parts.append("Env: " + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        } else if DisplayController.supports(g) {
            parts.append("Display: \(DisplayController.currentMode(g).title)")
        }
        if let v = g.wineVersion { parts.append(v) }
        return parts.joined(separator: " · ")
    }

    /// Plain-text export for sharing or pasting into a forum post.
    public static func export(_ notes: [GameNote], game: String) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        var out = "\(game) — notes\n\n"
        for n in notes.sorted(by: { $0.created < $1.created }) {
            out += "[\(n.kind.title)] \(f.string(from: n.created))\n\(n.text)\n"
            if let l = n.link, !l.isEmpty { out += "Link: \(l)\n" }
            if let s = n.setup, !s.isEmpty { out += "Setup: \(s)\n" }
            out += "\n"
        }
        return out
    }
}
