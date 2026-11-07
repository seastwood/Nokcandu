import SwiftUI
import NokcanduCore

/// Controls → Controllers: what's plugged in, and whether each reaches Windows programs as itself or as an
/// Xbox controller. The choice belongs to the game's Windows environment.
struct GameControllersSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var connected: [Controllers.Connected] = []
    @State private var mode: Controllers.Mode = .automatic
    @State private var working = false

    var contents: URL? { WineTools.hostContents(for: game) }
    var steam: Bool { contents.map(Controllers.isSteamEnvironment) ?? false }
    var running: Bool { model.isRunning(game) || (contents.map { c in model.games.contains { WineTools.hostContents(for: $0) == c && model.isRunning($0) } } ?? false) }

    var scope: String {
        if game.usesSharedSteam || game.isSteamHost { return "Applies to all Steam games." }
        if game.battleNet != nil || BattleNet.isHost(game) { return "Applies to all Battle.net games." }
        if game.hosted != nil || PCLaunchers.kind(of: game) != nil { return "Applies to all games in this launcher." }
        return "Applies to this game."
    }

    var modeInfo: String {
        """
        As itself: Windows sees the real controller — a Switch Pro Controller as a Switch Pro Controller, a DualSense as a DualSense — with gyro, touchpad and every button. Only games and apps that support that controller can use it; Steam's own controller support (Steam Input) does, for every Steam game.

        As an Xbox controller: every game understands it, but gyro, touchpads and extra buttons are lost.

        Automatic: as itself in Steam (Steam Input takes care of it); elsewhere PlayStation controllers as themselves and others as Xbox controllers.

        Not at all: Windows programs don't see controllers or joysticks — for games played with a controller profile that turns buttons into keys and mouse.

        \(scope) Takes effect the next time the game or launcher starts.
        """
    }

    var body: some View {
        SettingsSection(title: "Controllers") {
            SettingRow(title: "Controllers reach games", info: modeInfo) {
                Picker("Controllers reach games", selection: Binding(get: { mode }, set: { choose($0) })) {
                    ForEach(Controllers.Mode.allCases) { m in
                        Text(m == .automatic ? "Automatic (\(steam ? "as themselves in Steam" : "Wine's default"))" : m.title).tag(m)
                    }
                }
                .labelsHidden().frame(width: 280)
                .disabled(working || running)
            }
            if let g = KeyRemap.gameContents(for: game), PadProfiles.effective(contents: g, shared: KeyRemap.isShared(game)) != nil, mode != .hidden {
                SettingNote("This game uses a controller profile: it gets the controller as an Xbox controller with the profile applied, and buttons set to keys or mouse don't reach it as controller buttons (from the next start of \(steam ? "Steam" : "the game")).\(steam ? " Turn off Steam Input for the game (its Properties → Controller) so Steam doesn't remap the controller as well." : "")")
            }
            if running { SettingNote("Quit the game\(steam || game.battleNet != nil || game.hosted != nil ? " and its launcher" : "") to change this.") }
            if connected.isEmpty {
                SettingNote("No controller connected. Plug one in or turn it on (Bluetooth controllers pair in System Settings → Bluetooth).")
            } else {
                ForEach(connected) { c in
                    SettingRow(title: c.name + (c.kind == .gamepad ? "" : " · " + c.kind.title)) {
                        Text(Controllers.describe(c, mode: mode, steam: steam))
                            .font(.callout).foregroundStyle(c.isGamepad ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                            .help("\(c.ids) · \(c.bluetooth ? "Bluetooth" : "USB")")
                    }
                }
            }
            HStack {
                Button("Test Controllers…") { test() }
                    .help("Opens Windows' Game Controllers panel in this environment: it lists what Windows sees and shows buttons, sticks and triggers live.")
                Button("Refresh") { load() }.buttonStyle(.link)
            }
        }
        .onAppear { load() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in reloadDevices() }
    }

    func load() {
        if let c = contents { mode = Controllers.mode(contents: c) }
        reloadDevices()
    }
    func reloadDevices() {
        Task {
            let list = await Task.detached(priority: .utility) { Controllers.connected() }.value
            if list != connected { connected = list }
        }
    }

    func choose(_ m: Controllers.Mode) {
        guard let c = contents, m != mode else { return }
        working = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try Controllers.set(m, contents: c) } }.value
            switch r {
            case .success:
                ChangeHistory.note(game, "Controllers: \(m.title.lowercased())", undo: .setting(GameDetailView.Tab.controls.rawValue))
                mode = m; model.say("Controllers reach games \(m == .automatic ? "automatically" : m.title.lowercased()) from the next start.")
            case .failure(let e): model.fail(e)
            }
            working = false
        }
    }

    func test() {
        do { try WineTools.run(["control", "joy.cpl"], for: game); model.say("Opening Game Controllers… Buttons and sticks light up as you press them.") }
        catch { model.fail(error) }
    }
}
