import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [InstalledGame] = [] { didSet { reorganize() } }
    @Published var libraryRevision = 0
    /// Sidebar lists, rebuilt when the library or its order changes.
    @Published var favoriteGames: [InstalledGame] = []
    @Published var sortedGames: [InstalledGame] = []
    @Published var launcherApps: [InstalledGame] = []
    /// Games on a drive that isn't plugged in: whole apps (not listed otherwise) and games whose files are there.
    @Published var offlineApps: [(name: String, drive: String)] = []
    @Published var missingDrive: [InstalledGame.ID: String] = [:]
    /// Subtitles you set for games.
    @Published var subtitles: [InstalledGame.ID: String] = [:]
    /// The game being renamed (shows the rename sheet).
    @Published var renaming: InstalledGame?
    @Published var sortMode: LibraryOrganizer.Sort = LibraryOrganizer.sort
    /// Games being moved to another folder right now.
    @Published var moving: Set<InstalledGame.ID> = []
    @Published var selection: InstalledGame.ID?
    @Published var runStates: [InstalledGame.ID: RunState] = [:]
    /// Game waiting for Quit to be confirmed.
    @Published var quitting: InstalledGame?
    @Published var banner: Banner?
    @Published var showInstaller = false
    @Published var showSteamLibrary = false
    @Published var showStores = false
    /// A launcher to set up the next time the installer opens (nil kind = Battle.net).
    @Published var pendingLauncherSetup: PCLauncher?? = nil
    /// A store game to install the next time the installer opens: (name, installer inputs).
    @Published var pendingStoreInstall: (name: String, inputs: [String: String], folder: URL)?
    /// Next time the installer opens, go straight to setting up the shared Steam.
    @Published var installerStartsSteamHost = false
    /// Mac versions downloading from a store right now (job id → latest status), and ones that stopped
    /// before finishing (saved on disk, so they survive a restart).
    @Published var storeDownloads: [String: StoreDownload] = [:]
    @Published var interruptedDownloads: [StoreJob] = []
    struct StoreDownload: Equatable { var line: String; var progress: StoreTools.Progress? }
    @Published var showUpdates = false
    @Published var showReport = false
    @Published var showStorage = false
    @Published var showProfiles = false
    @Published var profileFocus: Int?
    @Published var showWelcome = Setup.needsAttention
    /// A newer Nokcandu on GitHub Releases, if any.
    @Published var appUpdate: AppUpdate.Release?
    /// What's available upstream (Wine engine, wrapper template, LAV Filters); refreshed daily.
    @Published var catalog: UpdateCatalog? = Updates.cached()

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    private var timer: Timer?
    private var maintainedPaths: Set<String> = []
    private var lastMaintenance = Date.distantPast

    init() {
        SharedSteam.refreshHostScriptsIfNeeded()
        refresh()
        interruptedDownloads = StoreJobs.all()
        if let j = interruptedDownloads.first {
            let more = interruptedDownloads.count > 1 ? " (and \(interruptedDownloads.count - 1) more)" : ""
            say("\(j.game.title)'s download didn't finish\(more). Resume it in Game Stores.")
        }
        if Updates.isStale { Task { await checkForUpdates(quiet: true) } }
        Task.detached(priority: .utility) { await AntiCheat.refreshIfStale() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunStates() }
        }
        // A drive plugged in or out: games on it become playable or show "Connect … to play" right away.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    var selectedGame: InstalledGame? { games.first { $0.id == selection } }

    func refresh() {
        libraryRevision += 1
        games = GameLibrary.scan()
        GameFolders.remember(games)
        for g in games { AppPrivacy.ensure(g.appURL) }
        CustomGames.upgradeLaunchers(games)
        let snapshot = games
        // Bring helper files inside the game apps up to date — at startup, when games are added or moved,
        // and otherwise at most every 10 minutes (it hashes and rewrites files, so not on every refresh).
        let paths = Set(games.map(\.appURL.path))
        guard paths != maintainedPaths || Date().timeIntervalSince(lastMaintenance) > 600 else {
            if selection == nil || !games.contains(where: { $0.id == selection }) { selection = LibraryOrganizer.mostRecentlyPlayed(games)?.id }
            refreshRunStates()
            return
        }
        maintainedPaths = paths; lastMaintenance = Date()
        Task.detached(priority: .utility) {
            // Icons first: the rest can be slow when a game drive is slow to answer.
            if StoreAccounts.refreshIcons(snapshot) { await MainActor.run { self.games = GameLibrary.scan() } }
            HotCorners.recoverIfStale()
            let migratedLaunchers = HelperPatch.refresh(snapshot)
            RawMouse.refreshLibraries(snapshot); Performance.refreshEnvFiles(snapshot); BattleNet.refreshLaunchers(snapshot); PCLaunchers.refreshLaunchers(snapshot); BattleNet.refreshSteamLaunchers(snapshot); AudioBuffer.fixMicrophones(snapshot)
            if !migratedLaunchers.isEmpty {
                // Migration updates saved launcher hashes; replace the old in-memory configs too.
                let refreshed = GameLibrary.scan()
                await MainActor.run { self.games = refreshed; self.refreshRunStates() }
            }
        }
        if selection == nil || !games.contains(where: { $0.id == selection }) { selection = LibraryOrganizer.mostRecentlyPlayed(games)?.id }
        refreshRunStates()
    }

    private var settingHosts = Set<String>()
    /// One restart/confirmation flow for private games and shared Steam/Battle.net/EA environments.
    func changeSetting(for game: InstalledGame, title: String, success: String = "Settings applied.",
                       edit: @escaping (InstalledGame) async throws -> Void,
                       completion: @escaping (Bool) -> Void = { _ in }) {
        let contents = WineTools.hostContents(for: game)
        let host = contents.flatMap { GameLibrary.inspect($0.deletingLastPathComponent()) }
        let key = host?.id ?? game.id
        guard settingHosts.insert(key).inserted else { fail(NokError("Another setting is still being applied in this Windows environment.")); completion(false); return }
        Task {
            var applied = false
            defer { settingHosts.remove(key); completion(applied) }
            let running = contents != nil ? await WineTools.environmentIsRunning(for: game) : false
            if running {
                let name = host?.name ?? game.name
                let alert = NSAlert()
                alert.messageText = "Restart \(name) to apply \(title.lowercased())?"
                alert.informativeText = "Nokcandu will fully close all Windows programs in this environment, including its running games. Unsaved progress will be lost. It will apply the setting while everything is closed, then reopen \(name)."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Apply and Restart")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                say("Closing \(name) and its Windows programs…")
            }
            do {
                try await WineTools.applySettings(for: game, restart: running, edit: edit)
                applied = true
                refresh()
                say(running ? "\(host?.name ?? game.name) restarted. \(success)" : success)
            } catch { fail(error) }
        }
    }

    func checkForUpdates(quiet: Bool = false) async {
        if let r = try? await AppUpdate.check() { appUpdate = r }
        do {
            catalog = try await Updates.check()
            if !quiet { say(updateCount == 0 ? "Everything is up to date." : "\(updateCount) update\(updateCount == 1 ? "" : "s") available.") }
        } catch { if !quiet { fail(error) } }
    }

    /// Apps whose engine is older than the newest available, plus LAV installs older than the latest.
    var updateCount: Int {
        var n = appUpdate == nil ? 0 : 1
        guard let cat = catalog else { return n }
        if let latest = cat.latestEngine?.version,
           !EngineSelfTests.failed(RuntimeManager.runtimeID(engine: latest, template: cat.latestTemplate?.version ?? .tested)) {
            n += EngineUpdate.hosts(in: games).filter { g in EngineUpdate.current(g).map { $0 < latest } ?? false }.count
        }
        if let lav = cat.lav {
            n += EngineUpdate.hosts(in: games).filter { g in CinematicFix.state(for: g).map { $0.version != lav.version } ?? false }.count
        }
        return n
    }

    func refreshRunStates() {
        HotCorners.recoverIfStale()        // a game that switched hot corners off may have crashed
        var s: [InstalledGame.ID: RunState] = [:]
        for g in games {
            if g.native != nil {
                // Mac games: running if macOS lists the app as running.
                let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == g.appURL.standardizedFileURL }
                s[g.id] = running.map { .launcherRunning(pid: $0.processIdentifier) } ?? .notRunning
            } else {
                s[g.id] = GameLauncher.runState(of: g)
            }
        }
        if s != runStates {
            runStates = s
            // Something just started or stopped: if Steam is closed now, bring its helper up to date
            // (it can only be replaced while Steam isn't running).
            SharedSteam.refreshHostScriptsIfNeeded()
        }
    }

    func isRunning(_ g: InstalledGame) -> Bool {
        if case .launcherRunning = runStates[g.id] ?? .notRunning { return true }
        return false
    }

    /// After the user confirmed: quits the game or launcher.
    func quit(_ g: InstalledGame) {
        say("Quitting \(g.name)…")
        Task {
            if g.native != nil {
                for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == g.appURL.standardizedFileURL { app.terminate() }
            } else {
                do { try await GameLauncher.quit(g) } catch { fail(error) }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            refreshRunStates()
        }
    }

    func play(_ g: InstalledGame) {
        if let m = GameMover.missingDrive(g) { fail(NokError(m)); return }
        say("Starting \(g.name)…")
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                // A copy of this game left over from an earlier run (no window) blocks the launcher from starting it.
                let stuck = StuckGames.stuck(g)
                if StuckGames.end(stuck) > 0 {
                    await MainActor.run { self.say("\(g.name) was still running from before without a window — closed it and starting fresh.") }
                }
                if DisplayController.supports(g) { DisplayController.prepareForLaunch(g) }
                LibraryOrganizer.notePlayed(g)
                GameDataSpec.forGame(g)?.snapshot()     // keep a copy of settings that live outside the app
                // Mac versions from Epic need Epic's sign-in details, or they close right after their first screen.
                var args: [String] = []
                if let link = g.native?.store, link.store == .epic {
                    do { args = try await StoreAccounts.launchArguments(link) }
                    catch { await MainActor.run { self.say("Starting without Epic sign-in — \(error.localizedDescription). Online features may not work.") } }
                }
                let launchArgs = args
                return Result { try GameLauncher.launch(g, arguments: launchArgs) }
            }.value
            if case .failure(let e) = r { fail(e) }
            if sortMode == .recent { reorganize() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refreshRunStates()
        }
    }

    /// battlenet:// / blizzard:// links from the browser (e.g. after a passkey sign-in) go back to Battle.net in Wine.
    func openURL(_ url: URL) {
        // nokcandu://profile/123 from the profiles website
        if url.scheme == "nokcandu", url.host == "stores" { openStores(); return }
        if url.scheme == "nokcandu" {
            if url.host == "profile", let n = Int(url.lastPathComponent) { profileFocus = n } else { profileFocus = nil }
            showProfiles = true
            return
        }
        guard BattleNetBridge.canHandle(url) else { return }
        do {
            let host = try BattleNetBridge.forward(url, games: games.isEmpty ? GameLibrary.scan() : games)
            say("Passed the Battle.net sign-in back to \(host.name).")
        } catch { fail(error) }
    }

    // MARK: Library organization

    /// Which games' drives are unplugged (reads launcher records, so off the main thread).
    func refreshDrives() {
        let list = games
        Task {
            let missing = await Task.detached(priority: .utility) {
                Dictionary(list.compactMap { g in GameMover.offlineDrive(g).map { (g.id, $0) } }, uniquingKeysWith: { a, _ in a })
            }.value
            if missing != missingDrive { missingDrive = missing }
        }
    }

    func reorganize() {
        let launchers = games.filter(LibraryOrganizer.isLauncher)
        let rest = games.filter { !LibraryOrganizer.isLauncher($0) }
        let keys = LibraryOrganizer.favoriteKeys
        let favs = rest.filter { keys.contains(LibraryOrganizer.key($0)) }
        favoriteGames = LibraryOrganizer.sorted(favs)
        sortedGames = LibraryOrganizer.sorted(rest.filter { !favs.contains($0) })
        launcherApps = launchers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        offlineApps = GameFolders.offlineGames() + NativeGames.missing()
        refreshDrives()
        subtitles = Dictionary(games.compactMap { g in LibraryOrganizer.subtitle(g).map { (g.id, $0) } }, uniquingKeysWith: { a, _ in a })
        sortMode = LibraryOrganizer.sort
    }

    func setSort(_ s: LibraryOrganizer.Sort) { LibraryOrganizer.setSort(s); reorganize() }
    func setFavorite(_ g: InstalledGame, _ on: Bool) { LibraryOrganizer.setFavorite(g, on); reorganize() }
    func moveGames(from: IndexSet, to: Int) {
        var list = sortedGames
        list.move(fromOffsets: from, toOffset: to)
        LibraryOrganizer.setOrder(list)
        reorganize()
    }

    /// Moves a game app to another library folder (copying it when that's another drive).
    func move(_ g: InstalledGame, to folder: URL) {
        if !GameFolders.holdsApps(folder) { moveFiles(g, to: folder); return }
        if let b = GameMover.blocker(g) { fail(NokError(b)); return }
        moving.insert(g.id)
        say("Moving \(g.name) to \(GameFolders.volumeName(folder))… You can keep using Nokcandu.")
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try GameMover.move(g, to: folder) } }.value
            moving.remove(g.id)
            switch r {
            case .success(let newURL):
                refresh()
                selection = newURL.path
                say("\(g.name) is now in \(GameFolderLabel.text(folder)).")
            case .failure(let e): fail(e); refresh()
            }
        }
    }

    /// Moves only the game's files (to any drive, ExFAT included); nil brings them back to this Mac.
    func moveFiles(_ g: InstalledGame, to folder: URL?) {
        if let b = GameMover.filesBlocker(g) { fail(NokError(b)); return }
        moving.insert(g.id)
        say(folder.map { "Moving \(g.name)'s files to \(GameFolders.volumeName($0))… You can keep using Nokcandu." }
            ?? "Bringing \(g.name)'s files back to this Mac…")
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try GameMover.moveFiles(g, to: folder) } }.value
            moving.remove(g.id)
            switch r {
            case .success(let dest):
                say(folder == nil ? "\(g.name)'s files are back on this Mac." : "\(g.name)'s files are now on \(GameFolders.volumeName(dest)). The app stays here; keep the drive connected to play.")
            case .failure(let e): fail(e)
            }
            refresh()
        }
    }

    func moveToChosenFolder(_ g: InstalledGame) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose where to keep \(g.name). Picking a whole drive makes a “Nokcandu Games” folder on it."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        do { move(g, to: try GameFolders.add(picked)) } catch { fail(error) }
    }

    /// Re-presents the store sheet even if a previous presentation left the flag set.
    func openStores() {
        showStores = false
        DispatchQueue.main.async { self.showStores = true }
    }

    /// Adds a Mac app (OpenMW, a Mac game you installed yourself…) to the library.
    func addMacGame() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add to Nokcandu"
        panel.message = "Choose a Mac game app. Nokcandu just opens it — the app isn't changed or moved."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do {
            let n = try NativeGames.add(u)
            refresh()
            selection = URL(fileURLWithPath: n.appPath).path
            say("Added \(n.name).")
        } catch { fail(error) }
    }

    /// Opens the installer and starts setting up a launcher (nil = Battle.net).
    func setUpLauncher(kind: PCLauncher?) {
        pendingLauncherSetup = .some(kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showInstaller = true }
    }

    /// Download a store game's Mac version (or pick up one that stopped) — runs here, not in the store
    /// window, so closing the window doesn't lose it, and is saved so a restart can resume it.
    func installMac(_ g: StoreGame, into folder: URL) {
        let job = StoreJob(game: g, folder: folder)
        guard storeDownloads[job.id] == nil else { return }
        StoreJobs.add(job)
        interruptedDownloads.removeAll { $0.id == job.id }
        storeDownloads[job.id] = StoreDownload(line: "Starting download…", progress: nil)
        let id = job.id
        Task {
            do {
                let n = try await NativeGames.installFromStore(g, into: folder, log: { line in
                    Task { @MainActor in self.storeDownloads[id]?.line = line.trimmingCharacters(in: .whitespaces) }
                }, progress: { p in
                    Task { @MainActor in self.storeDownloads[id]?.progress = p }
                })
                StoreJobs.remove(id)
                storeDownloads[id] = nil
                refresh()
                say("\(n.name) (Mac version) is ready to play.")
            } catch {
                storeDownloads[id] = nil
                interruptedDownloads = StoreJobs.all()
                banner = Banner(text: "\(g.title): \(error.localizedDescription)", isError: true)
            }
        }
    }

    func resumeDownload(_ j: StoreJob) { installMac(j.game, into: j.folder) }

    func discardDownload(_ j: StoreJob) {
        StoreJobs.discard(j)
        interruptedDownloads = StoreJobs.all()
        say("Stopped \(j.game.title)'s download and moved its files to the Trash.")
    }

    func say(_ text: String) { banner = Banner(text: text, isError: false) }
    func fail(_ error: Error) { banner = Banner(text: error.localizedDescription, isError: true) }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

extension InstalledGame {
    var icon: NSImage {
        if let u = iconURL, let img = NSImage(contentsOf: u) { return img }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}
