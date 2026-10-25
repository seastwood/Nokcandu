import SwiftUI
import NokcanduCore

struct GameDetailView: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    @State private var display: DisplayStatus?
    @State private var checking = false
    @State private var checkResult: ShellResult?
    @State private var showDiagnostics = false
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
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
                if game.custom != nil {
                    GroupBox {
                        GraphicsPicker(game: game).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Text("Graphics").font(.headline) }
                }
                if game.battleNet != nil { BattleNetGameInfo(game: game) }
                if game.isSteamHost { SteamGamesSection().id("steamgames-\(model.games.count)") }
                if BattleNet.isHost(game) { BlizzardGamesSection(host: game).id("bnet-\(game.id)-\(model.games.count)") }
                if game.custom != nil || game.isSteamHost {
                    PerformanceSection(game: game).id("perf-\(game.id)")
                }
                if WineTools.hostContents(for: game) != nil {
                    MouseSection(game: game).id("mouse-\(game.id)")
                }
                if game.custom != nil {
                    GameSettingsSection(game: game).id(game.custom)
                }
                checkSection
                if !WineTools.places(for: game).isEmpty { FilesToolsSection(game: game) }
                if WineTools.hostContents(for: game) != nil { FixesSection(game: game).id("\(game.id)-\(fixVersion)") }
                if game.isManaged { NotesSection(game: game).id(game.id) }
                aboutSection
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { reloadDisplay(); cinematicDiagnosis = CinematicFix.diagnoseLastRun(game); graphicsHint = CrashHints.diagnose(game) }
        .onChange(of: running) { if !running { cinematicDiagnosis = CinematicFix.diagnoseLastRun(game); graphicsHint = CrashHints.diagnose(game) } }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(game: game) }
        .confirmationDialog("Repair \(game.name)?", isPresented: $confirmRepair) {
            Button("Repair") { runRepair() }
        } message: {
            Text("Checks and restores the engine, launcher, Windows folders and settings the game needs. Anything replaced goes to the Trash or can be undone. Saves and game content aren't touched.")
        }
        .confirmationDialog("Reset \(game.name) to its tested settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: reset)
        } message: {
            Text("Undoes every change Nokcandu made and returns to Fill screen. Saves, replays, maps, and your other options are not touched.")
        }
    }

    // MARK: Header

    var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: game.icon).resizable().frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name).font(.largeTitle.bold())
                if let r = game.recipe {
                    Text(r.edition).foregroundStyle(.secondary)
                } else {
                    Text("Not set up by a Nokcandu recipe — Play still works.").foregroundStyle(.secondary)
                }
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
                    }
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
