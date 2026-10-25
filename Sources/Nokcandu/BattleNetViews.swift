import SwiftUI
import NokcanduCore

/// On the Battle.net app's page: Blizzard games installed in it, each addable as its own app.
struct BlizzardGamesSection: View {
    @EnvironmentObject var model: AppModel
    let host: InstalledGame
    @State private var games: [BattleNet.BlizzardGame] = []

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if games.isEmpty {
                    Text("No Blizzard games installed yet. Install one in Battle.net, then come back here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(games) { bg in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bg.name)
                            Text(bg.installLocation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let app = BattleNet.addedApp(for: bg, in: model.games) {
                            Button("Show") { model.selection = app.id }.buttonStyle(.link)
                            Button("Play") { model.play(app) }
                        } else {
                            Button("Add to Nokcandu") { add(bg) }
                        }
                    }
                }
                Text("Each game gets its own app that opens Battle.net (signed in) and starts the game. They use this app's Graphics, Performance, Mouse and extra settings — e.g. Apple Metal and ROSETTA_ADVERTISE_AVX for Diablo II: Resurrected.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Blizzard Games").font(.headline) }
        .onAppear { games = BattleNet.installedGames(host: host) }
    }

    func add(_ bg: BattleNet.BlizzardGame) {
        do {
            let url = try BattleNet.addGame(bg, host: host)
            model.refresh()
            model.selection = url.path
            model.say("Added \(bg.name). Play starts it through Battle.net.")
        } catch { model.fail(error) }
    }
}

/// On a Blizzard game's page: where its settings live.
struct BattleNetGameInfo: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    var body: some View {
        GroupBox {
            HStack(alignment: .top) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text("Starts through Battle.net (launch code \(game.battleNet?.code ?? "?")). If Battle.net isn't open it opens it first and waits until you're signed in. Graphics, performance and raw-mouse settings come from the Battle.net app.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let h = model.games.first(where: { $0.appURL.path == game.battleNet?.hostApp }) {
                    Button("Battle.net Settings") { model.selection = h.id }
                }
            }
            .padding(6)
        } label: { Text("Battle.net").font(.headline) }
    }
}

/// On the Steam app's page: games installed in the shared Steam, each addable as its own app.
struct SteamGamesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var games: [SharedSteam.LibraryGame] = []
    @State private var adding: Int?

    /// Steam's own runtimes and redistributables aren't games.
    static let notGames: Set<Int> = [228980, 1070560, 1391110, 1628350, 1493710]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if games.isEmpty {
                    Text("No games installed in Steam yet. Install one in Steam, then come back here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(games) { sg in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sg.name)
                            Text(sg.installed ? (sg.sizeOnDisk.map { Storage.format($0) } ?? "Installed") : "Downloading in Steam…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let app = model.games.first(where: { $0.custom?.steamAppID == sg.appID }) {
                            Button("Show") { model.selection = app.id }.buttonStyle(.link)
                            Button("Play") { model.play(app) }
                        } else if adding == sg.appID {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Add to Nokcandu") { add(sg) }.disabled(!sg.installed)
                        }
                    }
                }
                Text("Each game gets its own app with its icon; Play starts it through this shared Steam. Steam games share Steam's Mouse and Performance settings; graphics is chosen per game.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Steam Games").font(.headline)
                Spacer()
                Button("Refresh", action: load).buttonStyle(.link)
            }
        }
        .onAppear(perform: load)
    }

    func load() {
        games = SharedSteam.installedGames().filter { !Self.notGames.contains($0.appID) }.sorted { $0.name < $1.name }
    }

    func add(_ sg: SharedSteam.LibraryGame) {
        adding = sg.appID
        Task {
            let r = await Task.detached { Result { try SharedSteam.addGame(sg) } }.value
            adding = nil
            switch r {
            case .success(let url): model.refresh(); model.selection = url.path; model.say("Added \(sg.name). Play starts it through Steam.")
            case .failure(let e): model.fail(e)
            }
        }
    }
}
