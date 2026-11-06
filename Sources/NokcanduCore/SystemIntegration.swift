import Foundation

/// The places Nokcandu touches macOS beyond its own files: the Trash and LaunchServices (the database behind the
/// Apps launcher, the Games app, Spotlight's app results and Open With). Unit tests make throwaway games, so
/// while tests run nothing goes to the user's Trash and nothing is registered with LaunchServices.
public enum SystemIntegration {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Moves to the Trash (removes outright while tests run).
    public static func trash(_ url: URL) throws {
        if isTesting { try FileManager.default.removeItem(at: url); return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public static func register(_ app: URL) {
        guard !isTesting else { return }
        _ = try? Shell.run(lsregister, ["-f", app.path], timeout: 30)
    }
    public static func unregister(_ app: URL) {
        guard !isTesting else { return }
        _ = try? Shell.run(lsregister, ["-u", app.path], timeout: 30)
    }

    // MARK: Stale app records

    /// One app record in LaunchServices' database.
    struct Record: Equatable { var path: String; var identifier: String? }

    static func records(dump: String) -> [Record] {
        dump.components(separatedBy: "\n--------------------------------------------------------------------------------").compactMap { block in
            var path: String?, identifier: String?
            for line in block.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
                if line.hasPrefix("path:"), path == nil {
                    var p = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let r = p.range(of: " (0x", options: .backwards) { p = String(p[..<r.lowerBound]) }
                    path = p
                } else if line.hasPrefix("identifier:"), identifier == nil {
                    identifier = line.dropFirst(11).trimmingCharacters(in: .whitespaces)
                }
            }
            guard let path, path.hasSuffix(".app") else { return nil }
            return Record(path: path, identifier: identifier)
        }
    }

    /// Records of Nokcandu's apps that no longer match a real app on disk: copies that were moved, deleted or
    /// trashed, the same app reached through a link (a moved game's Applications entry), restore-point clones,
    /// and throwaway apps in temporary folders. Each makes a game appear twice (or as a dead entry) in the Apps
    /// launcher and the Games app.
    static func stale(_ records: [Record], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                      resolve: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) -> [Record] {
        let temporary = ["/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/"]
        return records.filter { r in
            let ours = r.identifier?.hasPrefix("local.nokcandu.") == true
            if r.path.contains("/.Nokcandu Restore Points/") { return true }
            guard ours else { return false }
            if r.path.contains("/.Trash/") || temporary.contains(where: { r.path.hasPrefix($0) }) { return true }
            if !exists(r.path) { return true }
            let real = resolve(r.path)
            return real != r.path && !real.hasPrefix("/private" + r.path)
        }
    }

    /// The first symbolic link along a path (an app folder in Applications that points at the game's drive).
    static func linkComponent(of path: String) -> URL? {
        var url = URL(fileURLWithPath: "/")
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { return url }
        }
        return nil
    }

    /// Removes stale records, then registers the real apps behind linked ones again (so each game stays known
    /// once). At most once a day; call off the main thread. Returns how many records were removed.
    @discardableResult
    public static func cleanLaunchServices(force: Bool = false, defaults: UserDefaults = .standard) -> Int {
        guard !isTesting else { return 0 }
        let key = "launchServicesCleaned"
        if !force, Date().timeIntervalSince1970 - defaults.double(forKey: key) < 86_400 { return 0 }
        defaults.set(Date().timeIntervalSince1970, forKey: key)
        // The database dump is tens of megabytes: written to a file (Shell keeps only a bounded amount of output).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nokcandu-ls-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else { return 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsregister); p.arguments = ["-dump"]
        p.standardOutput = handle; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        p.waitUntilExit(); try? handle.close()
        guard p.terminationStatus == 0, let data = try? Data(contentsOf: file) else { return 0 }
        let stale = stale(records(dump: String(decoding: data, as: UTF8.self)))
        var reregister = Set<String>()
        for s in stale {
            let real = URL(fileURLWithPath: s.path).resolvingSymlinksInPath().path
            // LaunchServices follows links, so a record made through one (a moved game's Applications entry) can only
            // be removed while its link is briefly out of the way; it goes straight back.
            if let link = linkComponent(of: s.path) {
                let aside = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).nokcandu-relink")
                if (try? FileManager.default.moveItem(at: link, to: aside)) != nil {
                    _ = try? Shell.run(lsregister, ["-u", s.path], timeout: 30)
                    if (try? FileManager.default.moveItem(at: aside, to: link)) == nil, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: aside.path) {
                        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dest)
                        try? FileManager.default.removeItem(at: aside)
                    }
                }
            } else {
                _ = try? Shell.run(lsregister, ["-u", s.path], timeout: 30)
            }
            if real != s.path, FileManager.default.fileExists(atPath: real), !real.contains("/.Trash/") { reregister.insert(real) }
        }
        for p in reregister { _ = try? Shell.run(lsregister, ["-f", p], timeout: 30) }
        return stale.count
    }
}
