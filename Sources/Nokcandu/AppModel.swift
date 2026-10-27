import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [InstalledGame] = [] { didSet { reorganize() } }
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
    @Published var showUpdates = false
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
        if Updates.isStale { Task { await checkForUpdates(quiet: true) } }
        Task.detached(priority: .utility) { await AntiCheat.refreshIfStale() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunStates() }
        }
    }

    var selectedGame: InstalledGame? { games.first { $0.id == selection } }

    func refresh() {
        games = GameLibrary.scan()
        GameFolders.remember(games)
        for g in games { AppPrivacy.ensure(g.appURL) }
        CustomGames.upgradeLaunchers(games)
        let snapshot = games
        // Bring helper files inside the game apps up to date — at startup, when games are added or moved,
        // and otherwise at most every 10 minutes (it hashes and rewrites files, so not on every refresh).
        let paths = Set(games.map(\.appURL.path))
        guard paths != maintainedPaths || Date().timeIntervalSince(lastMaintenance) > 600 else {
            if selection == nil || !games.contains(where: { $0.id == selection }) { selection = games.first?.id }
            refreshRunStates()
            return
        }
        maintainedPaths = paths; lastMaintenance = Date()
        Task.detached(priority: .utility) {
            // Icons first: the rest can be slow when a game drive is slow to answer.
            if StoreAccounts.refreshIcons(snapshot) { await MainActor.run { self.games = GameLibrary.scan() } }
            HotCorners.recoverIfStale(); HelperPatch.refresh(snapshot); RawMouse.refreshLibraries(snapshot); Performance.refreshEnvFiles(snapshot); BattleNet.refreshLaunchers(snapshot); PCLaunchers.refreshLaunchers(snapshot); BattleNet.refreshSteamLaunchers(snapshot); AudioBuffer.fixMicrophones(snapshot) 
        }
        if selection == nil || !games.contains(where: { $0.id == selection }) { selection = games.first?.id }
        refreshRunStates()
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
                return Result { try GameLauncher.launch(g) }
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

    func reorganize() {
        let launchers = games.filter(LibraryOrganizer.isLauncher)
        let rest = games.filter { !LibraryOrganizer.isLauncher($0) }
        let keys = LibraryOrganizer.favoriteKeys
        let favs = rest.filter { keys.contains(LibraryOrganizer.key($0)) }
        favoriteGames = LibraryOrganizer.sorted(favs)
        sortedGames = LibraryOrganizer.sorted(rest.filter { !favs.contains($0) })
        launcherApps = launchers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        offlineApps = GameFolders.offlineGames() + NativeGames.missing()
        var missing: [InstalledGame.ID: String] = [:]
        for g in games {
            if let ext = GameMover.externalFiles(g), !FileManager.default.fileExists(atPath: ext.path) {
                missing[g.id] = ext.path.hasPrefix("/Volumes/") && ext.pathComponents.count > 2 ? ext.pathComponents[2] : "its drive"
            }
        }
        missingDrive = missing
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
