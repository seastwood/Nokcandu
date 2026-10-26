import SwiftUI
import AppKit
import NokcanduCore

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [InstalledGame] = []
    @Published var selection: InstalledGame.ID?
    @Published var runStates: [InstalledGame.ID: RunState] = [:]
    @Published var banner: Banner?
    @Published var showInstaller = false
    @Published var showSteamLibrary = false
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

    init() {
        SharedSteam.refreshHostScriptsIfNeeded()
        refresh()
        if Updates.isStale { Task { await checkForUpdates(quiet: true) } }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunStates() }
        }
    }

    var selectedGame: InstalledGame? { games.first { $0.id == selection } }

    func refresh() {
        games = GameLibrary.scan()
        for g in games { AppPrivacy.ensure(g.appURL) }
        CustomGames.upgradeLaunchers(games)
        let snapshot = games
        Task.detached(priority: .utility) { RawMouse.refreshLibraries(snapshot); BattleNet.refreshLaunchers(snapshot); BattleNet.refreshSteamLaunchers(snapshot); AudioBuffer.fixMicrophones(snapshot) }
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
        var s: [InstalledGame.ID: RunState] = [:]
        for g in games { s[g.id] = GameLauncher.runState(of: g) }
        if s != runStates {
            runStates = s
            // Something just started or stopped: if Steam is closed now, bring its helper up to date
            // (it can only be replaced while Steam isn't running).
            SharedSteam.refreshHostScriptsIfNeeded()
        }
    }

    func play(_ g: InstalledGame) {
        say("Starting \(g.name)…")
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                if DisplayController.supports(g) { DisplayController.prepareForLaunch(g) }
                GameDataSpec.forGame(g)?.snapshot()     // keep a copy of settings that live outside the app
                return Result { try GameLauncher.launch(g) }
            }.value
            if case .failure(let e) = r { fail(e) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refreshRunStates()
        }
    }

    /// battlenet:// / blizzard:// links from the browser (e.g. after a passkey sign-in) go back to Battle.net in Wine.
    func openURL(_ url: URL) {
        // nokcandu://profile/123 from the profiles website
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
