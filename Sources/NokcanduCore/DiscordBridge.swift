import Foundation

/// "Show what you're playing in Discord": Discord Rich Presence for Windows games.
///
/// Windows games talk to Discord through a named pipe (\\.\pipe\discord-ipc-0). rpc-bridge (EnderIce2, MIT; the
/// bridge Sikarugir uses) runs as a small Windows service inside the game's environment and forwards that pipe to
/// the Mac Discord app's socket in $TMPDIR, which every launcher passes to Wine as BRIDGE_RPC_PATH (so no
/// LaunchAgent is needed). Off by default; installed into each environment before a launch while it's closed.
public enum DiscordBridge {
    public static let version = "1.4.1.3"
    static let url = "https://github.com/EnderIce2/rpc-bridge/releases/download/v1.4.1.3/bridge.zip"
    static let sha = "2e348b851b54a99b6e062289bdb1f5bc4c86efcb1ef2b3e748ee29f0fdd143e7"

    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "discordPresence") }
        set { UserDefaults.standard.set(newValue, forKey: "discordPresence") }
    }
    static func marker(_ prefix: URL) -> URL { prefix.appendingPathComponent(".nokcandu-discord-bridge") }
    static func installed(_ prefix: URL) -> String? {
        (try? String(contentsOf: marker(prefix), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bridge program, downloaded once (checksummed) and unpacked into Nokcandu's tools.
    static func bridgeExe(log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let dir = NokPaths.support.appendingPathComponent("Tools/rpc-bridge-\(version)", isDirectory: true)
        let exe = dir.appendingPathComponent("bridge.exe")
        if FileManager.default.fileExists(atPath: exe.path) { return exe }
        let zip = try await CompatibilityFixes.verifiedDownload("rpc-bridge-\(version).zip", url: url, sha: sha, log: log)
        try NokPaths.ensure(dir)
        let r = try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 60)
        guard r.ok else { throw NokError("Couldn't unpack the Discord bridge: \(r.combined.suffix(200))") }
        if !FileManager.default.fileExists(atPath: exe.path),
           let found = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
               .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.lowercased() == "bridge.exe" }) {
            try FileManager.default.moveItem(at: found, to: exe)
        }
        guard FileManager.default.fileExists(atPath: exe.path) else { throw NokError("The Discord bridge download has no bridge.exe.") }
        return exe
    }

    /// Before a launch: install (or, when switched off, remove) the bridge in a closed environment.
    public static func prepareForLaunch(_ g: InstalledGame) async {
        guard g.native == nil, let h = WineTools.hostContents(for: g) else { return }
        let prefix = h.appendingPathComponent("SharedSupport/prefix")
        let have = installed(prefix)
        guard (enabled && have != version) || (!enabled && have != nil) else { return }
        if await WineTools.environmentIsRunning(for: g) { return }
        let wine = h.appendingPathComponent("SharedSupport/wine/bin/wine").path
        let env = WineTools.environment(contents: h)
        do {
            if enabled {
                let exe = try await bridgeExe(log: { _ in })
                let dst = prefix.appendingPathComponent("drive_c/windows/bridge.exe")
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: exe, to: dst)
                _ = try await Shell.runAsync(wine, [#"C:\windows\bridge.exe"#, "--install"], env: env, timeout: 120)
                try Data(version.utf8).write(to: marker(prefix), options: .atomic)
            } else {
                _ = try await Shell.runAsync(wine, [#"C:\windows\bridge.exe"#, "--uninstall"], env: env, timeout: 120)
                try? FileManager.default.removeItem(at: marker(prefix))
            }
            _ = try? await Shell.runAsync(h.appendingPathComponent("SharedSupport/wine/bin/wineserver").path, ["-w"], env: env, timeout: 60)
        } catch {}
    }
}
