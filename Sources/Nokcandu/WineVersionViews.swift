import SwiftUI
import NokcanduCore

/// Same verified engine list for game settings, installation defaults and one-install overrides.
struct WineVersionMenu: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: String
    var includeDefault = false
    /// Also list Apple silicon engines that aren't installed yet (chosen: downloaded when applied).
    var offersSources = false
    @State private var versions: [EngineVersion] = [.tested]
    @State private var sources: [ExternalEngines.Source] = []

    var body: some View {
        Picker("Wine version", selection: $selection) {
            if includeDefault { Text("Default (\(WineSelection.defaultEngine().description))").tag("") }
            ForEach(versions, id: \.self) { version in
                Text(version.description + (EngineSelfTests.failed(WineSelection.spec(for: version).id) ? " — startup check failed" : version == .tested ? " — original tested build" : ""))
                    .tag(version.tag)
                    .disabled(EngineSelfTests.failed(WineSelection.spec(for: version).id))
            }
            if offersSources && !sources.isEmpty {
                Divider()
                ForEach(sources) { s in Text("\(s.name) (Apple silicon, preview)").tag(ExternalEngines.sourceTag(s)) }
            }
        }
        .task(id: model.catalog?.checkedAt) {
            let catalog = model.catalog
            var values = await Task.detached(priority: .utility) {
                WineSelection.versions(catalog: catalog, cached: RuntimeManager.cachedRuntimes())
            }.value
            for version in [WineSelection.parse(selection), WineSelection.defaultEngine()].compactMap({ $0 }) where !values.contains(version) { values.append(version) }
            if !Task.isCancelled {
                versions = values.sorted(by: >)
                // A source with an engine already installed is listed by that engine instead.
                let installed = ExternalEngines.installed().compactMap(\.source)
                sources = ExternalEngines.sources().filter { !installed.contains($0.id) }
            }
        }
    }
}

struct DefaultWineSetting: View {
    @EnvironmentObject var model: AppModel
    @State private var selected = WineSelection.defaultEngine().tag
    var body: some View {
        WineVersionMenu(selection: Binding(get: { selected }, set: { tag in
            guard let engine = WineSelection.parse(tag) else { return }
            do { try WineSelection.setDefault(engine); selected = tag }
            catch { model.fail(error) }
        }))
        Text("Used for new Windows installations unless you choose another version. Existing games and unfinished installations keep their Wine version.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct GameWineSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var selected = ""
    @State private var working = false
    @State private var progress = ""
    @State private var confirmWarning = false
    /// Read from disk off the main thread whenever the game or the chosen version changes.
    struct Info: Equatable {
        var requested: String?
        var current: EngineVersion?
        var currentText: String
        var trial: EngineUpdate.State?
        var reason: String?
        var warning: String?
    }
    @State private var info: Info?

    var host: InstalledGame? { WineSelection.host(for: game, in: model.games) }
    var shownTag: String { selected.isEmpty ? info?.requested ?? info?.current?.tag ?? EngineVersion.tested.tag : selected }
    var target: EngineVersion? { WineSelection.parse(shownTag) }
    /// An Apple silicon engine chosen before it's installed: its newest release is installed when applied.
    var source: ExternalEngines.Source? { ExternalEngines.source(forTag: shownTag) }
    var reason: String? { info?.reason }
    var warning: String? { info?.warning }

    var body: some View {
        if let host {
            SettingsSection(title: "Wine", info: "Wine is the engine that runs Windows programs on the Mac. Each game keeps the version it was set up with until you choose another; Roll Back returns to the previous one. Use Selected Wine downloads a verified build if needed and keeps the previous engine for Roll Back. Game files and saves aren't affected.") {
                HStack {
                    WineVersionMenu(selection: Binding(get: { shownTag }, set: { selected = $0 }), offersSources: true)
                        .disabled(working || info == nil)
                    PendingSettingBadge(title: "Wine version")
                }
                Text("Currently using \(info?.currentText ?? "…").")
                    .font(.caption).foregroundStyle(.secondary)
                if host.id != game.id || host.isSteamHost || BattleNet.isHost(host) || PCLaunchers.kind(of: host) != nil {
                    Text("Shared by \(host.name) and the games that run inside it. Changing Wine here applies to that whole Windows environment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                else if let warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if let trial = info?.trial, trial.status == .trying {
                    EngineTrialBanner(game: host, state: trial)
                }
                HStack {
                    Button(working ? "Preparing Wine…" : "Use Selected Wine") {
                        if warning != nil { confirmWarning = true } else { apply() }
                    }
                    .disabled(working || info == nil || (target == nil && source == nil) || (target != nil && target == info?.current) || reason != nil || info?.trial?.status == .trying)
                    if working { ProgressView().controlSize(.small) }
                }
                if !progress.isEmpty { Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if source != nil || target?.external != nil {
                    HStack(spacing: 4) {
                        Text("Apple silicon engine (preview): some Nokcandu features don't apply.").font(.caption).foregroundStyle(.orange)
                        InfoButton("Apple silicon engines run Intel Windows programs with FEX instead of Rosetta. They come from other projects and are used exactly as built, so Nokcandu's raw mouse input, the audio buffer setting and the game's own name in the Dock aren't available with them. The resizable window works on the engines Nokcandu has its driver for.")
                    }
                }
            }
            .confirmationDialog("Use \(target?.description ?? "this Wine version")?", isPresented: $confirmWarning) {
                Button("Use Selected Wine") { apply() }
                Button("Cancel", role: .cancel) {}
            } message: { Text(warning ?? "") }
            .task(id: "\(host.id)|\(selected)|\(model.libraryRevision)") {
                let h = host, games = model.games, chosen = selected
                info = await Task.detached(priority: .userInitiated) { () -> Info in
                    let requested = PendingSettings.requestedWine(for: h)
                    let current = EngineUpdate.current(h)
                    let tag = chosen.isEmpty ? requested ?? current?.tag ?? "" : chosen
                    let target = WineSelection.parse(tag)
                    return Info(requested: requested, current: current,
                                currentText: current?.description ?? h.wineVersion ?? "an unknown version",
                                trial: EngineUpdate.state(for: h),
                                reason: target.flatMap { WineSelection.incompatibility(host: h, target: $0, games: games) },
                                warning: target.flatMap { WindowedPresentation.engineUpdateWarning(host: h, games: games, target: $0) })
                }.value
            }
        }
    }
    func apply() {
        guard let host, reason == nil, target != nil || source != nil else { return }
        let chosenSource = source, chosenTarget = target, games = model.games
        working = true; progress = ""
        Task {
            do {
                let log: @Sendable (String) -> Void = { line in Task { @MainActor in progress = line } }
                var engine = chosenTarget
                if let s = chosenSource {
                    log("Looking for \(s.name)'s newest release…")
                    let r = try await ExternalEngines.latest(s)
                    let id = try await ExternalEngines.install(r, log: log)
                    guard let installed = WineSelection.parse(id), RuntimeManager.manifest(for: id)?.selfTest == true else {
                        throw NokError("\(s.name) was installed but didn't pass the Windows startup check on this Mac, so it can't be used.")
                    }
                    if let problem = WineSelection.incompatibility(host: host, target: installed, games: games) { throw NokError(problem) }
                    engine = installed
                    selected = installed.tag
                }
                guard let engine else { working = false; return }
                let id = try await WineSelection.prepare(engine, catalog: model.catalog, log: log)
                model.changeSetting(for: host, title: "Wine version", success: "Trying \(engine). Play, then Keep or Roll Back.", change: .wine(id),
                                    progress: log, completion: { _ in working = false; progress = "" })
            } catch { model.fail(error); working = false }
        }
    }
}
