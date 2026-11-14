import Foundation

/// Nokcandu keeping itself current: checks the project's GitHub Releases, downloads the new DMG,
/// verifies it against GitHub's published SHA-256 and against the running app's signer, swaps the app in place
/// and relaunches.
public enum AppUpdate {
    public static let repo = "seastwood/Nokcandu"
    public static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    public struct Release: Codable, Equatable {
        public var version: String          // "0.9.1"
        public var tag: String              // "v0.9.1"
        public var notes: String
        public var dmg: ReleaseAsset
        public var page: URL
    }

    public static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Semantic-version comparison ("0.10.0" > "0.9.3"); a pre-release suffix sorts before the release.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> ([Int], String) {
            let core = v.split(separator: "-", maxSplits: 1)
            return ((core.first ?? "").split(separator: ".").map { Int($0) ?? 0 }, core.count > 1 ? String(core[1]) : "")
        }
        let (x, xp) = parts(a), (y, yp) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        if xp.isEmpty != yp.isEmpty { return xp.isEmpty }   // 1.0.0 > 1.0.0-beta
        return xp > yp
    }

    struct GHRelease: Decodable {
        var tag_name: String; var body: String?; var html_url: URL; var draft: Bool; var prerelease: Bool
        var assets: [Updates.GHAsset]
    }

    /// The newest published release, or nil if this copy is current (or the repo has no releases yet).
    public static func check() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("Nokcandu/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw NokError("GitHub answered \(code) when checking for Nokcandu updates.") }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(GHRelease.self, from: data)
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        guard !r.draft, isNewer(version, than: currentVersion),
              let a = r.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return nil }
        return Release(version: version, tag: r.tag_name, notes: r.body ?? "", dmg: Updates.asset(a), page: r.html_url)
    }

    /// Published stable app releases with verifiable DMG downloads, for explicit version selection.
    public static func availableVersions() async throws -> [Release] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100")!)
        request.setValue("Nokcandu/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NokError("Could not load Nokcandu releases. Saved versions remain available offline.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GHRelease].self, from: data).compactMap { r in
            guard !r.draft, !r.prerelease, let dmg = r.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  Updates.asset(dmg).sha256 != nil else { return nil }
            return Release(version: r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name,
                           tag: r.tag_name, notes: r.body ?? "", dmg: Updates.asset(dmg), page: r.html_url)
        }.sorted { isNewer($0.version, than: $1.version) }
    }

    /// The same verified, backed-up replacement path handles updates and older releases.
    public static func install(_ r: Release, log: @escaping @Sendable (String) -> Void, quit: @escaping @Sendable () -> Void) async throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw NokError("Nokcandu isn't running from an app bundle.") }
        let dmg = try await Updates.download(r.dmg, log: log)
        let mount = NokPaths.support.appendingPathComponent("Work/update-mount-\(UUID().uuidString)")
        try NokPaths.ensure(mount)
        log("Opening the disk image…")
        let attached = try await Shell.runAsync("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path], timeout: 120)
        guard attached.ok else { try? fm.removeItem(at: mount); throw NokError("Couldn't open the update's disk image.") }
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60); try? fm.removeItem(at: mount) }
        let source = mount.appendingPathComponent("Nokcandu.app")
        let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == r.version else { throw NokError("The app's version doesn't match its release.") }
        // The same signer as the app that is running: the checksum only says the download is what was uploaded.
        try AppSigner.check(update: source, current: current)
        log("Saving the current app and preparing Nokcandu \(r.version)…")
        let plan = try await Task.detached { try AppRollback.prepare(source: source, current: current) }.value
        try AppRollback.launch(plan, quit: quit)
    }
}
