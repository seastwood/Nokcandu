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
    @State private var gpu = SharedSteam.gpuDrawing

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
                Toggle("Smoother Steam windows (GPU drawing)", isOn: Binding(get: { gpu }, set: { gpu = $0; SharedSteam.gpuDrawing = $0
                    model.say("Takes effect when Steam next starts.") }))
                Text("Steam's windows, scrolling and friends list move more smoothly, but Steam then uses the graphics chip alongside the game, which can add a little delay in games. If Steam's windows turn black, switch it off. Takes effect when Steam next starts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Tip(title: "Steam → Settings → In Game → Steam Overlay: off (worth trying)",
                detail: "The overlay draws into the game. Under Wine it can cause stutters or crashes in some games; in others it makes no difference.", done: overlayOff),
            Tip(title: "Steam → Settings → Downloads → Allow downloads during gameplay: off",
                detail: "Off is Steam's default — just check it hasn't been turned on. Downloading and unpacking updates mid-game competes for CPU and disk."),
            Tip(title: "Shader Pre-Caching: only matters if Steam is processing shaders",
                detail: "Steam's pre-cached shaders are for Vulkan/OpenGL; Apple Metal and DXMT build their own. If you see \"Processing Vulkan shaders\" before a game starts, turning it off (Settings → Downloads) skips that work."),
            Tip(title: "Try minimizing Steam's window while playing",
                detail: "Under Wine, Steam's window can keep using CPU while it's visible. Minimize it (yellow button) and compare in Activity Monitor; if it makes no difference on your Mac, don't bother."),
            Tip(title: "Mac: Low Power Mode off",
                detail: "Low Power Mode caps the CPU and GPU (Battery Settings → Low Power Mode → Never, or Only on Battery). On a MacBook Air, being plugged in doesn't make games faster by itself — it just keeps you playing longer.", done: !lowPower),
            Tip(title: "Mac: quit apps that are busy",
                detail: "Idle apps cost little, but busy ones — video, a browser tab doing work, a build — share the CPU, GPU and memory with the game. On a MacBook Air (no fan) they also share its heat budget, so it slows down sooner."),
            Tip(title: "In the game: lower the resolution before lowering everything else",
                detail: "Your screen's full Retina resolution is expensive; a lower one (e.g. 1920×1200, or Game resolution on the game's page) usually gains the most FPS. Vsync off gives the lowest input lag but can tear; turn it on if tearing bothers you. Fullscreen is worth comparing with windowed."),
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
            }.disclosureGroupStyle(WholeRowDisclosureStyle())
            .padding(6)
        }
        .onAppear {
            overlayOff = SharedSteam.overlayDisabled
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// On the EA app / Ubisoft Connect page: games installed in it, each addable as its own app.
struct LauncherGamesSection: View {
    @EnvironmentObject var model: AppModel
    let host: InstalledGame
    let kind: PCLauncher
    @State private var games: [PCLaunchers.HostedGame] = []

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if games.isEmpty {
                    Text("No games installed in \(kind.title) yet. Install one there, then press Refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(games) { hg in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hg.name)
                            Text(hg.installLocation).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let app = PCLaunchers.addedApp(for: hg, kind: kind, in: model.games) {
                            Button("Show") { model.selection = app.id }.buttonStyle(.link)
                            Button("Play") { model.play(app) }
                        } else {
                            Button("Add to Nokcandu") { add(hg) }
                        }
                    }
                }
                Text("Each game gets its own app that opens \(kind.title) (signed in) and starts the game, using this app's graphics and performance settings. \(kind == .ea ? "The EA app runs in Wine with mixed results; if it won't open, try another graphics mode here." : "Games with anti-cheat may not run.")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("\(kind.title) Games").font(.headline)
                Spacer()
                Button("Refresh", action: load).buttonStyle(.link)
            }
        }
        .onAppear(perform: load)
    }

    func load() { games = PCLaunchers.installedGames(kind, host: host) }

    func add(_ hg: PCLaunchers.HostedGame) {
        do {
            let url = try PCLaunchers.addGame(hg, kind: kind, host: host)
            model.refresh(); model.selection = url.path
            model.say("Added \(hg.name). Play starts it through \(kind.title).")
        } catch { model.fail(error) }
    }
}

/// On a launcher's page (Steam, Battle.net, EA app, Ubisoft Connect): let it install games on another drive.
/// Gives the drive a Windows letter inside the launcher; the launcher's own settings then pick it.
struct LauncherDriveBox: View {
    @EnvironmentObject var model: AppModel
    let host: InstalledGame
    let name: String
    @State private var drives: [Drives.Drive] = []
    @State private var message: String?

    var howTo: String {
        switch name {
        case "Steam": "In Steam: Settings → Storage → Add Drive, pick %@, then install games there (or move them with Steam's Move button)."
        case "Battle.net": "In Battle.net: Settings → Downloads → Default Install Directory, choose %@. Existing games can be moved by reinstalling or with Battle.net's \"Locate the game\"."
        case "EA app": "In the EA app: Settings → Download → Download location, choose %@."
        default: "In Ubisoft Connect: Settings → Downloads → Default game installation location, choose %@."
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(drives.filter { !$0.builtIn && !$0.gameDisc }) { d in
                    HStack {
                        Text("\(d.letter):").font(.body.monospaced().bold())
                        Image(systemName: d.connected ? "externaldrive.fill" : "externaldrive.badge.xmark").foregroundStyle(d.connected ? Color.secondary : .orange)
                        Text(d.target).lineLimit(1).truncationMode(.middle).font(.caption)
                        if !d.connected { Text("not connected").font(.caption).foregroundStyle(.orange) }
                    }
                }
                if let message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text("Keep \(name)'s games on an external drive (ExFAT is fine). The drive appears inside \(name) as a drive letter.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Use a Drive for Games…", action: add)
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Game Drives").font(.headline) }
        .onAppear { drives = Drives.list(for: host) }
    }

    func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Games"
        panel.message = "Choose a drive or folder for \(name) games. Picking a whole drive makes a “\(name) Games” folder on it."
        guard panel.runModal() == .OK, var u = panel.url else { return }
        do {
            if (try? u.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true {
                u = u.appendingPathComponent("\(name) Games", isDirectory: true)
                try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            }
            let free = Drives.freeLetters(for: host).filter { $0 != "D" }
            guard let letter = free.first else { throw NokError("No free drive letters left.") }
            try Drives.add(letter, to: u, for: host)
            drives = Drives.list(for: host)
            message = "\(letter): is now \(u.path). " + String(format: howTo, "\(letter):") + " If \(name) is open, quit and reopen it first."
        } catch { message = error.localizedDescription }
    }
}
