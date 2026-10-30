import SwiftUI
import NokcanduCore

/// On a game's page: a newer Wine engine is ready to try for it (or for the launcher it runs in).
struct EngineNotice: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    var body: some View {
        if let n = notice {
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
    }

    var notice: (latest: EngineVersion, detail: String)? {
        guard game.native == nil, let cat = model.catalog, let latest = cat.latestEngine?.version,
              let hostContents = WineTools.hostContents(for: game),
              let host = EngineUpdate.hosts(in: model.games).first(where: { $0.contents.standardizedFileURL == hostContents.standardizedFileURL }),
              let current = EngineUpdate.current(host), current < latest,
              !EngineUpdate.isHeld(host), EngineUpdate.state(for: host)?.status != .trying else { return nil }
        let id = RuntimeManager.runtimeID(engine: latest, template: cat.latestTemplate?.version ?? .tested)
        if EngineSelfTests.failed(id) { return nil }
        let place = host.contents == game.contents ? "This game" : "\(host.isSteamHost ? "Steam" : host.name), which runs this game,"
        var detail = "\(place) uses \(current.description). Try the new engine from Updates; you can roll back."
        if let w = WindowedPresentation.engineUpdateWarning(host: host, games: model.games, target: latest) { detail += " " + w }
        return (latest, detail)
    }
}
