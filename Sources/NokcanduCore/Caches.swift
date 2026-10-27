import Foundation

/// Shader caches games build up while playing. Clearing one is safe; the next session stutters briefly
/// while shaders are compiled again.
public enum Caches {
    public struct Cache: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public var title: String
        public var detail: String
        public var url: URL
        public var bytes: Int64
    }

    static var userCacheDir: URL {
        var buf = [CChar](repeating: 0, count: 1024)
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count)
        let path = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// All shader caches Nokcandu knows about.
    public static func all(_ games: [InstalledGame]) -> [Cache] { metal() + others(games) }

    public static func metal() -> [Cache] {
        var out: [Cache] = []
        // macOS's Metal cache for every Wine game (Apple Metal, DXMT, DXVK through MoltenVK).
        let metal = userCacheDir.appendingPathComponent("org.winehq.wine/com.apple.metal", isDirectory: true)
        if FileManager.default.fileExists(atPath: metal.path) {
            out.append(Cache(title: "Metal shader cache (all Wine games)", detail: "macOS keeps compiled graphics shaders here for every game.",
                             url: metal, bytes: Storage.size(metal)))
        }
        return out
    }

    /// Steam's and DXVK's caches (these can be on external drives, so they may take a moment).
    public static func others(_ games: [InstalledGame]) -> [Cache] {
        var out: [Cache] = []
        // Steam's per-game shader caches, in every Steam library folder.
        if SharedSteam.isSetUp {
            let names = Dictionary(SharedSteam.installedGames().map { ($0.appID, $0.name) }, uniquingKeysWith: { a, _ in a })
            for lib in SharedSteam.libraryFolders() {
                let dir = lib.appendingPathComponent("steamapps/shadercache")
                for id in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    let u = dir.appendingPathComponent(id)
                    let b = Storage.size(u)
                    guard b > 0 else { continue }
                    out.append(Cache(title: "Steam: \(Int(id).flatMap { names[$0] } ?? "App \(id)")", detail: "Steam's shader cache for this game.", url: u, bytes: b))
                }
            }
        }
        // DXVK caches next to games' programs (older DXVK versions).
        for g in games where g.custom != nil {
            guard let rel = g.custom?.exeRelativeToContents else { continue }
            let dir = g.contents.appendingPathComponent(rel).deletingLastPathComponent()
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".dxvk-cache") {
                let u = dir.appendingPathComponent(f)
                out.append(Cache(title: "\(g.name): DXVK cache", detail: f, url: u, bytes: Storage.size(u)))
            }
        }
        return out
    }

    /// Deletes a cache's contents (keeps the folder so the owner can write to it again).
    public static func clear(_ c: Cache) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: c.url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            for f in try fm.contentsOfDirectory(at: c.url, includingPropertiesForKeys: nil) { try fm.removeItem(at: f) }
        } else {
            try fm.removeItem(at: c.url)
        }
    }
}
