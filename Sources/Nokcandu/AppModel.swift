import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [InstalledGame] = [] { didSet { reorganize(); recountUpdates() } }
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
    /// Progress of each move ("Copying 1.2 GB of 4.5 GB…").
    @Published var moveStatus: [InstalledGame.ID: String] = [:]
    /// The game whose Move sheet is open.
    @Published var movingGame: InstalledGame?
    /// The Move sheet was opened to fix ExFAT waste: preselect "inside the app" for the game's files.
    var moveSuggestsFilesWithApp: InstalledGame.ID?
    @Published var selection: InstalledGame.ID?
    @Published var helperActivation: [InstalledGame.ID: HelperActivation] = [:]
    @Published var statusUnavailable = false
    @Published var runStates: [InstalledGame.ID: RunState] = [:]
    @Published var pendingActivities: [InstalledGame.ID: PendingSettings.Activity] = [:]
    /// Game waiting for Quit to be confirmed.
    @Published var quitting: InstalledGame?
    @Published var banner: Banner?
    @Published var activity: [Activity] = []
    @Published var unseenErrors = 0
    /// What a game that is starting is doing ("Starting Windows…"), shown under Play.
    @Published var launchStages: [String: String] = [:]
    /// Games whose store client opened but didn't start them (cleared on the next Play or when the game runs).
    @Published var launchProblems: [String: String] = [:]
    @Published var showWhatsNew = false
    @Published var librarySearch = ""
    @Published var focusSearch = false
    @Published var libraryFilter: LibraryFilter = .all
    /// Which drive each game's app is on (filled with the library scan).
    @Published var gameDrives: [String: String] = [:]
    /// The app owns the session so closing its window cannot discard a running task.
    let installer = InstallerModel()
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
    /// GOG/Epic games with a newer version (game id → versions), and updates running now.
    @Published var storeUpdates: [String: StoreUpdates.Available] = StoreUpdates.cached()?.value ?? [:]
    @Published var updating: [String: StoreDownload] = [:]
    struct StoreDownload: Equatable { var line: String; var progress: StoreTools.Progress? }
    @Published var showUpdates = false
    @Published var showReport = false
    @Published var showStorage = false
    @Published var showProfiles = false
    @Published var profileFocus: Int?
    @Published var showWelcome = Setup.needsAttention
    /// A newer Nokcandu on GitHub Releases, if any.
    @Published var appUpdate: AppUpdate.Release? { didSet { recountUpdates() } }
    /// What's available upstream (Wine engine, wrapper template, LAV Filters); refreshed daily.
    @Published var catalog: UpdateCatalog? = Updates.cached() { didSet { recountUpdates() } }

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    private var timer: Timer?
    private let pendingMonitor = PendingSettingsMonitor()
    private var checkingPending = false
    private var maintainedPaths: Set<String> = []
    private var lastMaintenance = Date.distantPast
    private var lastHousekeeping = Date.distantPast
    private var discoveringStoreGames = false
    private var lastStoreDiscovery = Date.distantPast
    private var lastStoreDiscoveryErrors: [String] = []

    init() {
        SharedSteam.refreshHostScriptsIfNeeded()
        Notifier.shared.start { [weak self] id in self?.selection = id }
        showWhatsNew = !showWelcome && WhatsNew.shouldShow()
        refresh()
        installer.onLibraryReady = { [weak self] in self?.refresh() }
        interruptedDownloads = StoreJobs.all()
        if Date().timeIntervalSince(StoreUpdates.cached()?.saved ?? .distantPast) > 6 * 3600 {
            Task { await checkStoreUpdates() }
        }
        if let j = interruptedDownloads.first {
            let more = interruptedDownloads.count > 1 ? " (and \(interruptedDownloads.count - 1) more)" : ""
            say("\(j.game.title)'s download didn't finish\(more). Resume it in Game Stores.")
        }
        let replacementFailure = AppRollback.root.appendingPathComponent("last-failure.txt")
        if let text = try? String(contentsOf: replacementFailure, encoding: .utf8) {
            fail(NokError("Nokcandu version change: " + text))
            try? FileManager.default.removeItem(at: replacementFailure)
        }
        if Updates.isStale { Task { await checkForUpdates(quiet: true) } }
        Task.detached(priority: .utility) { await AntiCheat.refreshIfStale() }
        scheduleStatusTimer()
        // A drive plugged in or out: games on it become playable or show "Connect … to play" right away.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                Task { @MainActor in
                    self?.refresh()
                    // A drive holding a games volume was connected: open the volume too.
                    if n.name == NSWorkspace.didMountNotification { Task.detached(priority: .utility) { GamesVolume.attachRegistered() } }
                }
            }
        }
        Task.detached(priority: .utility) { GamesVolume.attachRegistered() }
        // Games start and quit as Mac apps: notice right away instead of polling quickly.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.statusSoon() }
            }
        }
        // Check often only while someone is looking at Nokcandu; otherwise stay out of the way (a game may be playing).
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                Task { @MainActor in
                    self?.scheduleStatusTimer()
                    if n.name == NSApplication.didBecomeActiveNotification { self?.helperCheckNeeded = true; self?.refreshRunStates(); self?.refreshStoreGames() }
                }
            }
        }
    }

    /// Status checks: every 3 s while Nokcandu is in front, every 20 s in the background (every 30 s while
    /// a game plays, so the game gets the Mac). Starting and quitting apps are noticed immediately regardless.
    private var statusInterval: TimeInterval = 0
    private func scheduleStatusTimer() {
        let foreground = NSApp?.isActive == true && NSApp?.isHidden == false
        let interval: TimeInterval = foreground ? 3 : (runStates.values.contains { if case .launcherRunning = $0 { return true }; return false } ? 30 : 20)
        guard interval != statusInterval || timer == nil else { return }
        statusInterval = interval
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunStates()
                self?.refreshStoreGames()
            }
        }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var statusSoonPending = false
    /// Coalesces bursts of app launches (a game starts several helper apps) into one check.
    private func statusSoon() {
        guard !statusSoonPending else { return }
        statusSoonPending = true
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            statusSoonPending = false
            refreshRunStates()
        }
    }

    var selectedGame: InstalledGame? { games.first { $0.id == selection }.map(PendingSettings.preview) }

    private var scanningLibrary = false
    private var rescanRequested = false
    /// Re-reads the library. The scan runs off the main thread (a game drive that is asleep or slow must
    /// never freeze the window); calls that arrive meanwhile are merged into one more scan.
    func refresh() {
        libraryRevision += 1
        if scanningLibrary { rescanRequested = true; return }
        scanningLibrary = true
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { () -> ([InstalledGame], LibraryExtras) in
                let found = GameLibrary.scan()
                GameFolders.remember(found)
                return (found, LibraryExtras.load(found))
            }.value
            scanningLibrary = false
            if rescanRequested { rescanRequested = false; refresh(); return }
            libraryExtras = scanned.1
            if gameDrives != scanned.1.drives { gameDrives = scanned.1.drives }
            games = scanned.0
            // First run with an empty library: the welcome shows the ways to add games.
            if !libraryLoaded, games.isEmpty, !UserDefaults.standard.bool(forKey: "welcomeDone") { showWelcome = true }
            libraryLoaded = true
            didRefresh()
        }
    }
    @Published var libraryLoaded = false
    private var libraryExtras = LibraryExtras()

    private func didRefresh() {
        let snapshot = games
        refreshStoreGames(force: true)
        Task.detached(priority: .utility) { AutomaticDriveMappings.reconcile(games: snapshot) }
        // Bring helper files inside the game apps up to date — at startup, when games are added or moved,
        // and otherwise at most every 10 minutes (it hashes and rewrites files, so not on every refresh).
        let paths = Set(games.map(\.appURL.path))
        guard paths != maintainedPaths || Date().timeIntervalSince(lastMaintenance) > 600 else {
            if selection == nil || !games.contains(where: { $0.id == selection }) { selection = LibraryOrganizer.mostRecentlyPlayed(games)?.id }
            refreshRunStates()
            return
        }
        maintainedPaths = paths; lastMaintenance = Date()
        let movingNow = moving
        let housekeeping = Date().timeIntervalSince(lastHousekeeping) > 6 * 3600
        if housekeeping { lastHousekeeping = Date() }
        Task.detached(priority: .utility) {
            // Games being moved right now are left alone: writing into the old place would recreate it.
            let live = snapshot.filter { !movingNow.contains($0.id) }
            // Keep Nokcandu's records in step with where apps really are.
            let relinked = InstallRecords.reconcile(library: live)
            // Games moved to another drive by earlier versions get their place in Applications back.
            if !GameMover.linkMovedApps(live).isEmpty { await MainActor.run { self.refresh() } }
            // Disc games on an APFS games volume mount their discs through a folder on the Mac.
            for g in live where g.native == nil { Discs.prepareMountPoints(support: g.support) }
            let ghosts = GhostApps.clean(library: live)
            if relinked + ghosts > 0 { await MainActor.run { self.installer.saved = InstallerModel.unfinished() } }
            if housekeeping {
                LogRetention.prune(live)
                RestorePoints.pruneOld(library: live)
                // Crash reports for games started outside Nokcandu too (closed environments only, once each).
                var hosts = Set<String>()
                for g in live where g.native == nil {
                    guard let host = WineTools.hostContents(for: g), hosts.insert(host.resolvingSymlinksInPath().path).inserted else { continue }
                    CrashReports.ensureCapture(contents: host)
                }
                let kept = EngineUpdate.autoKeep(live)
                if !kept.isEmpty {
                    await MainActor.run { self.say("Kept the new engine for \(kept.joined(separator: ", ")) after a week of play and removed the old engine's copy. A restore point from before the change remains.") }
                }
            }
            for game in live { AppPrivacy.ensure(game.appURL) }
            let upgraded = CustomGames.upgradeLaunchers(live)
            // Icons first: the rest can be slow when a game drive is slow to answer.
            if StoreAccounts.refreshIcons(live) { await MainActor.run { self.games = GameLibrary.scan() } }
            HotCorners.recoverIfStale()
            let migratedLaunchers = HelperPatch.refresh(live)
            SystemIntegration.cleanLaunchServices(); Storage.cleanStaleWork(); KeyRemap.refresh(environments: KeyRemap.environments(live)); RawMouse.refreshLibraries(live); Performance.refreshEnvFiles(live); BattleNet.refreshLaunchers(live); PCLaunchers.refreshLaunchers(live); BattleNet.refreshSteamLaunchers(live); AudioBuffer.fixMicrophones(live); WindowedPresentation.refresh(live)
            // Helper files may have just been brought up to date: re-check what each app has installed.
            await MainActor.run { self.helpersMaintained = true; self.helperCheckNeeded = true; self.refreshRunStates() }
            if !migratedLaunchers.isEmpty || upgraded > 0 {
                // Migration updates saved launcher hashes; replace the old in-memory configs too.
                let refreshed = GameLibrary.scan()
                await MainActor.run { self.games = refreshed; self.refreshRunStates() }
            }
        }
        if selection == nil || !games.contains(where: { $0.id == selection }) { selection = LibraryOrganizer.mostRecentlyPlayed(games)?.id }
        refreshRunStates()
    }

    /// Installation readers and shortcut generation never block the library UI.
    private func refreshStoreGames(force: Bool = false) {
        // Finding newly installed store games reads every launcher's library (often on an external drive):
        // every 2 minutes while Nokcandu is in front, every 15 in the background; drive changes force it.
        let interval: TimeInterval = NSApp?.isActive == true ? 120 : 900
        guard !discoveringStoreGames, force || Date().timeIntervalSince(lastStoreDiscovery) >= interval else { return }
        discoveringStoreGames = true
        lastStoreDiscovery = Date()
        Task {
            let result = await Task.detached(priority: .utility) { StoreGameDiscovery.refresh() }.value
            // Keep the guard set through refresh(), which also requests discovery.
            if !result.added.isEmpty {
                await StorageInventory.shared.invalidate()
                refresh()
                let names = result.added.map { $0.deletingPathExtension().lastPathComponent }
                let text = names.count <= 3 ? "Added \(ListFormatter.localizedString(byJoining: names)) to your game list." : "Added \(names.count) installed store games to your game list."
                say(text, game: names.count == 1 ? result.added[0].path : nil)
                Notifier.post(title: names.count == 1 ? "\(names[0]) is ready to play" : "New games in Nokcandu", body: text, gameID: names.count == 1 ? result.added[0].path : nil)
            }
            if !result.errors.isEmpty, result.errors != lastStoreDiscoveryErrors {
                fail(NokError(result.errors.joined(separator: "\n")))
            }
            lastStoreDiscoveryErrors = result.errors
            discoveringStoreGames = false
        }
    }

    func changeMicrophone(_ on: Bool, for game: InstalledGame) {
        guard settingHosts.insert(game.id).inserted else { return }
        Task {
            defer { settingHosts.remove(game.id) }
            do {
                let fresh = try await Task.detached(priority: .userInitiated) {
                    let current = GameLibrary.inspect(game.appURL) ?? game
                    try GameMicrophone.set(on, for: current)
                    return GameLibrary.inspect(game.appURL) ?? current
                }.value
                if let index = games.firstIndex(where: { $0.id == fresh.id }) { games[index] = fresh }
                libraryRevision += 1
                refreshRunStates()
                say(on ? "Microphone on. First-time macOS permission may need one close/reopen; later changes work while playing." : "Microphone off.")
            } catch { fail(error) }
        }
    }

    private var settingHosts = Set<String>()
    /// Save desired changes immediately; never close or reopen a game to change a setting.
    func changeSetting(for game: InstalledGame, title: String, success: String = "Settings saved.",
                       change: PendingSettings.Change, completion: @escaping (Bool) -> Void = { _ in }) {
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    let current = GameLibrary.inspect(game.appURL) ?? game
                    try PendingSettings.save(change, title: title, for: current)
                    let outcome = try await PendingSettings.apply(for: current)
                    if outcome == .applied {
                        _ = try? PendingSettings.ensureHelper(for: current)
                        try? LauncherEntry.ensure(GameLibrary.inspect(current.appURL) ?? current)
                    }
                    return outcome
                }.value
                refresh()
                if outcome == .deferred {
                    let name = WineSelection.host(for: game, in: games)?.name ?? game.name
                    say("Saved \(title.lowercased()). It will apply automatically when \(name)'s Windows environment is idle.")
                } else { say(success) }
                completion(true)
            } catch {
                // A failed application retains its durable request for retry or discard.
                refresh(); fail(error); completion(false)
            }
        }
    }

    func checkForUpdates(quiet: Bool = false) async {
        if let r = try? await AppUpdate.check() { appUpdate = r }
        do {
            catalog = try await Updates.check()
            if !quiet {
                let n = await Task.detached(priority: .userInitiated) { [games, catalog, appUpdate] in AppModel.countUpdates(games: games, catalog: catalog, appUpdate: appUpdate) }.value
                say(n == 0 ? "Everything is up to date." : "\(n) update\(n == 1 ? "" : "s") available.")
            }
        } catch { if !quiet { fail(error) } }
    }

    /// Apps whose engine is older than the newest available, plus LAV installs older than the latest.
    /// Counted off the main thread (it reads each app's engine records) and kept for the views.
    @Published private(set) var updateCount = 0
    private var countingUpdates = false, recountRequested = false
    private func recountUpdates() {
        if countingUpdates { recountRequested = true; return }
        countingUpdates = true
        let games = games, catalog = catalog, app = appUpdate
        Task {
            let n = await Task.detached(priority: .utility) { AppModel.countUpdates(games: games, catalog: catalog, appUpdate: app) }.value
            countingUpdates = false
            if updateCount != n { updateCount = n }
            if recountRequested { recountRequested = false; recountUpdates() }
        }
    }
    nonisolated static func countUpdates(games: [InstalledGame], catalog: UpdateCatalog?, appUpdate: AppUpdate.Release?) -> Int {
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

    private var refreshingRunStates = false
    func refreshRunStates() {
        // A timer must not queue another scan behind a slow one. All filesystem,
        // process and LaunchServices queries stay off the main actor.
        guard !refreshingRunStates else { return }
        refreshingRunStates = true
        let snapshot = games, revision = libraryRevision
        // Which helper build each running session loaded only changes when something starts, stops or is
        // repaired: check it then, and otherwise once a minute.
        // A game that just started records its loaded helper a moment later: keep checking until it has.
        let unsettled = helperActivation.values.contains { $0 == .unknown || $0 == .restartRequired }
        let checkHelpers = helperCheckNeeded || unsettled || Date().timeIntervalSince(lastHelperCheck) > 60
        let previousHelpers = helperActivation
        Task {
            let states = await Task.detached(priority: .utility) {
                HotCorners.recoverIfStale()
                KeyRemap.recoverIfStale()
                var states = GameLauncher.runStates(of: snapshot)
                var heavy: [(InstalledGame, MemoryWatch.Session)] = []
                for game in snapshot where game.native == nil {
                    if case .launcherRunning = states[game.id] ?? .notRunning, let s = MemoryWatch.sample(game), MemoryWatch.isHeavy(s) { heavy.append((game, s)) }
                }
                // Crash reports are kept per environment (one stat each when nothing changed).
                for contents in Set(snapshot.compactMap { $0.native == nil ? WineTools.hostContents(for: $0) : nil }) { CrashReports.archive(contents: contents) }
                if snapshot.contains(where: { $0.native != nil }) {
                    let running = NSWorkspace.shared.runningApplications
                    let apps = running.compactMap { app -> (URL, Int32)? in
                        guard let url = app.bundleURL?.standardizedFileURL else { return nil }
                        return (url, app.processIdentifier)
                    }
                    for game in snapshot where game.native != nil {
                        states[game.id] = apps.first { $0.0 == game.appURL.standardizedFileURL }
                            .map { .launcherRunning(pid: $0.1) } ?? .notRunning
                    }
                }
                return (states, checkHelpers ? HelperActivation.statuses(for: snapshot) : previousHelpers, heavy)
            }.value
            for (game, session) in states.2 where memoryWarned.insert("\(game.id)#\(session.pid)").inserted {
                let text = "\(game.name) is using \(MemoryWatch.gigabytes(session.peak)) of this Mac's \(MemoryWatch.gigabytes(MemoryWatch.physicalMemory)) memory. Closing other apps helps; its page has more after you quit."
                say(text, game: game.id)
                Notifier.post(title: "\(game.name) is low on memory", body: text, gameID: game.id)
            }
            refreshingRunStates = false
            guard revision == libraryRevision else { helperCheckNeeded = true; refreshRunStates(); return }
            if checkHelpers { lastHelperCheck = Date(); helperCheckNeeded = false }
            // Until startup maintenance has brought helper files up to date, an "update needed" result is
            // usually just that pending work: don't flash a warning for it.
            let shown = helpersMaintained ? states.1 : states.1.mapValues { $0 == .updateRequired ? .ready : $0 }
            if helperActivation != shown { helperActivation = shown }
            let changed = applyRunStates(states.0)
            if changed { helperCheckNeeded = true; scheduleStatusTimer(); refreshStoreGames(force: true) }
            applyIdleSettings()
        }
    }
    private var memoryWarned = Set<String>()
    private var lastHelperCheck = Date.distantPast
    private var helperCheckNeeded = true
    private var helpersMaintained = false
    private var unknownStreak = 0

    func applyIdleSettings(retry: Bool = false) {
        guard !checkingPending else { return }
        checkingPending = true
        let snapshot = games, monitor = pendingMonitor
        Task {
            if retry { await monitor.retry() }
            let result = await Task.detached(priority: .utility) { await monitor.drain(snapshot) }.value
            checkingPending = false
            if pendingActivities != result.activities { pendingActivities = result.activities }
            if !result.applied.isEmpty {
                refresh()
                say("Applied saved settings for \(result.applied.joined(separator: ", ")).")
            }
            if !result.failures.isEmpty { refresh(); fail(NokError(result.failures.joined(separator: "\n"))) }
        }
    }

    @discardableResult
    private func applyRunStates(_ incoming: [InstalledGame.ID: RunState]) -> Bool {
        // A single overlapping process scan reports "unknown" (it never waits behind another scan): keep the last
        // known state through one such pass, and only say status is unavailable when it persists.
        let anyUnknown = incoming.values.contains(.unknown)
        unknownStreak = anyUnknown ? unknownStreak + 1 : 0
        let unavailable = unknownStreak >= 3
        if statusUnavailable != unavailable { statusUnavailable = unavailable }
        var s = incoming
        for (id, state) in incoming where state == .unknown {
            if case .launcherRunning = runStates[id] { s[id] = runStates[id] }
            else if !unavailable, let known = runStates[id], known != .unknown { s[id] = known }
        }
        if s != runStates {
            // A game with Epic cloud saves just quit: upload its newer saves.
            for g in games where CloudSaves.supported(g) != nil {
                if case .launcherRunning = runStates[g.id] ?? .notRunning, case .notRunning = s[g.id] ?? .notRunning {
                    Task.detached(priority: .utility) {
                        if await CloudSaves.sync(g) == .uploaded { await MainActor.run { self.say("Uploaded \(g.name)'s save to Epic's cloud.") } }
                    }
                }
            }
            for (id, state) in s { if case .launcherRunning = state, launchProblems[id] != nil { launchProblems.removeValue(forKey: id) } }
            runStates = s
            // Something just started or stopped: if Steam is closed now, bring its helper up to date
            // (it can only be replaced while Steam isn't running).
            Task.detached(priority: .utility) { SharedSteam.refreshHostScriptsIfNeeded() }
            return true
        }
        return false
    }

    func isRunning(_ g: InstalledGame) -> Bool {
        if case .launcherRunning = runStates[g.id] ?? .notRunning { return true }
        return false
    }

    /// After the user confirmed: quits the game or launcher.
    func quit(_ g: InstalledGame) {
        startupObservers.removeValue(forKey: g.id)
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
        launchProblems.removeValue(forKey: g.id)
        // Resizable window: each game has its own choice; a launcher running with another one restarts.
        Task {
            do {
                if PendingSettings.hasPending(for: g) {
                    _ = try await PendingSettings.apply(for: g, waitForApplication: true)
                    refresh()
                }
            } catch { fail(error); return }
            let g = GameLibrary.inspect(g.appURL) ?? g
            if let why = await WindowedPresentation.restartReason(for: g) {
                let alert = NSAlert()
                let host = WineTools.hostContents(for: g).flatMap { GameLibrary.inspect($0.deletingLastPathComponent()) }
                alert.messageText = "Restart \(host?.name ?? "the launcher") to play \(g.name)?"
                alert.informativeText = why + " Restarting closes everything running in it (unsaved progress in other games is lost) and starts \(g.name) with its setting."
                alert.addButton(withTitle: "Restart and Play")
                alert.addButton(withTitle: "Play Without Restarting")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    say("Restarting \(host?.name ?? "the launcher") for \(g.name)…")
                    do {
                        try await WineTools.stopAll(for: g)
                        try await WindowedPresentation.prepareForLaunch(g)
                    } catch { fail(error); return }
                    launch(g, extra: [])
                case .alertSecondButtonReturn: playChecked(g)
                default: break
                }
                return
            }
            playChecked(g)
        }
    }

    private func playChecked(_ g: InstalledGame) {
        // Steam games: if the running Steam has other settings, ask here (a dialog from the background
        // helper could open behind other windows, so it looked like nothing happened).
        if g.usesSharedSteam, let why = SharedSteam.restartReason(for: g) {
            let alert = NSAlert()
            alert.messageText = "Restart Steam to play \(g.name)?"
            let gameRunning = (try? Shell.run("/bin/ps", ["-axo", "command="], timeout: 5))?.stdout.range(of: #"steamapps[\\/]common"#, options: [.regularExpression, .caseInsensitive]) != nil
            alert.informativeText = why + " Restarting applies them." + (gameRunning ? " The Steam game that's running now will close." : "")
            alert.addButton(withTitle: "Restart Steam")
            alert.addButton(withTitle: "Play Without Restarting")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: launch(g, extra: ["--restart-steam"])
            case .alertSecondButtonReturn: launch(g, extra: ["--no-restart"])
            default: break
            }
            return
        }
        launch(g, extra: [])
    }

    private func launch(_ g: InstalledGame, extra: [String]) {
        say("Starting \(g.name)…")
        if g.native == nil { launchStages[g.id] = "Getting \(g.name) ready…" }
        ActivationHandoff.expect(g)
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do { try GameMicrophone.refreshPolicies(await MainActor.run { self.games }) }
                catch { return .failure(error) }
                // A copy of this game left over from an earlier run (no window) blocks the launcher from starting it.
                let stuck = StuckGames.stuck(g)
                if StuckGames.end(stuck) > 0 {
                    await MainActor.run { self.say("\(g.name) was still running from before without a window — closed it and starting fresh.") }
                }
                // A Steam game added before its download finished: pick its graphics mode now.
                if SharedSteam.refreshDetection(g) { await MainActor.run { self.refresh() } }
                if DisplayController.supports(g) { DisplayController.prepareForLaunch(g) }
                ProgramSettings.refresh(g, games: await MainActor.run { self.games })
                do { try await WindowedPresentation.prepareForLaunch(g) }
                catch {
                    // Never in the way of playing: the game starts on the Mac's screen, and says why.
                    let why = WindowedPresentation.unavailable(for: g) ?? error.localizedDescription
                    await MainActor.run { self.say("\(g.name) is playing on the Mac's screen: \(why)") }
                }
                // A mod started from the launch options that's missing a mod it builds on crashes while loading: say so first.
                if let mod = ModDependencies.launchedMod(arguments: g.custom?.arguments ?? ""),
                   let missing = ModDependencies.missing(g).first(where: { $0.mod.lowercased() == mod.lowercased() }) {
                    await MainActor.run { self.say(missing.message) }
                }
                await BonjourService.prepareForLaunch(g)
                await DiscordBridge.prepareForLaunch(g)
                LibraryOrganizer.notePlayed(g)
                GameDataSpec.forGame(g)?.snapshot()     // keep a copy of settings that live outside the app
                // Mac versions from Epic need Epic's sign-in details, or they close right after their first screen.
                var args: [String] = []
                if let link = g.native?.store, link.store == .epic {
                    do { args = try await StoreAccounts.launchArguments(link) }
                    catch { await MainActor.run { self.say("Starting without Epic sign-in — \(error.localizedDescription). Online features may not work.") } }
                }
                let launchArgs = args + extra
                // Epic cloud saves: get a newer save from the cloud before the game reads it.
                if CloudSaves.supported(g) != nil {
                    await MainActor.run { self.say("Checking \(g.name)'s cloud saves…") }
                    if await CloudSaves.sync(g) == .downloaded {
                        await MainActor.run { self.say("Downloaded \(g.name)'s newer cloud save. Starting…") }
                    }
                }
                let started = Date()
                do {
                    try GameLauncher.launch(g, arguments: launchArgs)
                    if g.native == nil { await MainActor.run { self.observeStartup(g, since: started) } }
                    return .success(())
                } catch { return .failure(error) }
            }.value
            if case .failure(let e) = r { fail(e); launchStages.removeValue(forKey: g.id) }
            if sortMode == .recent { reorganize() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refreshRunStates()
        }
    }

    private var startupObservers: [String: UUID] = [:]
    private func observeStartup(_ game: InstalledGame, since: Date) {
        let token = UUID(); startupObservers[game.id] = token
        Task {
            var warned = false
            defer { if startupObservers[game.id] == token { startupObservers.removeValue(forKey: game.id); launchStages.removeValue(forKey: game.id) } }
            while startupObservers[game.id] == token {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard startupObservers[game.id] == token else { return }
                let elapsed = Date().timeIntervalSince(since)
                let observation = await Task.detached(priority: .utility) {
                    StartupMonitor.observe(game, since: since, elapsed: elapsed)
                }.value
                let stage = await Task.detached(priority: .utility) { StartupMonitor.stage(game, since: since, elapsed: elapsed) }.value
                if case .opened = observation { launchStages.removeValue(forKey: game.id) }
                else if case .failed = observation { launchStages.removeValue(forKey: game.id) }
                else if launchStages[game.id] != stage { launchStages[game.id] = stage }
                switch observation {
                case .opened: return
                case .failed(let message): fail(NokError(message)); refreshRunStates(); return
                case .waiting(let message): if !warned { say(message); warned = true }
                case .stalled(let message):
                    launchProblems[game.id] = message
                    say(message, game: game.id)
                    Notifier.post(title: "\(game.name) hasn't started", body: message, gameID: game.id)
                    return
                case .pending: break
                }
            }
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
        offlineApps = libraryExtras.offline
        refreshDrives()
        subtitles = LibraryOrganizer.subtitles(for: games)
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
            await StorageInventory.shared.invalidate()
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
            await StorageInventory.shared.invalidate()
            switch r {
            case .success(let dest):
                say(folder == nil ? "\(g.name)'s files are back on this Mac." : "\(g.name)'s files are now on \(GameFolders.volumeName(dest)). The app and Wine runtime stay on this Mac; keep the drive connected to play.")
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
    func installMac(_ g: StoreGame, into folder: URL, includeDLC: Bool = false) {
        var job = StoreJob(game: g, folder: folder)
        job.includeDLC = includeDLC
        guard storeDownloads[job.id] == nil else { return }
        StoreJobs.add(job)
        interruptedDownloads.removeAll { $0.id == job.id }
        storeDownloads[job.id] = StoreDownload(line: "Starting download…", progress: nil)
        let id = job.id
        Task {
            do {
                let n = try await NativeGames.installFromStore(g, into: folder, includeDLC: includeDLC, log: { line in
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

    func checkStoreUpdates() async {
        let gs = games
        storeUpdates = await Task.detached(priority: .utility) { await StoreUpdates.check(gs) }.value
    }

    func updateGame(_ g: InstalledGame) {
        guard updating[g.id] == nil else { return }
        updating[g.id] = StoreDownload(line: "Starting update…", progress: nil)
        let id = g.id
        Task {
            do {
                try await StoreUpdates.update(g, log: { line in
                    Task { @MainActor in self.updating[id]?.line = line.trimmingCharacters(in: .whitespaces) }
                }, progress: { p in
                    Task { @MainActor in self.updating[id]?.progress = p }
                })
                updating[id] = nil
                storeUpdates[id] = nil
                refresh()
                say("\(g.name) is up to date.")
            } catch {
                updating[id] = nil
                banner = Banner(text: "\(g.name): \(error.localizedDescription)", isError: true)
            }
        }
    }

    func resumeDownload(_ j: StoreJob) { installMac(j.game, into: j.folder, includeDLC: j.includeDLC ?? false) }

    func discardDownload(_ j: StoreJob) {
        StoreJobs.discard(j)
        interruptedDownloads = StoreJobs.all()
        say("Stopped \(j.game.title)'s download and moved its files to the Trash.")
    }

    func say(_ text: String) { say(text, game: nil) }
    /// A message about one game: its line in Recent Activity gets a Show button.
    func say(_ text: String, game: String?) { banner = Banner(text: text, isError: false); remember(text, isError: false, game: game) }
    func fail(_ error: Error) { banner = Banner(text: error.localizedDescription, isError: true); remember(error.localizedDescription, isError: true) }

    // MARK: Recent activity (messages stay readable after their banner fades)

    struct Activity: Identifiable, Equatable {
        let id = UUID()
        var date = Date()
        var text: String
        var isError: Bool
        var game: String? = nil
    }
    private func remember(_ text: String, isError: Bool, game: String? = nil) {
        // Progress lines ("Starting X…") repeat a lot; keep only the newest of the same text.
        activity.removeAll { $0.text == text }
        activity.insert(Activity(text: text, isError: isError, game: game), at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
        if isError { unseenErrors += 1 }
    }

    // MARK: Quit

    /// Quit without the confirmation (Settings → General, or "Always Quit Without Asking").
    var quitWithoutAsking: Bool {
        get { UserDefaults.standard.bool(forKey: "quitWithoutAsking") }
        set { UserDefaults.standard.set(newValue, forKey: "quitWithoutAsking"); objectWillChange.send() }
    }
    /// Asks first, unless asking was turned off or nothing can be lost (a launcher with no game running in it).
    func requestQuit(_ g: InstalledGame) {
        if quitWithoutAsking || (LibraryOrganizer.isLauncher(g) && !gamesRunning(in: g)) { quit(g) } else { quitting = g }
    }
    func gamesRunning(in host: InstalledGame) -> Bool {
        let hostPath = host.appURL.resolvingSymlinksInPath().path
        return games.contains { g in
            g.id != host.id && isRunning(g) && WineTools.hostContents(for: g)?.deletingLastPathComponent().resolvingSymlinksInPath().path == hostPath
        }
    }

    // MARK: Library search and filters

    enum LibraryFilter: Hashable, Identifiable {
        case all, running, windows, mac, steam, battleNet, drive(String)
        var id: String { title }
        var title: String {
            switch self {
            case .all: "All Games"; case .running: "Running"; case .windows: "Windows Games"; case .mac: "Mac Games"
            case .steam: "Steam"; case .battleNet: "Battle.net"; case .drive(let d): "On \(d)"
            }
        }
    }
    func matchesLibrary(_ g: InstalledGame) -> Bool {
        let q = librarySearch.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, !g.name.localizedCaseInsensitiveContains(q), !(subtitles[g.id] ?? "").localizedCaseInsensitiveContains(q) { return false }
        switch libraryFilter {
        case .all: return true
        case .running: return isRunning(g)
        case .windows: return g.native == nil
        case .mac: return g.native != nil
        case .steam: return g.usesSharedSteam || g.isSteamHost
        case .battleNet: return g.battleNet != nil || BattleNet.isHost(g)
        case .drive(let d): return gameDrives[g.id] == d
        }
    }
    /// Drive names the library's games are stored on (for the filter menu).
    var driveFilters: [LibraryFilter] { Array(Set(gameDrives.values)).sorted().map { .drive($0) } }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

extension InstalledGame {
    var icon: NSImage {
        if let u = iconURL, let img = NSImage(contentsOf: u) { return img }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

/// Library details that need the file system, gathered with the scan off the main thread.
struct LibraryExtras {
    var offline: [(name: String, drive: String)] = []
    var drives: [String: String] = [:]
    static func load(_ games: [InstalledGame]) -> LibraryExtras {
        var seen = Set<String>()
        return LibraryExtras(offline: (GameLibrary.offlineLinkedApps() + GameFolders.offlineGames() + NativeGames.missing()).filter { seen.insert($0.name).inserted },
                             drives: Dictionary(games.map { ($0.id, Storage.driveName($0.appURL.resolvingSymlinksInPath())) }, uniquingKeysWith: { a, _ in a }))
    }
}
