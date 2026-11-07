import SwiftUI
import NokcanduCore

struct GameDetailView: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    @State private var display: DisplayStatus?
    @State private var checking = false
    @State private var checkResult: ShellResult?
    @State private var showDiagnostics = false
    @State private var showReport = false
    @State private var showSettingsBackups = false
    @State private var confirmReset = false
    @State private var busy = false
    @State private var confirmRepair = false
    @State private var repairing = false
    @State private var repairSteps: [RepairStep]?
    @State private var cinematicDiagnosis: CinematicFix.Diagnosis?
    @State private var graphicsHint: GraphicsHint?
    @State private var fixVersion = 0
    @State private var crash: CrashReports.Explanation?
    @State private var missingMods: [ModDependencies.Missing] = []
    @State private var showCrashReport = false
    @State private var memory: (session: MemoryWatch.Session, advice: MemoryWatch.Advice)?
    @State private var applyingLowMemory = false
    @State private var setup: GameSetups.Setup?
    @State private var applyingSetup = false
    @State private var crashPattern: String?
    @State private var folderChanges: OriginalFiles.Changes?
    @State private var showDoctor = false
    @State private var confirmResetAll = false
    var crashDismissedKey: String { "crashDismissed." + game.id }
    var memoryDismissedKey: String { "memoryDismissed." + game.id }

    func loadNotices() async {
        guard game.native == nil, !running else { return }
        let g = game
        let dismissed = UserDefaults.standard.double(forKey: crashDismissedKey)
        let since = dismissed > 0 ? Date(timeIntervalSince1970: dismissed + 1) : nil
        let memoryDismissed = UserDefaults.standard.double(forKey: memoryDismissedKey)
        let (c, m, mem, su, pattern) = await Task.detached(priority: .utility) {
            (CrashReports.lastCrash(g, since: since), ModDependencies.missing(g),
             MemoryWatch.last(g).flatMap { s in MemoryWatch.advice(g, session: s).map { (s, $0) } },
             GameSetups.pending(g), CrashReports.pattern(CrashReports.history(g)))
        }.value
        crash = c; missingMods = m; setup = su; crashPattern = pattern
        folderChanges = await Task.detached(priority: .utility) { OriginalFiles.isProtected(g) ? OriginalFiles.lastChanges(g) : nil }.value
        memory = mem.flatMap { $0.0.started.timeIntervalSince1970 > memoryDismissed ? (session: $0.0, advice: $0.1) : nil }
    }

    /// Everything on this page that needs attention, most important first.
    var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        if let problem = model.launchProblems[game.id], !running {
            items.append(AttentionItem(id: "stalled", view: AnyView(
                NoticeCard(symbol: "hourglass", tint: .orange, title: "\(game.name) hasn't started", detail: problem + " If nothing is waiting there, try again.") {
                    Button("Try Again") { model.play(game) }.buttonStyle(.borderedProminent)
                    if let host = launcherHost { Button("Show \(StartupMonitor.storeName(game))") { model.selection = host.id } }
                    Button("Dismiss") { model.launchProblems.removeValue(forKey: game.id) }.buttonStyle(.link)
                })))
        }
        if let c = crash {
            items.append(AttentionItem(id: "crash", view: AnyView(
                NoticeCard(symbol: c.missingMod != nil ? "puzzlepiece.extension" : "exclamationmark.octagon", tint: .red, title: c.title, detail: c.detail,
                           evidence: c.evidence + " · " + c.date.formatted(date: .abbreviated, time: .shortened) + (crashPattern.map { " · " + $0 } ?? "")) {
                    Button("Show Report") { showCrashReport = true }
                    Button("Dismiss") { UserDefaults.standard.set(c.date.timeIntervalSince1970, forKey: crashDismissedKey); crash = nil }
                }
                .sheet(isPresented: $showCrashReport) { CrashReportSheet(game: game, crash: c) })))
        }
        for m in missingMods where crash?.missingMod != m {
            items.append(AttentionItem(id: "mod-" + m.mod, view: AnyView(
                NoticeCard(symbol: "puzzlepiece.extension", tint: .orange, title: "\(m.mod) is missing a mod it needs", detail: m.message) {
                    if let root = ModDependencies.gameRoot(game) {
                        Button("Show Mods Folder") { model.reveal(ModDependencies.child(of: root, named: "Mods") ?? root) }
                    }
                })))
        }
        if let h = graphicsHint {
            items.append(AttentionItem(id: "graphics", view: AnyView(
                NoticeCard(symbol: "display.trianglebadge.exclamationmark", tint: .orange, title: h.title, detail: h.detail, evidence: h.evidence) {
                    if let a = h.addArguments { Button("Add \(a)") { addArguments(a) }.buttonStyle(.borderedProminent) }
                    ForEach(h.suggested) { p in Button("Use \(p.title)") { switchGraphics(p) }.buttonStyle(.borderedProminent) }
                })))
        }
        if let fc = folderChanges, let folder = OriginalFiles.folder(game) {
            items.append(AttentionItem(id: "original-folder", view: AnyView(
                NoticeCard(symbol: "exclamationmark.triangle", tint: .orange, title: "\(game.name) changed files in your folder",
                           detail: "It \(fc.summary) in “\(folder.lastPathComponent)”, which it uses where it is. Games often save settings or progress beside their program. If you want this folder kept exactly as it was, stop here and add the game again as a copy (Add a Game → Existing game folder → Copy it); a copy on the same drive is instant.",
                           evidence: fc.examples.joined(separator: ", ") + (fc.count > 3 ? " and \(fc.count - 3) more" : "")) {
                    Button("Show Folder") { model.reveal(folder) }
                    Button("That's Fine") { let g = game; Task.detached { OriginalFiles.record(g) }; folderChanges = nil }
                        .help("Keeps watching, from how the folder is now.")
                    Button("Stop Watching") { OriginalFiles.setAllowChanges(true, for: game); folderChanges = nil }.buttonStyle(.link)
                })))
        }
        if let su = setup {
            items.append(AttentionItem(id: "setup", view: AnyView(
                NoticeCard(symbol: "wand.and.stars", tint: .purple, title: su.title, detail: su.detail) {
                    if applyingSetup { ProgressView().controlSize(.small) }
                    else {
                        Button(su.button) { applySetup(su) }.buttonStyle(.borderedProminent).disabled(running)
                        Button("Not Now") { GameSetups.dismiss(game); setup = nil }.buttonStyle(.link)
                    }
                })))
        }
        if let mem = memory {
            items.append(AttentionItem(id: "memory", view: AnyView(
                NoticeCard(symbol: "memorychip", tint: .orange, title: mem.advice.title, detail: mem.advice.detail,
                           evidence: "Last run " + mem.session.updated.formatted(date: .abbreviated, time: .shortened)) {
                    if mem.advice.offersLowMemoryDXMT {
                        Button("Use Low-memory DXMT") { useLowMemoryDXMT() }.buttonStyle(.borderedProminent).disabled(running || applyingLowMemory)
                    }
                    Button("Dismiss") { UserDefaults.standard.set(mem.session.started.timeIntervalSince1970, forKey: memoryDismissedKey); memory = nil }
                })))
        }
        if let d = cinematicDiagnosis, !CinematicFix.isPresent(for: game) {
            items.append(AttentionItem(id: "cinematic", view: AnyView(CinematicCrashBanner(game: game, diagnosis: d) { fixFromBanner() })))
        }
        if let w = AntiCheat.warning(for: game), !game.isSteamHost, !LibraryOrganizer.isLauncher(game) {
            items.append(AttentionItem(id: "anticheat", view: AnyView(
                NoticeCard(symbol: w.verdict == .blocked ? "xmark.shield" : "exclamationmark.shield", tint: w.verdict == .blocked ? .red : .orange,
                           title: w.verdict == .blocked ? "Anti-cheat blocks online play" : "Anti-cheat may affect online play",
                           detail: w.detail + " Based on areweanticheatyet.com (Linux/Steam Deck reports) — your results on a Mac may differ.") { EmptyView() })))
        }
        return items
    }

    var launcherHost: InstalledGame? {
        guard let contents = WineTools.hostContents(for: game), contents != game.contents else { return nil }
        return model.games.first { $0.contents.standardizedFileURL == contents.standardizedFileURL }
    }

    func applySetup(_ su: GameSetups.Setup) {
        applyingSetup = true
        let g = game, games = model.games
        Task {
            do {
                try await GameSetups.apply(su.kind, to: g, games: games) { line in Task { @MainActor in model.say(line) } }
                model.say("Applied the recommended setup to \(g.name). Press Play to try it.")
                setup = nil
            } catch { model.fail(error) }
            applyingSetup = false; model.refresh()
        }
    }

    func resetToRecommended() {
        busy = true
        let g = game, games = model.games
        Task {
            do {
                let skipped = try await GameSetups.resetToRecommended(g, games: games) { line in Task { @MainActor in model.say(line) } }
                model.say(skipped.isEmpty ? "\(g.name) is back to its recommended setup." + (RestorePoints.automaticChosen ? " A restore point has your earlier settings." : "")
                                          : "\(g.name) was reset. Skipped: " + skipped.joined(separator: " "))
            } catch { model.fail(error) }
            busy = false; model.refresh()
            await loadNotices()
        }
    }

    func useLowMemoryDXMT() {
        applyingLowMemory = true
        let g = game
        Task {
            do {
                try await CompatibilityFixes.install(.dxmtLowMemory, for: g) { line in Task { @MainActor in model.say(line) } }
                model.say("\(g.name) uses Low-memory DXMT from its next start. Undo is in Fixes.")
                memory = nil
            } catch { model.fail(error) }
            applyingLowMemory = false; model.refresh()
        }
    }

    var running: Bool { if case .launcherRunning = model.runStates[game.id] ?? .notRunning { return true }; return false }

    var body: some View {
        if let n = game.native { NativeGameDetail(game: game, native: n) }
        else {
            wineBody.environment(\.pendingControlTitles, pendingTitles)
                .task(id: "\(game.id)|\(model.libraryRevision)|\(model.pendingActivities[game.id].map { "\($0)" } ?? "")") {
                    let g = game
                    pendingTitles = await Task.detached(priority: .userInitiated) { PendingSettings.controlTitles(for: g) }.value
                }
        }
    }
    @State private var pendingTitles = Set<String>()

    var wineBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let message = model.helperActivation[game.id]?.message {
                    SettingNote(message, warning: true)
                }
                if model.statusUnavailable {
                    SettingNote("Game status is temporarily unavailable. The last known status is kept; changes that require a closed game will wait for a reliable check.", warning: true)
                }
                AttentionArea(items: attentionItems).id("attention-\(game.id)-\(attentionItems.count)")
                if let u = model.updating[game.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Updating \(game.name)…").font(.body.bold())
                        if let p = u.progress { ProgressView(value: p.fraction); Text(p.label).font(.caption).monospacedDigit() }
                        else { ProgressView().progressViewStyle(.linear); Text(u.line).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .padding(12).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                } else if let u = model.storeUpdates[game.id] {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update available from \(u.link.store.title)").font(.body.bold())
                            Text("Installed \(u.installed) · newest \(u.latest)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update") { model.updateGame(game) }.buttonStyle(.borderedProminent)
                            .disabled({ if case .launcherRunning = model.runStates[game.id] ?? .notRunning { return true }; return false }())
                    }
                    .padding(12).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if game.custom != nil, !LibraryOrganizer.isLauncher(game) {
                    SuggestionsBanner(game: game).id("suggest-\(game.id)")
                }
                if game.native == nil { PendingSettingsSection(game: game) }
                HStack {
                    SettingSearchField(available: availableTabs, tab: $tab).frame(maxWidth: 360)
                    Spacer()
                    Picker("View", selection: $simple) {
                        Text("Simple").tag(true)
                        Text("Advanced").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Simple shows the settings most games need; Advanced shows everything (Wine, fixes, performance, Windows tools).")
                }
                Picker("Settings", selection: $tab) {
                    ForEach(availableTabs) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Group {
                    switch currentTab {
                    case .overview: overviewTab
                    case .display: displayTab
                    case .performance: performanceTab
                    case .controls: controlsTab
                    case .compatibility: compatibilityTab
                    case .storage: storageTab
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { reloadDisplay(); cinematicDiagnosis = CinematicFix.diagnoseLastRun(game); graphicsHint = CrashHints.diagnose(game) }
        .task(id: "\(game.id)-\(running)") { await loadNotices() }
        .onChange(of: running) { if !running { cinematicDiagnosis = CinematicFix.diagnoseLastRun(game); graphicsHint = CrashHints.diagnose(game) } }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(game: game) }
        .sheet(isPresented: $showReport) { ReportProblemView(game: game) }
        .sheet(isPresented: $showSettingsBackups) { SettingsBackupsView(game: game).environmentObject(model) }
        .confirmationDialog("Repair \(game.name)?", isPresented: $confirmRepair) {
            Button("Repair") { runRepair() }
        } message: {
            Text("Checks and restores the engine, launcher, Windows folders and settings the game needs. Anything replaced goes to the Trash or can be undone. Saves and game content aren't touched.")
        }
        .confirmationDialog("Reset \(game.name) to its recommended setup?", isPresented: $confirmResetAll) {
            Button("Reset to Recommended", role: .destructive, action: resetToRecommended)
        } message: {
            Text((RestorePoints.automaticChosen ? "Takes a restore point, undoes" : "Undoes") + " every fix Nokcandu installed, and applies the recommended setup again (including suggestions you chose Not Now for). Saves, game files and the game's own options aren't touched." + (RestorePoints.automaticChosen ? " Restore Points brings your current settings back." : ""))
        }
        .confirmationDialog("Reset \(game.name) to its tested settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: reset)
        } message: {
            Text("Undoes every change Nokcandu made and returns to Fullscreen. Saves, replays, maps, and your other options are not touched.")
        }
    }

    // MARK: Tabs

    enum Tab: String, CaseIterable, Identifiable {
        case overview, display, performance, controls, compatibility, storage
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"; case .display: "Display"; case .performance: "Performance"
            case .controls: "Controls"; case .compatibility: "Wine & Fixes"; case .storage: "Storage"
            }
        }
        var symbol: String {
            switch self {
            case .overview: "gamecontroller"; case .display: "display"; case .performance: "speedometer"
            case .controls: "computermouse"; case .compatibility: "wrench.and.screwdriver"; case .storage: "internaldrive"
            }
        }
    }
    /// The last tab you used is remembered across games.
    @AppStorage("gameSettingsTab") private var tab: Tab = .overview
    /// Simple hides Wine & Fixes and Performance (graphics mode moves to Overview). Remembered for every game.
    @AppStorage("gamePageSimple") private var simple = false

    var hasDisplayTab: Bool {
        DisplayController.supports(game) || hasResizable || game.hosted?.exe != nil || game.custom != nil
    }
    var hasResizable: Bool {
        game.native == nil && WineTools.hostContents(for: game) != nil
            && !(game.custom != nil && game.battleNet == nil && !BattleNet.isHost(game) && !DisplayController.supports(game))
    }
    var hasPerformanceTab: Bool {
        game.custom != nil || game.isSteamHost || game.hosted?.exe != nil || RecipeSettings.supports(game) || game.battleNet != nil
    }
    var hasControlsTab: Bool { WineTools.hostContents(for: game) != nil && (game.hosted == nil || game.hosted?.exe != nil) }
    var availableTabs: [Tab] {
        Tab.allCases.filter {
            switch $0 {
            case .display: return hasDisplayTab
            case .performance: return hasPerformanceTab
            case .controls: return hasControlsTab
            case .compatibility: return !simple || game.native != nil
            default: return true
            }
        }.filter { !(simple && $0 == .performance) }
    }
    var currentTab: Tab { availableTabs.contains(tab) ? tab : .overview }

    @ViewBuilder var overviewTab: some View {
        if game.native == nil { GameSummarySection(game: game, lastCrash: crash, showDiagnostics: { showDiagnostics = true }) }
        if simple, game.native == nil, game.custom != nil, !LibraryOrganizer.isLauncher(game) {
            SettingsSection(title: "Graphics", info: "How the game's DirectX reaches the Mac. Switch to Advanced (top of this page) for fixes, the Wine version and Windows tools.") {
                GraphicsPicker(game: game) { model.refresh() }.id("simple-graphics-\(game.id)-\(model.libraryRevision)")
            }
        }
        if game.custom?.disc != nil { GameDiscsSection(game: game).id("discs-\(game.id)-\(Discs.all(game.custom!).count)") }
        if game.battleNet != nil { BattleNetGameInfo(game: game) }
        if game.isSteamHost { SteamGamesSection().id("steamgames-\(model.games.count)") }
        if BattleNet.isHost(game) { BlizzardGamesSection(host: game).id("bnet-\(game.id)-\(model.games.count)") }
        if let k = PCLaunchers.kind(of: game) { LauncherGamesSection(host: game, kind: k).id("pcl-\(game.id)-\(model.games.count)") }
        if game.isSteamHost || game.usesSharedSteam { SteamTipsSection() }
        if game.native == nil { ChangeHistorySection(game: game).id("history-\(game.id)") }
        if game.isManaged { NotesSection(game: game).id(game.id) }
        aboutSection
    }

    @ViewBuilder var displayTab: some View {
        if DisplayController.supports(game) { displaySection }
        // The resizable window lives in the game's Display section; games without one get it on its own.
        if hasResizable { ResizableWindowSection(game: game).id("resizable-\(game.id)") }
        if game.custom != nil {
            SettingsSection(title: "Graphics") { GraphicsPicker(game: game) }
        }
        if game.custom != nil, game.battleNet == nil, !BattleNet.isHost(game), !DisplayController.supports(game) {
            GameResolutionSection(game: game).id("res-\(game.id)-\(game.custom?.displayPixels ?? [])")
        }
        if game.hosted?.exe != nil { HostedGameSettingsSection(game: game).id("hosted-\(game.id)") }
    }

    @ViewBuilder var performanceTab: some View {
        if game.custom != nil || game.isSteamHost || game.hosted?.exe != nil || RecipeSettings.supports(game) {
            PerformanceSection(game: game).id("perf-\(game.id)")
        }
        if game.battleNet != nil {
            SettingsSection(title: "Microphone") { MicrophoneSettingRow(game: game) }
        }
    }

    @ViewBuilder var controlsTab: some View {
        if hasControlsTab {
            MouseSection(game: game).id("mouse-\(game.id)")
            KeyboardSection(game: game).id("keyboard-\(game.id)")
            GameControllersSection(game: game).id("controllers-\(game.id)")
            ControllerProfileSection(game: game).id("padprofile-\(game.id)")
        }
    }

    @ViewBuilder var compatibilityTab: some View {
        if game.native == nil { GameWineSection(game: game).id("wine-\(game.id)-\(game.wineVersion ?? "")") }
        EngineNotice(game: game).id("engine-\(game.id)")
        if game.custom != nil {
            GameSettingsSection(game: game).id(game.custom)
        }
        if RecipeSettings.supports(game) { RecipeSettingsSection(game: game).id("recipe-settings-\(game.id)") }
        if WineTools.hostContents(for: game) != nil, game.hosted == nil { FixesSection(game: game).id("\(game.id)-\(fixVersion)") }
        else if WineTools.hostContents(for: game) != nil {
            SettingsSection(title: "Fixes") { PhysXRuntimeRow(game: game).id("physx-\(game.id)") }
        }
        if game.custom != nil || game.battleNet != nil || game.hosted?.exe != nil || RecipeSettings.supports(game) { ProfilesSection(game: game).id("profiles-\(game.id)") }
        checkSection
        if !WineTools.places(for: game).isEmpty { FilesToolsSection(game: game) }
    }

    @ViewBuilder var storageTab: some View {
        GameLocationSection(game: game).id("location-\(game.id)")
        if let folder = OriginalFiles.folder(game) { OriginalFolderSection(game: game, folder: folder).id("original-\(game.id)") }
        if game.isSteamHost || BattleNet.isHost(game) || PCLaunchers.kind(of: game) != nil {
            LauncherDriveBox(host: game, name: game.isSteamHost ? "Steam" : BattleNet.isHost(game) ? "Battle.net" : PCLaunchers.kind(of: game)!.title)
                .id("drives-\(game.id)")
        }
        if RestorePoints.hostApp(for: game) != nil { RestorePointsSection(game: game).id("restore-\(game.id)-\(fixVersion)-\(model.games.count)") }
        RemoveGameSection(game: game).id("remove-\(game.id)")
    }

    // MARK: Header

    var header: some View {
        HStack(alignment: .center, spacing: 18) {
            GameIconEditor(game: game)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.name).font(.largeTitle.bold())
                    Button { model.renaming = game } label: { Image(systemName: "pencil") }.accessibilityLabel("Rename \(game.name)").help("Rename")
                        .buttonStyle(.borderless).help("Rename this game or give it a subtitle")
                }
                if let r = game.recipe {
                    Text(r.edition).foregroundStyle(.secondary)
                } else {
                    Text("Not set up by a Nokcandu recipe — Play still works.").foregroundStyle(.secondary)
                }
                GameStorageSummary(game: game)
                HStack(spacing: 10) {
                    Button { model.play(game) } label: {
                        Label(game.isSteamHost ? (running ? "Show Steam" : "Open Steam") : (running ? "Running" : "Play"), systemImage: "play.fill").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(running && !game.isSteamHost)
                    if game.isSteamHost {
                        Button("Steam Library…") { model.showSteamLibrary = true }
                        if running { Button("Quit Steam…", role: .destructive) { model.requestQuit(game) }.controlSize(.large) }
                    } else if running {
                        Button("Quit…", role: .destructive) { model.requestQuit(game) }.controlSize(.large)
                    }
                    if !game.isSteamHost {
                        Button("Won't start?") { showDoctor = true }.buttonStyle(.link)
                            .help("Goes through what usually stops a game from starting, repairs what it can, and tells you what to do.")
                    }
                }
                .padding(.top, 4)
                .sheet(isPresented: $showDoctor) { LaunchDoctorSheet(game: game).environmentObject(model) }
                if let stage = model.launchStages[game.id] { LaunchProgressLine(text: stage) }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.launchStages[game.id])
    }

    // MARK: Display (milestone 2)

    var displaySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Display", selection: Binding(
                    get: { display?.mode ?? .fillScreen },
                    set: { apply($0) })) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(running || busy || display?.launcher == .unrecognized)

                if let d = display {
                    Text(d.mode == .fillScreen
                         ? "Uses your whole screen at the current desktop size (\(d.desktop.description)). Switching apps keeps working."
                         : "A \(game.recipe?.display?.recoveryWindow.description ?? "1280 × 800") window — use this if the screen ever looks wrong.")
                        .font(.callout).foregroundStyle(.secondary)
                    if d.launcher == .unrecognized {
                        Label("The game's launcher was changed outside Nokcandu, so display settings are locked. See Diagnostics.", systemImage: "lock.fill")
                            .font(.callout).foregroundStyle(.orange)
                    } else if !d.consistent {
                        Label("Game settings don't fully match this mode yet; they'll be corrected the next time you press Play here.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if running { Text("Quit the game to change this.").font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Reset to Tested Settings…") { confirmReset = true }
                        .disabled(running || busy)
                    Spacer()
                }
            }
            .padding(6)
        } label: { Text("Screen").font(.headline) }
    }

    // MARK: Check

    var checkSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        checking = true; checkResult = nil
                        Task {
                            let r = await GameLauncher.preflight(game)
                            checkResult = r; checking = false
                        }
                    } label: { Label("Check Game", systemImage: "stethoscope") }
                    .disabled(checking || running)
                    Button { showDiagnostics = true } label: { Label("Diagnostics…", systemImage: "list.bullet.clipboard") }
                    Button { showReport = true } label: { Label("Report a Problem…", systemImage: "exclamationmark.bubble") }
                    if checking || repairing || busy { ProgressView().controlSize(.small) }
                }
                HStack {
                    Button { confirmRepair = true } label: { Label("Repair…", systemImage: "wrench.and.screwdriver") }
                        .disabled(running || repairing || !game.isManaged)
                    Button { confirmResetAll = true } label: { Label("Reset to Recommended…", systemImage: "arrow.counterclockwise") }
                        .disabled(running || busy || repairing)
                        .help("Undo every fix and apply the recommended setup again.")
                    Button("Settings Backups…") { showSettingsBackups = true }
                }
                if let missing = GameDataSpec.forGame(game)?.missingEssentials, !missing.isEmpty {
                    Label("The game's settings folder in Documents is missing \(missing.joined(separator: ", ")). Repair can put it back.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let steps = repairSteps {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(steps) { s in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: s.outcome == .ok ? "checkmark.circle" : s.outcome == .fixed ? "wrench.and.screwdriver.fill" : s.outcome == .failed ? "xmark.octagon.fill" : "minus.circle")
                                    .foregroundStyle(s.outcome == .fixed ? .blue : s.outcome == .failed ? .red : s.outcome == .ok ? .green : .secondary)
                                VStack(alignment: .leading) {
                                    Text(s.title)
                                    Text(s.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let r = checkResult {
                    Label(r.ok ? (r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Check passed." : r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                               : "Check failed. Open Diagnostics for details.",
                          systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(r.ok ? .green : .red)
                    if !r.ok, !r.combined.isEmpty {
                        Text(r.combined.suffix(600)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Text("Check looks at the game files, engine\(game.recipe?.disc != nil ? " and disc" : "") without starting the game. Repair puts back what the game needs to start — engine, launcher, folders, settings — and never touches your saves or game content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: { Text("Health").font(.headline) }
    }

    // MARK: About

    var aboutSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let r = game.recipe {
                    ForEach(r.verification) { v in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: v.state == .confirmed ? "checkmark.seal.fill" : "questionmark.circle")
                                .foregroundStyle(v.state == .confirmed ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(v.title)
                                Text(v.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    DisclosureGroup("Technical details") {
                        VStack(alignment: .leading, spacing: 4) {
                            detail("Recipe", "\(r.id) (validated \(r.validationDate))")
                            detail("Source", r.ownershipSource)
                            detail("Engine", "\(r.runtime.engine) · \(game.wineVersion ?? "?")")
                            detail("Wrapper", r.runtime.template)
                            if let rr = r.runtime.renderer { detail("Renderer", rr) }
                            if let gd = r.runtime.gpuDriver { detail("GPU driver", gd) }
                            detail("App", game.appURL.path)
                            ForEach(r.notes, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.top, 4)
                    }.disclosureGroupStyle(WholeRowDisclosureStyle())
                } else {
                    detail("Engine", game.wineVersion ?? "unknown")
                    detail("App", game.appURL.path)
                }
                HStack(spacing: 16) {
                    Button("Show in Finder") { model.reveal(game.appURL) }.buttonStyle(.link)
                    if game.usesSharedSteam {
                        Button("Refresh Icon") {
                            if SharedSteam.refreshIcon(for: game) { model.refresh(); model.say("Icon updated.") }
                            else { model.fail(NokError("Couldn't find an icon for this game yet.")) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(6)
        } label: { Text("About This Setup").font(.headline) }
    }

    func detail(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).textSelection(.enabled)
        }.font(.callout)
    }

    // MARK: Actions

    // File work (game settings live in Documents, which may be iCloud-synced and slow to read)
    // always runs off the main thread so the window can never freeze.
    func addArguments(_ a: String) {
        guard var c = game.custom else { return }
        c.arguments = (c.arguments + " " + a).trimmingCharacters(in: .whitespaces)
        do { try CustomGames.save(c, to: game); graphicsHint = nil; model.say("Launch options updated. Press Play to try again."); model.refresh() }
        catch { model.fail(error) }
    }

    func switchGraphics(_ p: GraphicsPreset) {
        guard var c = game.custom else { return }
        c.graphics = p
        do { try CustomGames.save(c, to: game); graphicsHint = nil; model.say("Graphics: \(p.title). Press Play to try again."); model.refresh() }
        catch { model.fail(error) }
    }

    func fixFromBanner() {
        let g = game
        model.say("Installing the cinematic fix…")
        Task {
            do {
                try await CinematicFix.install(for: g, log: { _ in })
                model.say("Cinematic fix installed. Try the game again.")
                cinematicDiagnosis = nil
            } catch { model.fail(error) }
            fixVersion += 1
        }
    }

    func runRepair() {
        repairing = true; repairSteps = nil
        let g = game
        Task {
            let steps = await Task.detached(priority: .userInitiated) { Repair.run(g) }.value
            repairSteps = steps; repairing = false
            let fixed = steps.filter { $0.outcome == .fixed }.count, failed = steps.filter { $0.outcome == .failed }.count
            if failed > 0 { model.fail(NokError("Repair finished: \(failed) problem(s) need attention.")) }
            else { model.say(fixed > 0 ? "Repaired \(fixed) thing(s)." : "Everything looked fine — nothing needed repair.") }
            model.refresh(); reloadDisplay()
        }
    }

    func reloadDisplay() {
        guard DisplayController.supports(game) else { return }
        let g = game
        Task {
            let s = await Task.detached(priority: .userInitiated) { DisplayController.status(g) }.value
            display = s
        }
    }

    func apply(_ mode: DisplayMode) {
        guard mode != display?.mode, !busy else { return }
        busy = true
        let g = game
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try DisplayController.apply(mode, to: g) } }.value
            switch r { case .success(let msg): model.say(msg); case .failure(let e): model.fail(e) }
            busy = false
            reloadDisplay()
        }
    }

    func reset() {
        busy = true
        let g = game
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try DisplayController.reset(g).summary } }.value
            switch r { case .success(let msg): model.say(msg); case .failure(let e): model.fail(e) }
            busy = false
            reloadDisplay()
        }
    }
}

/// A Mac game's page: open it, see where it is, take it out of the library.
struct NativeGameDetail: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    let native: NativeGame
    @State private var confirmRemove = false

    var running: Bool { if case .launcherRunning = model.runStates[game.id] ?? .notRunning { return true }; return false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: game.icon).resizable().frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(game.name).font(.largeTitle.bold())
                            Button { model.renaming = game } label: { Image(systemName: "pencil") }.accessibilityLabel("Rename \(game.name)").help("Rename").buttonStyle(.borderless)
                        }
                        GameStorageSummary(game: game)
                        Text(native.store.map { "Mac version from \($0.store.title)" } ?? "Mac game — runs natively, no Wine").foregroundStyle(.secondary)
                        if let n = MacCompat.note(MacCompat.check(game.appURL)) {
                            Label(n.text, systemImage: n.warning ? "exclamationmark.triangle" : "checkmark.circle")
                                .font(.callout).foregroundStyle(n.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button { model.play(game) } label: { Label(running ? "Running" : "Play", systemImage: "play.fill").frame(minWidth: 90) }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(running)
                            if running { Button("Quit…", role: .destructive) { model.requestQuit(game) }.controlSize(.large) }
                            Button("Show in Finder") { model.reveal(game.appURL) }
                        }
                        .padding(.top, 4)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.appURL.path).font(.callout).textSelection(.enabled)
                        Text("On " + Storage.driveName(game.appURL) + ". Nokcandu only opens this app; its settings live in the game itself. Keys below apply while it's in front; graphics, mouse and Wine settings don't apply to Mac games.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Location").font(.headline) }
                KeyboardSection(game: game).id("keyboard-\(game.id)")
                GroupBox {
                    HStack(alignment: .top) {
                        Text(native.installFolder != nil
                             ? "Remove from Nokcandu, or also move the downloaded game to the Trash."
                             : "Removes it from Nokcandu's list. The app itself isn't touched.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove…", role: .destructive) { confirmRemove = true }
                    }
                    .padding(6)
                } label: { Text("Remove").font(.headline) }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .confirmationDialog("Remove \(game.name)?", isPresented: $confirmRemove) {
            Button("Remove from Nokcandu") { remove(trash: false) }
            if let f = native.installFolder {
                Button("Remove and Move Game to Trash", role: .destructive) { _ = f; remove(trash: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    func remove(trash: Bool) {
        NativeGames.remove(id: native.id)
        if trash, let f = native.installFolder { try? FileManager.default.trashItem(at: URL(fileURLWithPath: f), resultingItemURL: nil) }
        model.selection = nil
        model.refresh()
        model.say(trash ? "\(game.name) moved to the Trash." : "Removed \(game.name) from Nokcandu.")
    }
}

/// Top of a game's page: the best-rated community profile (for games not played yet) and known fixes
/// from Proton's community database. Each can be applied or dismissed.
struct SuggestionsBanner: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var recs: [Recommendation] = []
    @State private var unchecked: Set<String> = []
    @State private var profile: CatalogEntry?
    @State private var applying = false
    @State private var log = ""
    @AppStorage("dismissedProfiles") private var dismissedProfiles = ""

    var newGame: Bool { LibraryOrganizer.lastPlayed(game) == nil || (game.custom.map { Date().timeIntervalSince($0.createdAt) < 7 * 86400 } ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let e = profile {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.2.fill").foregroundStyle(.blue).font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Community profile for this game").font(.body.bold())
                            RatingBadge(rating: e.profile.rating)
                            Text("👍 \(e.up)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let n = e.profile.notes { Text(n).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                        Text("Shared by \(e.author)" + (e.profile.tested?.mac.map { " · tested on \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Button("View & Apply…") { model.profileFocus = e.number; model.showProfiles = true }.buttonStyle(.borderedProminent)
                        Button("Not Now") { dismissedProfiles += ",\(game.id)#\(e.number)"; profile = nil }.buttonStyle(.link)
                    }
                }
                .padding(12)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if !recs.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "wand.and.stars").foregroundStyle(.purple).font(.title3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recommended setup").font(.body.bold())
                        Text("Based on what this game's files use and how it last ran. Each change can be undone in Settings or Fixes.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(recs) { r in
                            Toggle(isOn: Binding(get: { !unchecked.contains(r.id) },
                                                 set: { on in if on { unchecked.remove(r.id) } else { unchecked.insert(r.id) } })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.title).font(.callout)
                                    Text(r.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    if case .knownFix(let f) = r.action {
                                        ForEach(lines(f), id: \.self) { Text("• " + $0).font(.caption) }
                                        ForEach(f.notApplied, id: \.self) { Text("• " + $0 + " (not applied automatically)").font(.caption).foregroundStyle(.secondary) }
                                        Link("From Proton's community fixes (umu-protonfixes)", destination: f.source).font(.caption)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox).disabled(applying)
                        }
                        if applying || !log.isEmpty { Text(log).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        if applying { ProgressView().controlSize(.small) }
                        else {
                            Button("Apply Recommended") { applyRecs() }.buttonStyle(.borderedProminent)
                                .disabled(recs.allSatisfy { unchecked.contains($0.id) })
                            Button("Not Now") { dismissRecs() }.buttonStyle(.link)
                        }
                    }
                }
                .padding(12)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task {
            let g = game
            if newGame {
                let best = Profiles.forGame(g, in: Profiles.cached()).first { !$0.reportedBroken && $0.profile.rating != .broken && $0.score >= 0 }
                if let best, !dismissedProfiles.contains("\(g.id)#\(best.number)") { profile = best }
            }
            await loadRecs()
        }
    }

    func loadRecs() async {
        let g = game
        let local = await Task.detached(priority: .utility) { Recommendations.forGame(g) }.value
        recs = Recommendations.withKnownFix(local, await KnownFixes.lookup(g), for: g)
    }

    func dismissRecs() {
        Recommendations.dismiss(recs.map(\.id), for: game)
        for r in recs { if case .knownFix(let f) = r.action { KnownFixes.markHandled(game, f) } }
        recs = []
    }

    func applyRecs() {
        let chosen = recs.filter { !unchecked.contains($0.id) }
        let rest = recs.filter { unchecked.contains($0.id) }
        applying = true; log = ""
        let g = game
        Task {
            do {
                let skipped = try await Recommendations.apply(chosen, to: g) { line in Task { @MainActor in log = line } }
                // Unchecked ones were a choice: don't offer them again.
                Recommendations.dismiss(rest.map(\.id), for: g)
                for r in rest { if case .knownFix(let f) = r.action { KnownFixes.markHandled(g, f) } }
                model.refresh()
                if skipped.isEmpty { model.say("Applied the recommended setup to \(g.name).") }
                else { model.say("Applied what could be applied. Skipped: " + skipped.joined(separator: " ")) }
                log = ""
                await loadRecs()
            } catch { model.fail(error); await loadRecs() }
            applying = false
        }
    }

    func lines(_ f: KnownFix) -> [String] {
        var out: [String] = []
        if !f.verbs.isEmpty { out.append("Install Windows components: \(f.verbs.joined(separator: ", "))") }
        if !f.arguments.isEmpty { out.append("Launch options: \(f.arguments.joined(separator: " "))") }
        for (k, v) in f.environment.sorted(by: { $0.key < $1.key }) { out.append("Setting: \(k)=\(v)") }
        for (d, o) in f.dllOverrides.sorted(by: { $0.key < $1.key }) {
            out.append("Use \(o.hasPrefix("n") ? "the game's own" : o.isEmpty ? "no" : "Wine's") \(d).dll")
        }
        return out
    }
}


/// Storage → Your Folder: a game that uses your own folder where it is, and whether Nokcandu keeps it unchanged.
struct OriginalFolderSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    let folder: URL
    @State private var protected = true

    var body: some View {
        SettingsSection(title: "Your Folder", info: "This game runs from your own folder instead of a copy, so nothing was copied and no extra space is used. With “Keep my folder unchanged” on, Nokcandu won't put fixes or settings into it, and after each session it tells you if the game itself changed files there (many games save settings beside their program).") {
            SettingRow(title: "Folder") {
                Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button("Show") { model.reveal(folder) }.buttonStyle(.link)
            }
            SettingToggle(title: "Keep my folder unchanged",
                          info: "On: fixes that would put files in this folder are refused, and changes the game makes are reported after it quits. Off: Nokcandu can change files here like in a copy (fixes keep their own Undo).",
                          isOn: Binding(get: { protected }, set: { on in protected = on; OriginalFiles.setAllowChanges(!on, for: game) }))
            SettingNote("Removing the game from Nokcandu leaves this folder where it is.")
        }
        .onAppear { protected = OriginalFiles.isProtected(game) }
    }
}
