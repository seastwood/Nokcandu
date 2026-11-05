import SwiftUI
import NokcanduCore

/// Same verified engine list for game settings, installation defaults and one-install overrides.
struct WineVersionMenu: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: String
    var includeDefault = false
    @State private var versions: [EngineVersion] = [.tested]

    var body: some View {
        Picker("Wine version", selection: $selection) {
            if includeDefault { Text("Default (\(WineSelection.defaultEngine().description))").tag("") }
            ForEach(versions, id: \.self) { version in
                Text(version.description + (EngineSelfTests.failed(WineSelection.spec(for: version).id) ? " — startup check failed" : version == .tested ? " — original tested build" : ""))
                    .tag(version.tag)
                    .disabled(EngineSelfTests.failed(WineSelection.spec(for: version).id))
            }
        }
        .task(id: model.catalog?.checkedAt) {
            let catalog = model.catalog
            var values = await Task.detached(priority: .utility) {
                WineSelection.versions(catalog: catalog, cached: RuntimeManager.cachedRuntimes())
            }.value
            for version in [WineSelection.parse(selection), WineSelection.defaultEngine()].compactMap({ $0 }) where !values.contains(version) { values.append(version) }
            if !Task.isCancelled { versions = values.sorted(by: >) }
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
    var reason: String? { info?.reason }
    var warning: String? { info?.warning }

    var body: some View {
        if let host {
            SettingsSection(title: "Wine") {
                HStack {
                    WineVersionMenu(selection: Binding(get: { shownTag }, set: { selected = $0 }))
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
                    Text("Keep the current trial or roll back before trying another version.").font(.caption).foregroundStyle(.secondary)
                    EngineTrialBanner(game: host, state: trial)
                }
                HStack {
                    Button(working ? "Preparing Wine…" : "Use Selected Wine") {
                        if warning != nil { confirmWarning = true } else { apply() }
                    }
                    .disabled(working || info == nil || target == info?.current || target == nil || reason != nil || info?.trial?.status == .trying)
                    if working { ProgressView().controlSize(.small) }
                }
                if !progress.isEmpty { Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text("Downloads a verified build if needed and keeps the previous engine for Roll Back. Game files and saves stay in place.")
                    .font(.caption).foregroundStyle(.secondary)
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
        guard let host, let target, reason == nil else { return }
        working = true; progress = ""
        Task {
            do {
                let id = try await WineSelection.prepare(target, catalog: model.catalog) { line in
                    Task { @MainActor in progress = line }
                }
                model.changeSetting(for: host, title: "Wine version", success: "Trying \(target). Play, then Keep or Roll Back.", change: .wine(id), completion: { _ in working = false })
            } catch { model.fail(error); working = false }
        }
    }
}
