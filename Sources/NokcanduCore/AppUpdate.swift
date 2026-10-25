import Foundation

/// Nokcandu keeping itself current: checks the project's GitHub Releases, downloads the new DMG,
/// verifies it against GitHub's published SHA-256, swaps the app in place and relaunches.
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
            return (core[0].split(separator: ".").map { Int($0) ?? 0 }, core.count > 1 ? String(core[1]) : "")
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

    /// Downloads, verifies and stages the update, then replaces this app and relaunches it.
    /// Calls `quit` once the replacement helper is waiting for Nokcandu to exit.
    public static func install(_ r: Release, log: @escaping @Sendable (String) -> Void, quit: @escaping @Sendable () -> Void) async throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw NokError("Nokcandu isn't running from an app bundle.") }
        let parent = current.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw NokError("Nokcandu can't replace itself in \(parent.path). Download the update from GitHub instead.")
        }
        let dmg = try await Updates.download(r.dmg, log: log)          // refuses without a matching sha256
        let mount = NokPaths.support.appendingPathComponent("Work/update-mount-\(UUID().uuidString.prefix(6))")
        try NokPaths.ensure(mount)
        log("Opening the disk image…")
        let a = try await Shell.runAsync("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path], timeout: 120)
        guard a.ok else { throw NokError("Couldn't open the update: \(a.combined.suffix(200))") }
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60); try? fm.removeItem(at: mount) }
        guard let newApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent == "Nokcandu.app" }) else {
            throw NokError("The update's disk image has no Nokcandu.app.")
        }
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleShortVersionString"] as? String) == r.version else { throw NokError("The update's version doesn't match its release.") }
        let staged = parent.appendingPathComponent(".Nokcandu-\(r.version).app")
        try? fm.removeItem(at: staged)
        log("Copying the new version…")
        let c = try await Shell.runAsync("/usr/bin/ditto", [newApp.path, staged.path], timeout: 300)
        guard c.ok else { throw NokError("Couldn't copy the update: \(c.combined.suffix(200))") }
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        try? fm.removeItem(at: dmg)

        // A small helper swaps the apps after Nokcandu quits (the old one goes to the Trash), then relaunches.
        let script = NokPaths.support.appendingPathComponent("Work/apply-update.sh")
        let q = CustomGames.shellQuote
        let text = """
        #!/bin/bash
        PID=\(ProcessInfo.processInfo.processIdentifier)
        for _ in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
        OLD=\(q(current.path)); NEW=\(q(staged.path))
        TRASH="$HOME/.Trash/Nokcandu \(currentVersion) $(date +%s).app"
        /bin/mv "$OLD" "$TRASH" && /bin/mv "$NEW" "$OLD" || { [ -e "$OLD" ] || /bin/mv "$TRASH" "$OLD"; }
        /usr/bin/open "$OLD"
        rm -f "$0"
        """
        try Data(text.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        log("Restarting into Nokcandu \(r.version)…")
        quit()
    }
}
