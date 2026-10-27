import Foundation

/// Your own profiles, kept only on this Mac (Application Support/Nokcandu/MyProfiles). Save a game's setup
/// to come back to it, keep variants ("High FPS", "Windowed"), apply them to any game, export them, and
/// share one with everyone only if you choose to.
public struct MyProfile: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var updated: Date
    /// Set once you've shared it, so it isn't shared twice by accident.
    public var sharedAt: Date?
    public var profile: GameProfile
    /// A community profile you favorited: its catalog number and author. `profile` stays exactly as it was
    /// when you favorited it; the catalog may have a newer version.
    public var favoriteOf: Int? = nil
    public var favoriteAuthor: String? = nil
}

public enum MyProfiles {
    /// Posted after any saved profile or favorite is added, changed or removed.
    public static let changed = Notification.Name("NokcanduMyProfilesChanged")

    static var folder: URL { NokPaths.support.appendingPathComponent("MyProfiles", isDirectory: true) }
    static func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Newest first.
    public static func all() -> [MyProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(MyProfile.self, from: $0) } }
            .sorted { $0.updated > $1.updated }
    }

    public static func forGame(_ g: InstalledGame) -> [MyProfile] { all().filter { Profiles.matches($0.profile, g) } }

    @discardableResult
    public static func save(_ p: GameProfile, name: String) throws -> MyProfile {
        let problems = p.problems
        guard problems.isEmpty else { throw NokError("Can't save this profile: \(problems.joined(separator: "; "))") }
        let item = MyProfile(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? p.title : name,
                             created: Date(), updated: Date(), sharedAt: nil, profile: p)
        try write(item)
        return item
    }

    public static func write(_ item: MyProfile) throws {
        try NokPaths.ensure(folder)
        try encoder.encode(item).write(to: url(item.id), options: .atomic)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    public static func rename(_ item: MyProfile, to name: String) throws {
        var i = item; i.name = name; i.updated = Date(); try write(i)
    }

    public static func markShared(_ item: MyProfile) throws {
        var i = item; i.sharedAt = Date(); try write(i)
    }

    /// Favorites: community profiles saved as they were when you starred them.
    public static func favorite(of number: Int) -> MyProfile? { all().first { $0.favoriteOf == number } }

    @discardableResult
    public static func addFavorite(_ e: CatalogEntry) throws -> MyProfile {
        if let f = favorite(of: e.number) { return f }
        let item = MyProfile(id: UUID(), name: e.profile.title + " (by \(e.author))", created: Date(), updated: Date(),
                             sharedAt: nil, profile: e.profile, favoriteOf: e.number, favoriteAuthor: e.author)
        try write(item)
        return item
    }

    public static func removeFavorite(of number: Int) {
        for f in all() where f.favoriteOf == number { try? delete(f) }
    }

    /// Moves it to the Trash (recoverable).
    public static func delete(_ item: MyProfile) throws {
        try FileManager.default.trashItem(at: url(item.id), resultingItemURL: nil)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Adds a profile from a file someone gave you (checked first — settings only).
    @discardableResult
    public static func importText(_ text: String, name: String? = nil) throws -> MyProfile {
        let p = try GameProfile.parse(text)
        let problems = p.problems
        guard problems.isEmpty else { throw NokError("This profile isn't safe to use: \(problems.joined(separator: "; "))") }
        return try save(p, name: name ?? p.title)
    }
}
