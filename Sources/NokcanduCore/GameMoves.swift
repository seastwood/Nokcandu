import Foundation
import Darwin

/// Moving a game, or a launcher with everything installed in it, with a clear plan of what goes where.
///
/// A game has two parts that can live apart:
///  • the app — Wine engine, Windows setup (registry, settings, saves inside Windows) and Nokcandu's settings.
///    It needs a Mac-formatted drive (APFS or Mac OS Extended), because Wine relies on symbolic links.
///  • the game's own files (its folder inside drive C) — these can go on any drive, ExFAT included; the app
///    keeps a link to them.
/// Launchers (Steam, Battle.net, EA app, Ubisoft Connect) move whole, with every game installed inside
/// them, and leave a link at their old place so their games' shortcuts keep working.
public struct MovePlan: Sendable, Equatable {
    public var name: String
    public var isLauncher: Bool
    /// Where the app really is (a moved launcher's real place, not its link).
    public var appLocation: URL
    /// What copying the app to another drive writes there (game files inside it included).
    public var appBytes: Int64
    /// The game's folder inside drive C (nil: unknown, or the app has none of its own).
    public var filesFolder: URL?
    /// Where those files really are (inside the app, or on another drive).
    public var filesLocation: URL?
    public var filesBytes: Int64
    /// On the drive they're on now (larger than `filesBytes` on ExFAT, which stores small files in big blocks).
    public var filesAllocated: Int64
    public var filesExternal: Bool
    public var restorePoints: Int
    public var restorePointBytes: Int64
    /// The copy of the previous Wine engine kept while a new one is tried.
    public var rollbackBytes: Int64
    /// Why the app (or the files) can't move now, or nil.
    public var appBlocker: String?
    public var filesBlocker: String?
    /// Other Nokcandu games that move along (a launcher's games).
    public var passengers: [String]
}

public enum FilesDestination: Hashable, Sendable {
    /// Leave them where they are.
    case keep
    /// Inside the app (wherever the app goes).
    case withApp
    /// In this folder on any drive; the app links to them.
    case folder(URL)
}

public struct MoveRequest: Sendable {
    public var appFolder: URL?
    public var files: FilesDestination
    public var keepOldRestorePoints: Bool
    public var dropRollbackCopy: Bool
    public init(appFolder: URL?, files: FilesDestination, keepOldRestorePoints: Bool = false, dropRollbackCopy: Bool = false) {
        self.appFolder = appFolder; self.files = files; self.keepOldRestorePoints = keepOldRestorePoints; self.dropRollbackCopy = dropRollbackCopy
    }
}

extension GameMover {
    public static func isLauncher(_ g: InstalledGame) -> Bool {
        g.isSteamHost || BattleNet.isHost(g) || PCLaunchers.kind(of: g) != nil
    }

    /// Sizes everything (walks the folders: call off the main thread).
    public static func plan(for g: InstalledGame, library: [InstalledGame]) -> MovePlan {
        let launcher = isLauncher(g)
        let real = g.appURL.resolvingSymlinksInPath()
        let inPrefix = launcher ? nil : gameFilesFolder(g)
        let external = launcher ? nil : externalFiles(g)
        let filesLocation = external ?? inPrefix.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let (apparent, allocated) = filesLocation.map { Storage.apparentAndAllocated($0) } ?? (0, 0)
        let points = RestorePoints.list(app: real)
        let pointBytes = points.first.map { Storage.allocatedSize($0.app) } ?? 0
        var appBlocker = launcher ? launcherBlocker(g, library: library) : blocker(g)
        if appBlocker == nil, g.usesSharedSteam || g.battleNet != nil || g.hosted != nil {
            appBlocker = "This game is installed inside its launcher. Move the launcher to move it."
        }
        let passengers: [String] = launcher ? library.filter { other in
            other.appURL != g.appURL && WineTools.hostContents(for: other).map { $0.resolvingSymlinksInPath() == g.contents.resolvingSymlinksInPath() } == true
        }.map(\.name) : []
        return MovePlan(name: g.name, isLauncher: launcher, appLocation: real,
                        appBytes: Storage.allocatedSize(real), filesFolder: inPrefix, filesLocation: filesLocation,
                        filesBytes: apparent, filesAllocated: allocated, filesExternal: external != nil,
                        restorePoints: points.count, restorePointBytes: pointBytes,
                        rollbackBytes: EngineUpdate.hasRollbackCopy(g) ? Storage.allocatedSize(EngineUpdate.rollbackDir(g.contents)) : 0,
                        appBlocker: appBlocker, filesBlocker: launcher ? "Launchers keep their games inside them." : filesBlocker(g),
                        passengers: passengers)
    }

    /// A launcher can move when it and everything running in it is closed.
    public static func launcherBlocker(_ g: InstalledGame, library: [InstalledGame]) -> String? {
        if g.native != nil { return "Mac games stay where they are." }
        if GameLauncher.runState(of: g) != .notRunning { return "Quit \(g.name) first." }
        if let c = WineTools.hostContents(for: g), !WineTools.ownedProcesses(contents: c).isEmpty {
            return "Quit \(g.name) and its games first."
        }
        let running = library.filter { other in
            WineTools.hostContents(for: other).map { $0.resolvingSymlinksInPath() == g.contents.resolvingSymlinksInPath() } == true
                && GameLauncher.runState(of: other) != .notRunning
        }
        if let r = running.first { return "Quit \(r.name) first." }
        return nil
    }

    /// Runs the whole request. Returns the app's (possibly new) location in the library.
    @discardableResult
    public static func perform(_ g: InstalledGame, _ request: MoveRequest, library: [InstalledGame],
                               progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> (app: URL, notes: [String]) {
        var notes: [String] = []
        var game = g
        if request.dropRollbackCopy, EngineUpdate.hasRollbackCopy(game) {
            try EngineUpdate.keep(game)
            notes.append("Kept the new engine and removed the old one's copy.")
        }
        let currentFolder = game.appURL.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
        let appTarget = request.appFolder.flatMap { $0.standardizedFileURL.resolvingSymlinksInPath() == currentFolder.resolvingSymlinksInPath() ? nil : $0 }

        // 1. Game files that go to their own folder move first, so the app copy is smaller.
        if case .folder(let dest) = request.files {
            let currentFiles = (externalFiles(game) ?? gameFilesFolder(game))?.resolvingSymlinksInPath().deletingLastPathComponent()
            if currentFiles?.standardizedFileURL != dest.resolvingSymlinksInPath().standardizedFileURL {
                progress("Moving \(game.name)'s files to \(GameFolders.volumeName(dest))…")
                try moveFiles(game, to: dest, progress: progress)
                notes.append("Game files are on \(GameFolders.volumeName(dest)).")
            }
        }
        // 2. The app.
        var appURL = game.appURL
        if let target = appTarget {
            let before = game.appURL.resolvingSymlinksInPath()
            // Every app keeps its place in the Applications folder (a link while it lives on another drive),
            // so Finder, Launchpad, the Dock and everything that remembers its path still find it.
            appURL = try moveAnchored(game, to: target, library: library, progress: progress)
            InstallRecords.relocate(from: game.appURL, to: appURL)
            let after = appURL.resolvingSymlinksInPath()
            // On another drive, store the Wine engine once for all apps there.
            if EngineShare.volumeRoot(after) != nil {
                progress("Sharing Wine engine files with other apps on \(Storage.driveName(after))…")
                if let freed = try? EngineShare.share(app: after), freed > 50_000_000 {
                    notes.append("Shares its Wine engine files with other apps there (saved \(Storage.format(freed))).")
                }
            }
            if let note = RestorePoints.followMove(from: before, to: after, keepOld: request.keepOldRestorePoints) { notes.append(note) }
            game = GameLibrary.inspect(appURL) ?? game
            notes.append("\(game.name) is now on \(GameFolders.volumeName(target)).")
        }
        // 3. Files that go back inside the app (now that the app is where it should be).
        if case .withApp = request.files, externalFiles(game) != nil {
            progress("Moving \(game.name)'s files into the app…")
            try moveFiles(game, to: nil, progress: progress)
            notes.append("Game files are inside the app on \(Storage.driveName(game.appURL.resolvingSymlinksInPath())).")
        }
        return (appURL, notes)
    }

    // MARK: Launchers

    /// Moves a launcher's real app to `folder` and leaves a link at its library place, so every game set up in
    /// it (and anything else that remembers the path) keeps working. Moving it back to its library folder
    /// replaces the link with the app again.
    /// The app's place in the standard games folder (~/Applications/…): a real app, or a link to it.
    public static func anchor(for g: InstalledGame) -> URL {
        NokPaths.gameAppsFolder.standardizedFileURL.appendingPathComponent(g.appURL.lastPathComponent)
    }

    /// Moves the real app to `folder` and keeps a link at its place in the standard games folder, so it still
    /// shows in Applications and every game set up in it (for a launcher) keeps working. Moving it back to the
    /// standard folder replaces the link with the app again.
    public static func moveAnchored(_ g: InstalledGame, to folder: URL, library: [InstalledGame],
                                    progress: @escaping @Sendable (String) -> Void) throws -> URL {
        if let b = isLauncher(g) ? launcherBlocker(g, library: library) : blocker(g) { throw NokError(b) }
        let fm = FileManager.default
        let anchor = anchor(for: g)
        let real = g.appURL.resolvingSymlinksInPath()
        let anchorIsLink = (try? fm.destinationOfSymbolicLink(atPath: anchor.path)) != nil
        let anchorIsReal = !anchorIsLink && fm.fileExists(atPath: anchor.path)
        if anchorIsReal, anchor.resolvingSymlinksInPath() != real {
            throw NokError("Another app called \(anchor.lastPathComponent) is already in \(NokPaths.gameAppsFolder.path). Rename one of them first.")
        }
        let dest = folder.standardizedFileURL
        guard GameFolders.holdsApps(dest) else {
            throw NokError("\(g.name) needs a Mac-formatted drive (APFS or Mac OS Extended): its Windows setup relies on links ExFAT can't store. Create an APFS games volume on that drive in Storage → Drives, then move it there.")
        }
        if let p = GameFolders.problem(with: dest) { throw NokError(p) }
        let backHome = dest.resolvingSymlinksInPath() == anchor.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = backHome ? anchor : dest.appendingPathComponent(anchor.lastPathComponent)
        guard backHome ? !anchorIsReal : target.resolvingSymlinksInPath() != real else { throw NokError("\(g.name) is already there.") }
        if !backHome, fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            throw NokError("There's already an app called \(anchor.lastPathComponent) in that folder.")
        }
        // Disc images stay mounted inside the app; eject them so the copy doesn't include their contents.
        for m in (try? fm.contentsOfDirectory(at: real.appendingPathComponent("Contents/SharedSupport"), includingPropertiesForKeys: nil)) ?? []
            where m.lastPathComponent.hasPrefix("MountedDisc") {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", m.resolvingSymlinksInPath().path, "-force"], timeout: 60)
        }

        let sameDrive = volumeID(real.deletingLastPathComponent()) != nil && volumeID(real.deletingLastPathComponent()) == volumeID(target.deletingLastPathComponent())
        if sameDrive {
            // Same drive: an instant rename, no copy.
            progress("Moving…")
            if backHome, anchorIsLink { try fm.removeItem(at: anchor) }
            try fm.moveItem(at: real, to: target)
        } else {
            try copyVerified(real, to: target, replacingLink: backHome && anchorIsLink ? anchor : nil, progress: progress)
        }
        // Paths inside the app that named its old real place (an earlier move by older versions).
        if real != anchor { try? fixPaths(in: target, from: real) }
        if !backHome {
            // Point the Applications entry at the new place.
            if anchorIsLink { try? fm.removeItem(at: anchor) }
            if anchorIsReal, fm.fileExists(atPath: real.path), real == anchor.resolvingSymlinksInPath() {
                // (Only when the app was copied: a same-drive rename already took it away.)
                let aside = anchor.deletingLastPathComponent().appendingPathComponent(".\(anchor.lastPathComponent).nokcandu-old")
                try? fm.removeItem(at: aside)
                try fm.moveItem(at: anchor, to: aside)
                do { try fm.createSymbolicLink(at: anchor, withDestinationURL: target) }
                catch { try? fm.moveItem(at: aside, to: anchor); try? fm.removeItem(at: target); throw error }
                progress("Removing the old copy…")
                try? fm.removeItem(at: aside)
            } else {
                try fm.createSymbolicLink(at: anchor, withDestinationURL: target)
            }
        }
        if fm.fileExists(atPath: real.path), real != target.resolvingSymlinksInPath(), real != anchor {
            progress("Removing the old copy…")
            do { try fm.removeItem(at: real) } catch { progress("The old copy couldn't be removed (\(error.localizedDescription)); you can delete it in Finder.") }
        }
        Discs.prepareMountPoints(support: target.appendingPathComponent("Contents/SharedSupport"))
        // Launch Services: forget the old copy, know the new one (Spotlight, the Apps launcher, Open With).
        if real != target.resolvingSymlinksInPath(), !fm.fileExists(atPath: real.path) {
            _ = try? Shell.run(GameApp.lsregister, ["-u", real.path], timeout: 30)
        }
        _ = try? Shell.run(GameApp.lsregister, ["-f", target.path], timeout: 30)
        // The library works with real apps (the link is the Applications entry).
        return target.resolvingSymlinksInPath()
    }

    /// Games moved to another library folder by earlier versions disappeared from Applications. Give each a
    /// link at its standard place (nothing is moved). Returns the names linked.
    @discardableResult
    public static func linkMovedApps(_ library: [InstalledGame]) -> [String] {
        let fm = FileManager.default
        let standard = NokPaths.gameAppsFolder.standardizedFileURL.resolvingSymlinksInPath()
        guard GameFolders.isAvailable(NokPaths.gameAppsFolder) else { return [] }
        var linked: [String] = []
        for g in library where g.native == nil {
            let real = g.appURL.resolvingSymlinksInPath()
            guard real.deletingLastPathComponent().resolvingSymlinksInPath() != standard,
                  GameFolders.all.contains(where: { $0.resolvingSymlinksInPath() == real.deletingLastPathComponent().resolvingSymlinksInPath() }) else { continue }
            let anchor = anchor(for: g)
            guard !fm.fileExists(atPath: anchor.path), (try? fm.destinationOfSymbolicLink(atPath: anchor.path)) == nil else { continue }
            if (try? fm.createSymbolicLink(at: anchor, withDestinationURL: real)) != nil { linked.append(g.name) }
        }
        return linked
    }

    // MARK: Verified copies

    /// Copies a folder to `dest` (through a hidden partial name), reports progress, and checks every file
    /// arrived with the right size before it counts as done. `replacingLink`: a link at `dest` that the finished
    /// copy replaces.
    static func copyVerified(_ source: URL, to dest: URL, replacingLink: URL? = nil, plain: Bool = false,
                             progress: @escaping @Sendable (String) -> Void) throws {
        let fm = FileManager.default
        let total = Storage.allocatedSize(source)
        let partial = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).nokcandu-moving")
        let need = ResumableCopy.remaining(source: source, partial: partial, total: total)
        if let free = GameFolders.freeSpace(dest.deletingLastPathComponent()), free < need + 300_000_000 {
            throw NokError("Not enough space on \(GameFolders.volumeName(dest.deletingLastPathComponent())): this needs \(Storage.format(need)), \(Storage.format(free)) is free.")
        }
        let done = Locked(false)
        progress(need < total ? "Continuing an earlier copy (\(Storage.format(total - need)) already there)…" : "Copying \(Storage.format(total))…")
        let watcher = Thread {
            while !done.value {
                Thread.sleep(forTimeInterval: 3)
                if done.value { break }
                let copied = Storage.allocatedSize(partial)
                progress("Copying \(Storage.format(min(copied, total))) of \(Storage.format(total))…")
            }
        }
        watcher.start()
        defer { done.value = true }
        do { try ResumableCopy.copy(source, into: partial, total: total, plain: plain) }
        catch {
            done.value = true
            throw NokError("Copying stopped, so nothing was moved (the original is untouched). Moving to the same place again continues the copy. \(error.localizedDescription)")
        }
        done.value = true
        if plain { try removeCopiedMacMetadata(in: partial) }
        progress("Checking the copy…")
        if compare(source, partial) != nil {
            // Fix whatever differs (a file changed while copying, or one cut off), then check again.
            try? ResumableCopy.copyMissing(source, into: partial, plain: plain)
            if let problem = compare(source, partial) {
                try? ResumableCopy.discard(.init(source: source.path, partial: partial.path, total: total, started: Date()))
                throw NokError("The copy didn't match the original (\(problem)), so nothing was moved. The original is untouched.")
            }
        }
        if let link = replacingLink {
            let aside = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).nokcandu-link")
            try? fm.removeItem(at: aside)
            try fm.moveItem(at: link, to: aside)
            do { try fm.moveItem(at: partial, to: dest) }
            catch { try? fm.moveItem(at: aside, to: link); throw error }
            try? fm.removeItem(at: aside)
        } else {
            try fm.moveItem(at: partial, to: dest)
        }
        ResumableCopy.finished(partial: partial)
    }

    /// Nil when every regular file in `a` exists in `b` with the same size (links compared by target).
    static func compare(_ a: URL, _ b: URL) -> String? {
        // Relative paths straight from the enumerator: URL paths can differ in a /private prefix.
        func inventory(_ root: URL) -> [String: Int64] {
            var out: [String: Int64] = [:]
            guard let e = FileManager.default.enumerator(atPath: root.path) else { return out }
            while let rel = e.nextObject() as? String {
                let name = (rel as NSString).lastPathComponent
                if name == ".DS_Store" || name.hasPrefix("._") { continue }
                var st = stat()
                guard lstat(root.appendingPathComponent(rel).path, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFLNK: out[rel] = -1
                case S_IFREG: out[rel] = Int64(st.st_size)
                default: break
                }
            }
            return out
        }
        let x = inventory(a), y = inventory(b)
        for (path, size) in x {
            guard let other = y[path] else { return "missing \(path)" }
            if size >= 0, other != size { return "\(path) differs" }
        }
        return nil
    }
}

extension GameLibrary {
    /// Launchers moved to another drive leave a link in their library folder. When that drive isn't connected
    /// the link leads nowhere: (app name, drive) for each, to show them as offline.
    public static func offlineLinkedApps(folders: [URL] = GameFolders.all) -> [(name: String, drive: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for folder in folders where GameFolders.isAvailable(folder) {
            for item in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where item.hasSuffix(".app") {
                let path = folder.appendingPathComponent(item).path
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: path), !fm.fileExists(atPath: path) else { continue }
                let parts = URL(fileURLWithPath: dest).pathComponents
                out.append(((item as NSString).deletingPathExtension, dest.hasPrefix("/Volumes/") && parts.count > 2 ? parts[2] : "its drive"))
            }
        }
        return out
    }
}
