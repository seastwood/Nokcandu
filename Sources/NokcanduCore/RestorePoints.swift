import Foundation
import Darwin

/// Restore points: an instant APFS clone of a game's whole app (its Windows environment, engine and
/// settings) taken before risky changes — fixes, recommended setups, engine updates — so a game that
/// stops working can be put back exactly as it was. A clone shares the disk blocks with the original,
/// so it costs nothing until the two start to differ.
///
/// Kept next to the app, in a hidden "Nokcandu Restore Points" folder on the same drive (clones can't
/// cross drives). Game files linked from another drive aren't part of the app and aren't included.
public struct RestorePoint: Identifiable, Hashable, Sendable, Codable {
    public var reason: String
    public var created: Date
    public var automatic: Bool
    public var nokcanduVersion: String?
    /// Folder holding `info.json` and the cloned app.
    public var folder: URL
    public var id: String { folder.path }
    public var app: URL { folder.appendingPathComponent("App", isDirectory: true) }
}

public enum RestorePoints {
    /// How many automatic restore points to keep per app (ones you take yourself are kept until you delete them).
    public static let keepAutomatic = 5
    /// Off while unit tests run (their throwaway apps don't need restore points).
    static var automaticEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        && NSClassFromString("XCTestCase") == nil
    static let folderName = ".Nokcandu Restore Points"

    /// The app that actually holds the Windows environment (a Battle.net game's is Battle.net's).
    public static func hostApp(for g: InstalledGame) -> URL? {
        guard g.native == nil, !g.usesSharedSteam, let c = WineTools.hostContents(for: g) else { return nil }
        return c.deletingLastPathComponent()
    }

    public static func root(for app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(app.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    public static func list(for g: InstalledGame) -> [RestorePoint] {
        guard let app = hostApp(for: g) else { return [] }
        return list(app: app)
    }

    public static func list(app: URL) -> [RestorePoint] {
        let r = root(for: app)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("info.json")),
                  var p = try? JSONDecoder().decode(RestorePoint.self, from: data),
                  FileManager.default.fileExists(atPath: d.appendingPathComponent("App").path) else { return nil }
            p.folder = d
            return p
        }.sorted { $0.created > $1.created }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmmss"; return f
    }()

    static func unique(_ dir: URL, _ name: String) -> URL {
        var u = dir.appendingPathComponent(name, isDirectory: true), n = 2
        while FileManager.default.fileExists(atPath: u.path) { u = dir.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1 }
        return u
    }

    /// Take a restore point. `automatic` ones are skipped if one was taken in the last 2 minutes (so a
    /// group of changes gets one point) and are pruned to the newest few.
    @discardableResult
    public static func create(app: URL, reason: String, automatic: Bool) throws -> RestorePoint? {
        let fm = FileManager.default
        let existing = list(app: app)
        if automatic, let last = existing.first, Date().timeIntervalSince(last.created) < 120 { return nil }
        let r = root(for: app)
        try fm.createDirectory(at: r, withIntermediateDirectories: true)
        let folder = unique(r, stamp.string(from: Date()))
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let dest = folder.appendingPathComponent("App")
        guard clonefile(app.path, dest.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
            let err = errno
            try? fm.removeItem(at: folder)
            if err == ENOTSUP || err == EXDEV { throw NokError("Restore points need a Mac-formatted (APFS) drive.") }
            throw NokError("Couldn't take a restore point: \(String(cString: strerror(err))).")
        }
        let p = RestorePoint(reason: reason, created: Date(), automatic: automatic,
                             nokcanduVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, folder: folder)
        try JSONEncoder().encode(p).write(to: folder.appendingPathComponent("info.json"), options: .atomic)
        if automatic { prune(app: app) }
        return p
    }

    /// Before a risky change: take an automatic restore point if possible. Never stops the change.
    public static func before(_ g: InstalledGame, _ reason: String, log: (@Sendable (String) -> Void)? = nil) {
        guard automaticEnabled, let app = hostApp(for: g) else { return }
        do { if try create(app: app, reason: reason, automatic: true) != nil { log?("Took a restore point.") } }
        catch { log?("No restore point: \(error.localizedDescription)") }
    }

    static func prune(app: URL) {
        let autos = list(app: app).filter(\.automatic)
        for p in autos.dropFirst(keepAutomatic) { try? FileManager.default.removeItem(at: p.folder) }
    }

    public static func delete(_ p: RestorePoint) throws {
        try FileManager.default.removeItem(at: p.folder)
    }

    /// Put the app back as it was. The current app becomes a restore point itself ("Before restoring"),
    /// so a restore can be undone too.
    public static func restore(_ p: RestorePoint, app: URL) throws {
        let fm = FileManager.default
        if let g = GameLibrary.inspect(app), case .launcherRunning = GameLauncher.runState(of: g) {
            throw NokError("Quit \(g.name) first.")
        }
        guard fm.fileExists(atPath: p.app.path) else { throw NokError("That restore point is missing.") }
        let r = root(for: app)
        let aside = unique(r, stamp.string(from: Date()) + " before restore")
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        // Move (not copy) the current app aside: instant, and nothing is lost if the clone fails.
        try fm.moveItem(at: app, to: aside.appendingPathComponent("App"))
        let info = RestorePoint(reason: "Before restoring \(p.created.formatted(date: .abbreviated, time: .shortened))",
                                created: Date(), automatic: false, nokcanduVersion: nil, folder: aside)
        try? JSONEncoder().encode(info).write(to: aside.appendingPathComponent("info.json"), options: .atomic)
        guard clonefile(p.app.path, app.path, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.moveItem(at: aside.appendingPathComponent("App"), to: app)
            try? fm.removeItem(at: aside)
            throw NokError("Couldn't restore: \(err). Nothing was changed.")
        }
    }

    /// Disk space a restore point uses on its own (what deleting it frees).
    public static func size(_ p: RestorePoint) -> Int64 { Storage.size(p.app) }
}
