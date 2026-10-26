import SwiftUI
import NokcanduCore

/// On the Battle.net app's page: Blizzard games installed in it, each addable as its own app.
struct BlizzardGamesSection: View {
    @EnvironmentObject var model: AppModel
    let host: InstalledGame
    @State private var games: [BattleNet.BlizzardGame] = []
    @State private var closes = true

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
                Toggle("Close Battle.net when its game quits", isOn: Binding(get: { closes }, set: { closes = $0; BattleNet.setClosesWithGame($0, host: host) }))
                Text("Battle.net opened by a game closes about 30 seconds after that game quits, so the next game starts it fresh with its own settings. Battle.net you open yourself stays open.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Each game gets its own app that opens Battle.net (signed in) and starts the game. They use this app's Graphics, Performance, Mouse and extra settings — e.g. Apple Metal and ROSETTA_ADVERTISE_AVX for Diablo II: Resurrected.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Blizzard Games").font(.headline) }
        .onAppear { games = BattleNet.installedGames(host: host); closes = BattleNet.closesWithGame(host: host) }
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
    @State private var closes = SharedSteam.closesWithGame

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
                Toggle("Close Steam when its game quits", isOn: Binding(get: { closes }, set: { closes = $0; SharedSteam.closesWithGame = $0 }))
                Text("Steam opened by a game closes about 30 seconds after that game quits, so the next game starts Steam fresh with its own graphics settings. Steam you open yourself (Open Steam) stays open.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

/// Things only you can change (Steam's own settings and your Mac's), shown on the Steam page and on
/// every Steam game's page. Checks what it can and marks it.
struct SteamTipsSection: View {
    @State private var expanded = false
    @State private var overlayOff: Bool?
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    struct Tip: Identifiable { let id = UUID(); let title: String; let detail: String; var done: Bool? = nil }

    var tips: [Tip] {
        [
            Tip(title: "Steam → Settings → In Game → Steam Overlay: off",
                detail: "The overlay hooks into the game's graphics, which costs frame rate and can cause stutters under Wine.", done: overlayOff),
            Tip(title: "Steam → Settings → Downloads → Allow downloads during gameplay: off",
                detail: "Updates downloading and unpacking in the background take CPU and disk while you play."),
            Tip(title: "Steam → Settings → Downloads → Shader Pre-Caching: off",
                detail: "It's for Vulkan games; it doesn't help Apple Metal, but its background work still uses CPU."),
            Tip(title: "Minimize Steam's window while playing",
                detail: "Steam's window is drawn in software under Wine and can use a whole CPU core while it's on screen; minimized (yellow button), it mostly idles. Steam closes after the game unless you opened it yourself."),
            Tip(title: "Mac: plugged in, Low Power Mode off",
                detail: "Low Power Mode caps the CPU and GPU. Battery Settings → Low Power Mode → Never (or Only on Battery).", done: !lowPower),
            Tip(title: "Mac: quit browsers and other heavy apps",
                detail: "Especially on a MacBook Air (no fan): everything running shares the same heat budget as the game."),
            Tip(title: "In the game: fullscreen at your screen's resolution, vsync off",
                detail: "For shooters, Low-latency aiming and the frame cap (Performance, on the game's page) set this up."),
        ]
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tips) { t in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: t.done == true ? "checkmark.circle.fill" : t.done == false ? "exclamationmark.circle" : "circle")
                                .foregroundStyle(t.done == true ? .green : t.done == false ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.callout)
                                Text(t.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("These are Steam's and your Mac's own settings, so Nokcandu can't change them for you. ✓ means Nokcandu checked it's already done.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text("Performance tips for Steam games").font(.headline)
            }
            .padding(6)
        }
        .onAppear {
            overlayOff = SharedSteam.overlayDisabled
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}
