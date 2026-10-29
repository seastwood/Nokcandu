import Foundation

/// Small on-disk caches for lists that are slow to fetch (store libraries, owned Steam games): shown
/// instantly next time, then refreshed in the background. Losing a cache file only means a slower first load.
public enum ListCache {
    static var dir: URL { NokPaths.support.appendingPathComponent("Cache", isDirectory: true) }
    static func file(_ key: String) -> URL { dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "-") + ".json") }

    struct Box<T: Codable>: Codable { var saved: Date; var value: T }

    /// The cached value and when it was saved.
    public static func load<T: Codable>(_ key: String, as: T.Type = T.self) -> (value: T, saved: Date)? {
        guard let d = try? Data(contentsOf: file(key)), let b = try? JSONDecoder().decode(Box<T>.self, from: d) else { return nil }
        return (b.value, b.saved)
    }

    public static func save<T: Codable>(_ value: T, _ key: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Box(saved: Date(), value: value)) { try? d.write(to: file(key), options: .atomic) }
    }

    public static func remove(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }

    /// A disk cache for cover images (store artwork), so they load once instead of on every visit.
    public static func installImageCache() {
        let images = dir.appendingPathComponent("Images", isDirectory: true)
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20, directory: images)
    }
}
