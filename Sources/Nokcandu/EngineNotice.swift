import SwiftUI
import NokcanduCore

/// On a game's page: a newer Wine engine is ready to try for it (or for the launcher it runs in).
struct EngineNotice: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    @State private var computed: (latest: EngineVersion, detail: String)?
    var body: some View {
        Group { if let n = computed { content(n) } }
            .task(id: "\(game.id)|\(model.libraryRevision)|\(model.catalog?.latestEngine?.version.description ?? "")") {
                let g = game, games = model.games, cat = model.catalog
                computed = await Task.detached(priority: .utility) { EngineNotice.notice(game: g, games: games, catalog: cat) }.value
            }
    }
    @ViewBuilder func content(_ n: (latest: EngineVersion, detail: String)) -> some View {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(n.latest.description) is available").font(.body.weight(.semibold))
                    Text(n.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Open Updates") { model.showUpdates = true }
            }
            .padding(12)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    nonisolated static func notice(game: InstalledGame, games: [InstalledGame], catalog: UpdateCatalog?) -> (latest: EngineVersion, detail: String)? {
        guard game.native == nil, let cat = catalog, let latest = cat.latestEngine?.version,
              let hostContents = WineTools.hostContents(for: game),
              let host = EngineUpdate.hosts(in: games).first(where: { $0.contents.standardizedFileURL == hostContents.standardizedFileURL }),
              let current = EngineUpdate.current(host), current < latest,
              !EngineUpdate.isHeld(host), EngineUpdate.state(for: host)?.status != .trying else { return nil }
        let id = RuntimeManager.runtimeID(engine: latest, template: cat.latestTemplate?.version ?? .tested)
        if EngineSelfTests.failed(id) { return nil }
        let place = host.contents == game.contents ? "This game" : "\(host.isSteamHost ? "Steam" : host.name), which runs this game,"
        var detail = "\(place) uses \(current.description). Choose a version in the Wine section above, or try the newest from Updates. You can roll back."
        if let w = WindowedPresentation.engineUpdateWarning(host: host, games: games, target: latest) { detail += " " + w }
        return (latest, detail)
    }
}
