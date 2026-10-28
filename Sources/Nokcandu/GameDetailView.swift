import SwiftUI
import NokcanduCore

struct GameDetailView: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    @State private var display: DisplayStatus?
    @State private var checking = false
    @State private var checkResult: ShellResult?
    @State private var showDiagnostics = false
    @State private var showSettingsBackups = false
    @State private var confirmReset = false
    @State private var busy = false
    @State private var confirmRepair = false
    @State private var repairing = false
    @State private var repairSteps: [RepairStep]?
    @State private var cinematicDiagnosis: CinematicFix.Diagnosis?
    @State private var graphicsHint: GraphicsHint?
    @State private var fixVersion = 0

    var running: Bool { if case .launcherRunning = model.runStates[game.id] ?? .notRunning { return true }; return false }

    var body: some View {
        if let n = game.native { NativeGameDetail(game: game, native: n) } else { wineBody }
    }

    var wineBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let w = AntiCheat.warning(for: game), !game.isSteamHost, !LibraryOrganizer.isLauncher(game) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: w.verdict == .blocked ? "xmark.shield" : "exclamationmark.shield")
                            .foregroundStyle(w.verdict == .blocked ? .red : .orange).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(w.verdict == .blocked ? "Anti-cheat blocks online play" : "Anti-cheat may affect online play").font(.body.bold())
                            Text(w.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("Based on areweanticheatyet.com (Linux/Steam Deck reports) — your results on a Mac may differ.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background((w.verdict == .blocked ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                if game.custom != nil, !LibraryOrganizer.isLauncher(game) {
                    SuggestionsBanner(game: game).id("suggest-\(game.id)")
                }
                if let h = graphicsHint {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "display.trianglebadge.exclamationmark").foregroundStyle(.orange).font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.title).font(.body.bold())
                            Text(h.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(h.evidence).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            if let a = h.addArguments {
                                Button("Add \(a)") { addArguments(a) }.buttonStyle(.borderedProminent)
                            }
                            ForEach(h.suggested) { p in
                                Button("Use \(p.title)") { switchGraphics(p) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding(12)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                if let st = EngineUpdate.state(for: game), st.status == .trying {
                    EngineTrialBanner(game: game, state: st)
                }
                if let d = cinematicDiagnosis, !CinematicFix.isPresent(for: game) {
                    CinematicCrashBanner(game: game, diagnosis: d) { fixFromBanner() }
                }
                if DisplayController.supports(game) { displaySection }
                if game.hosted?.exe != nil { HostedGameSettingsSection(game: game).id("hosted-\(game.id)") }
                if game.custom != nil {
                    GroupBox {
                        GraphicsPicker(game: game).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Text("Graphics").font(.headline) }
                }
                if game.custom != nil, game.battleNet == nil, !BattleNet.isHost(game), !DisplayController.supports(game) {
                    GameResolutionSection(game: game).id("res-\(game.id)-\(game.custom?.displayPixels ?? [])")
                }
                if game.custom?.disc != nil { GameDiscsSection(game: game).id("discs-\(game.id)-\(Discs.all(game.custom!).count)") }
                if game.battleNet != nil { BattleNetGameInfo(game: game) }
                if game.isSteamHost { SteamGamesSection().id("steamgames-\(model.games.count)") }
                if game.isSteamHost || game.usesSharedSteam { SteamTipsSection() }
                if BattleNet.isHost(game) { BlizzardGamesSection(host: game).id("bnet-\(game.id)-\(model.games.count)") }
                if let k = PCLaunchers.kind(of: game) { LauncherGamesSection(host: game, kind: k).id("pcl-\(game.id)-\(model.games.count)") }
                if game.isSteamHost || BattleNet.isHost(game) || PCLaunchers.kind(of: game) != nil {
                    LauncherDriveBox(host: game, name: game.isSteamHost ? "Steam" : BattleNet.isHost(game) ? "Battle.net" : PCLaunchers.kind(of: game)!.title)
                        .id("drives-\(game.id)")
                }
                if game.custom != nil || game.isSteamHost || game.hosted?.exe != nil {
                    PerformanceSection(game: game).id("perf-\(game.id)")
                }
                if WineTools.hostContents(for: game) != nil, game.hosted == nil || game.hosted?.exe != nil {
                    MouseSection(game: game).id("mouse-\(game.id)")
                }
                if game.custom != nil {
                    GameSettingsSection(game: game).id(game.custom)
                }
                if WineTools.hostContents(for: game) != nil { PhysXRuntimeSection(game: game).id("physx-\(game.id)") }
                checkSection
                if !WineTools.places(for: game).isEmpty { FilesToolsSection(game: game) }
                if WineTools.hostContents(for: game) != nil, game.hosted == nil { FixesSection(game: game).id("\(game.id)-\(fixVersion)") }
                if game.custom != nil || game.battleNet != nil || game.hosted?.exe != nil { ProfilesSection(game: game).id("profiles-\(game.id)") }
                if game.isManaged { NotesSection(game: game).id(game.id) }
                aboutSection
                GameLocationSection(game: game).id("location-\(game.id)")
                RemoveGameSection(game: game).id("remove-\(game.id)")
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { reloadDisplay(); cinematicDiagnosis = CinematicFix.diagnoseLastRun(game); graphicsHint = CrashHints.diagnose(game) }
        .onChange(of: running) { if !running { cinematicDiagnosis = CinematicFix.diagnoseLastRun(game); graphicsHint = CrashHints.diagnose(game) } }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(game: game) }
        .sheet(isPresented: $showSettingsBackups) { SettingsBackupsView(game: game).environmentObject(model) }
        .confirmationDialog("Repair \(game.name)?", isPresented: $confirmRepair) {
            Button("Repair") { runRepair() }
        } message: {
            Text("Checks and restores the engine, launcher, Windows folders and settings the game needs. Anything replaced goes to the Trash or can be undone. Saves and game content aren't touched.")
        }
        .confirmationDialog("Reset \(game.name) to its tested settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: reset)
        } message: {
            Text("Undoes every change Nokcandu made and returns to Fullscreen. Saves, replays, maps, and your other options are not touched.")
        }
    }

    // MARK: Header

    var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: game.icon).resizable().frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.name).font(.largeTitle.bold())
                    Button { model.renaming = game } label: { Image(systemName: "pencil") }
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
                        if running { Button("Quit Steam") { Task { await SharedSteam.shutdown(); model.refreshRunStates() } } }
                    } else if running {
                        Text("The game's launcher is running.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
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
                    Button("Settings Backups…") { showSettingsBackups = true }
                    Button { showDiagnostics = true } label: { Label("Diagnostics…", systemImage: "list.bullet.clipboard") }
                    Button { confirmRepair = true } label: { Label("Repair…", systemImage: "wrench.and.screwdriver") }
                        .disabled(running || repairing || !game.isManaged)
                    if checking || repairing { ProgressView().controlSize(.small) }
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
                            Button { model.renaming = game } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        }
                        GameStorageSummary(game: game)
                        Text(native.store.map { "Mac version from \($0.store.title)" } ?? "Mac game — runs natively, no Wine").foregroundStyle(.secondary)
                        HStack {
                            Button { model.play(game) } label: { Label(running ? "Running" : "Play", systemImage: "play.fill").frame(minWidth: 90) }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(running)
                            Button("Show in Finder") { model.reveal(game.appURL) }
                        }
                        .padding(.top, 4)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.appURL.path).font(.callout).textSelection(.enabled)
                        Text("On " + Storage.driveName(game.appURL) + ". Nokcandu only opens this app; its settings live in the game itself. Graphics, mouse and Wine settings don't apply to Mac games.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Location").font(.headline) }
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
    @State private var fix: KnownFix?
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
            if let f = fix {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.purple).font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Known fixes for this game").font(.body.bold())
                        if !f.summary.isEmpty { Text(f.summary).font(.callout).foregroundStyle(.secondary) }
                        ForEach(lines(f), id: \.self) { Text("• " + $0).font(.caption) }
                        ForEach(f.notApplied, id: \.self) { Text("• " + $0 + " (not applied automatically)").font(.caption).foregroundStyle(.secondary) }
                        HStack(spacing: 4) {
                            Text("From Proton's community fixes (umu-protonfixes) —").font(.caption).foregroundStyle(.secondary)
                            Link("details", destination: f.source).font(.caption)
                        }
                        if applying || !log.isEmpty { Text(log).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        if applying { ProgressView().controlSize(.small) }
                        else {
                            if !f.isEmpty { Button("Apply Fixes") { apply(f) }.buttonStyle(.borderedProminent) }
                            Button(f.isEmpty ? "Got It" : "Not Now") { KnownFixes.markHandled(game, f); fix = nil }.buttonStyle(.link)
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
            if let f = await KnownFixes.lookup(g), KnownFixes.handled(g) != f.fingerprint { fix = f }
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

    func apply(_ f: KnownFix) {
        applying = true; log = ""
        let g = game
        Task {
            do {
                try await KnownFixes.apply(f, to: g) { line in Task { @MainActor in log = line } }
                fix = nil
                model.refresh()
                model.say("Applied the known fixes to \(g.name).")
            } catch { model.fail(error) }
            applying = false
        }
    }
}
