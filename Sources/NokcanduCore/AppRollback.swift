import Foundation
import AppKit
import Darwin

/// App-only recovery. Game bundles, runtimes, preferences and saves are never replacement targets.
public enum AppRollback {
    public static let bundleID = "io.github.seastwood.nokcandu"
    nonisolated(unsafe) public static var recoveryHelperOverride: URL?
    public static var root: URL { NokPaths.support.appendingPathComponent("App Versions") }
    public struct Saved: Codable, Identifiable, Equatable {
        public var id: UUID
        public var version: String
        public var build: String
        public var savedAt: Date
        public var appSHA: String
        public var originalPath: String
        public func folder(in root: URL = AppRollback.root) -> URL { root.appendingPathComponent(id.uuidString) }
        public func app(in root: URL = AppRollback.root) -> URL { folder(in: root).appendingPathComponent("Nokcandu.app") }
    }
    public struct Plan: Codable {
        public var current: URL
        public var staged: URL
        public var displaced: URL
        public var backup: Saved
        public var archiveRoot: URL
        public var expectedCurrentSHA: String
        public var expectedNewSHA: String
        public var waitingPID: Int32
    }

    static func info(_ app: URL) throws -> (String, String, String) {
        guard app.pathExtension == "app", app.standardizedFileURL == app.resolvingSymlinksInPath(),
              let p = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              p["CFBundleIdentifier"] as? String == bundleID,
              p["CFBundleExecutable"] as? String == "Nokcandu",
              let version = p["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            throw NokError("This is not an intact Nokcandu app. Nothing was replaced.")
        }
        let signature = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 120)
        guard signature.ok else { throw NokError("Nokcandu's signature check failed. Nothing was replaced.") }
        if let minimum = p["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard !AppUpdate.isNewer(minimum, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
                throw NokError("This version requires macOS \(minimum) or later.")
            }
        }
        let components = try ["Contents/MacOS/Nokcandu", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"].map { relative in
            try Hashing.sha256(file: app.appendingPathComponent(relative))
        }
        return (version, p["CFBundleVersion"] as? String ?? "", Hashing.sha256(data: Data(components.joined(separator: "\n").utf8)))
    }

    public static func saved(in archiveRoot: URL = root) -> [Saved] {
        ((try? FileManager.default.contentsOfDirectory(at: archiveRoot, includingPropertiesForKeys: nil)) ?? []).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  folder.standardizedFileURL == folder.resolvingSymlinksInPath(),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("version.json")),
                  let entry = try? JSONDecoder().decode(Saved.self, from: data),
                  entry.id.uuidString == folder.lastPathComponent else { return nil }
            return entry
        }.sorted { $0.savedAt > $1.savedAt }
    }

    /// Explicitly keeps a signed copy before any app swap; never prunes a working recovery copy.
    @discardableResult public static func archive(_ app: URL, in archiveRoot: URL = root) throws -> Saved {
        let app = app.resolvingSymlinksInPath()
        let (version, build, sha) = try info(app)
        if let existing = saved(in: archiveRoot).first(where: { $0.appSHA == sha && $0.originalPath == app.path }),
           let checked = try? info(existing.app(in: archiveRoot)), checked.2 == sha,
           FileManager.default.isExecutableFile(atPath: existing.folder(in: archiveRoot).appendingPathComponent("restore-helper").path),
           FileManager.default.isExecutableFile(atPath: existing.folder(in: archiveRoot).appendingPathComponent("Restore Nokcandu.command").path) { return existing }
        let entry = Saved(id: UUID(), version: version, build: build, savedAt: Date(), appSHA: sha, originalPath: app.path)
        let folder = entry.folder(in: archiveRoot)
        try NokPaths.ensure(folder)
        do {
            try copy(app, to: entry.app(in: archiveRoot))
            guard try info(entry.app(in: archiveRoot)).2 == sha else { throw NokError("The recovery copy could not be verified.") }
            try JSONEncoder().encode(entry).write(to: folder.appendingPathComponent("version.json"), options: .atomic)
            // Independent recovery remains usable even when the installed UI will not launch.
            guard let helper = recoveryHelperOverride ?? NokPaths.bundledResource("nokcandu-settings", executable: true) else {
                throw NokError("The recovery helper is missing. Reinstall Nokcandu before changing versions.")
            }
            do {
                let tool = folder.appendingPathComponent("restore-helper")
                try FileManager.default.copyItem(at: helper, to: tool)
                let command = "#!/bin/bash\nset -e\n" + CustomGames.shellQuote(tool.path) + " --restore-app " + CustomGames.shellQuote(entry.app(in: archiveRoot).path) + " " + CustomGames.shellQuote(app.path) + " --archive-root " + CustomGames.shellQuote(archiveRoot.path) + "\necho 'Recovery finished.'\n"
                let file = folder.appendingPathComponent("Restore Nokcandu.command")
                try Data(command.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            return entry
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    static func copy(_ source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw NokError("The app staging location is already occupied.") }
        let result = try Shell.run("/usr/bin/ditto", [source.path, destination.path], timeout: 300)
        guard result.ok else { throw NokError("Could not copy Nokcandu. The installed version is unchanged.") }
    }

    public static func prepare(source: URL, current: URL, archiveRoot: URL = root, waitingPID: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> Plan {
        let current = current.resolvingSymlinksInPath(), source = source.resolvingSymlinksInPath()
        guard source != current, !current.path.hasPrefix(archiveRoot.resolvingSymlinksInPath().path + "/"),
              FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw NokError("Run Nokcandu from its installed location before changing versions.")
        }
        let oldInfo = try info(current), newInfo = try info(source)
        let backup = try archive(current, in: archiveRoot)
        let uid = UUID().uuidString
        let staged = current.deletingLastPathComponent().appendingPathComponent(".Nokcandu-stage-\(uid).app")
        do {
            try copy(source, to: staged)
            guard try info(staged).2 == newInfo.2 else { throw NokError("The staged app could not be verified.") }
        } catch { try? FileManager.default.removeItem(at: staged); throw error }
        return Plan(current: current, staged: staged,
                    displaced: current.deletingLastPathComponent().appendingPathComponent(".Nokcandu-before-\(uid).app"),
                    backup: backup, archiveRoot: archiveRoot, expectedCurrentSHA: oldInfo.2, expectedNewSHA: newInfo.2, waitingPID: waitingPID)
    }

    /// Executed by a copied helper after the UI exits. Refuses timeout, stale plans and concurrent swaps.
    public static func replace(_ plan: Plan, waitSeconds: TimeInterval = 60, relaunch: Bool = true) throws {
        let fm = FileManager.default
        try NokPaths.ensure(plan.archiveRoot)
        let fd = Darwin.open(plan.archiveRoot.appendingPathComponent("replacement.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NokError("Could not lock app replacement.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NokError("Another app replacement is already running.") }
        defer { _ = flock(fd, LOCK_UN) }
        let deadline = Date().addingTimeInterval(waitSeconds)
        while plan.waitingPID > 0 && kill(plan.waitingPID, 0) == 0 {
            guard Date() < deadline else { throw NokError("Nokcandu did not close. Its installed version is unchanged; quit it before retrying.") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.bundleURL?.resolvingSymlinksInPath() == plan.current }) else {
            throw NokError("Nokcandu is still running. Quit it before restoring a version.")
        }
        guard plan.staged.deletingLastPathComponent() == plan.current.deletingLastPathComponent(),
              plan.displaced.deletingLastPathComponent() == plan.current.deletingLastPathComponent(),
              plan.staged.lastPathComponent.hasPrefix(".Nokcandu-stage-"),
              plan.displaced.lastPathComponent.hasPrefix(".Nokcandu-before-"),
              plan.staged != plan.displaced,
              !fm.fileExists(atPath: plan.displaced.path),
              try info(plan.current).2 == plan.expectedCurrentSHA,
              try info(plan.staged).2 == plan.expectedNewSHA,
              try info(plan.backup.app(in: plan.archiveRoot)).2 == plan.expectedCurrentSHA else {
            throw NokError("The apps changed after preparation. Nothing was replaced; prepare the change again.")
        }
        try fm.moveItem(at: plan.current, to: plan.displaced)
        do {
            try fm.moveItem(at: plan.staged, to: plan.current)
            guard try info(plan.current).2 == plan.expectedNewSHA else { throw NokError("The installed app could not be verified.") }
        } catch {
            if fm.fileExists(atPath: plan.current.path) { try? fm.moveItem(at: plan.current, to: plan.staged) }
            try fm.moveItem(at: plan.displaced, to: plan.current)
            throw error
        }
        // The verified durable backup exists. Keep an unexpected changed original rather than deleting it.
        if (try? info(plan.displaced).2) == plan.expectedCurrentSHA { try? fm.removeItem(at: plan.displaced) }
        if relaunch { _ = try Shell.run("/usr/bin/open", [plan.current.path]) }
    }

    /// Independent recovery also handles a missing or damaged installed app after an interrupted swap.
    public static func recover(source: URL, current: URL, archiveRoot: URL = root, relaunch: Bool = true) throws {
        let current = current.resolvingSymlinksInPath(), source = source.resolvingSymlinksInPath()
        if (try? info(current)) != nil {
            let plan = try prepare(source: source, current: current, archiveRoot: archiveRoot, waitingPID: 0)
            try replace(plan, relaunch: relaunch)
            return
        }
        guard current.pathExtension == "app", source != current,
              !current.path.hasPrefix(archiveRoot.resolvingSymlinksInPath().path + "/"),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.bundleURL?.resolvingSymlinksInPath() == current }) else {
            throw NokError("Quit the installed Nokcandu before recovering it.")
        }
        let fingerprint = try info(source).2
        try NokPaths.ensure(archiveRoot)
        let fd = Darwin.open(archiveRoot.appendingPathComponent("replacement.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NokError("Could not lock app recovery.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NokError("Another app replacement is already running.") }
        defer { _ = flock(fd, LOCK_UN) }
        let stage = current.deletingLastPathComponent().appendingPathComponent(".Nokcandu-stage-\(UUID().uuidString).app")
        try copy(source, to: stage)
        guard try info(stage).2 == fingerprint else { throw NokError("The recovery copy could not be verified.") }
        let damaged = current.deletingLastPathComponent().appendingPathComponent(".Nokcandu-damaged-\(UUID().uuidString).app")
        let hadOriginal = FileManager.default.fileExists(atPath: current.path)
        if hadOriginal { try FileManager.default.moveItem(at: current, to: damaged) }
        do { try FileManager.default.moveItem(at: stage, to: current) }
        catch {
            if hadOriginal { try FileManager.default.moveItem(at: damaged, to: current) }
            throw error
        }
        // A damaged app is retained for investigation rather than silently removed.
        if hadOriginal { print("The damaged app was preserved at \(damaged.path).") }
        if relaunch { _ = try Shell.run("/usr/bin/open", [current.path]) }
    }

    public static func launch(_ plan: Plan, quit: @escaping @Sendable () -> Void) throws {
        guard let helper = NokPaths.bundledResource("nokcandu-settings", executable: true) else { throw NokError("The app replacement helper is missing. Reinstall Nokcandu before changing versions.") }
        let work = NokPaths.support.appendingPathComponent("Work/app-replacement-\(UUID().uuidString)")
        try NokPaths.ensure(work)
        let tool = work.appendingPathComponent("replace-helper"), file = work.appendingPathComponent("plan.json")
        try FileManager.default.copyItem(at: helper, to: tool)
        try JSONEncoder().encode(plan).write(to: file, options: .atomic)
        let process = Process(); process.executableURL = tool; process.arguments = ["--replace-app", file.path]
        let output = work.appendingPathComponent("result.txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle; process.standardError = handle
        try process.run(); try? handle.close(); quit()
    }
}
