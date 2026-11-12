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
    @State private var inputFix: ControllerHIDFix.State = .unavailable

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
        As itself: request Wine's native device route. A controller appears in Windows only if Wine can detect and open it; this setting does not create a virtual controller. Motion/touch/extra-button support depends on the device, Wine and the target app.

        As an Xbox controller: request Wine's existing Xbox-style conversion for devices it detects; this is not a new macOS virtual device. Motion and extra controls may be unavailable.

        Automatic: request native routing in Steam, and Wine's defaults elsewhere. Steam Input support still requires a controller visible to Steam.

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
                if mode == .native {
                    SettingNote("Your explicit As itself route is preserved. Controller-button remapping and suppression through Nokcandu's SDL profile driver do not apply to that native device route. Mac keyboard/mouse mapping is separate. Choose Automatic or As an Xbox controller if you want Wine's mapped controller outputs.")
                } else {
                    SettingNote("This controller profile requests the SDL/Xbox-style route from the next environment start. Steam Input may remap that output too; compare per-game Steam Input settings if actions duplicate.")
                }
            }
            if running { SettingNote("Quit the game\(steam || game.battleNet != nil || game.hosted != nil ? " and its launcher" : "") to change this.") }
            if connected.isEmpty {
                SettingNote("No controller connected. Plug one in or turn it on (Bluetooth controllers pair in System Settings → Bluetooth).")
            } else {
                ForEach(connected) { c in
                    SettingRow(title: c.displayName + (c.kind == .gamepad ? "" : " · " + c.kind.title)) {
                        Text(Controllers.describe(c, mode: mode, steam: steam))
                            .font(.callout).foregroundStyle(c.isGamepad ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                            .help("\(c.ids) · \(c.bluetooth ? "Bluetooth" : "USB")")
                    }
                }
            }
            SettingNote("The rows above show macOS hardware and requested routing, not confirmation that Windows detected it. If both lists in Test Controllers are empty, check Wine/device access and restart the environment after changing its route.")
            if inputFix != .unavailable {
                SettingRow(title: "Controller input compatibility") {
                    Text(inputFixText).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                }
                if inputFix == .installed || inputFix == .disabled {
                    Button(inputFix == .installed ? "Restore original controller input" : "Enable input correction") {
                        changeInputFix(inputFix == .disabled)
                    }.disabled(working || running)
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
        if let c = contents {
            mode = Controllers.mode(contents: c)
            Task { inputFix = await Task.detached(priority: .utility) { ControllerHIDFix.state(contents: c) }.value }
        }
        reloadDevices()
    }
    func reloadDevices() {
        Task {
            let list = await Task.detached(priority: .utility) { Controllers.connected() }.value
            if list != connected { connected = list }
        }
    }

    var inputFixText: String {
        switch inputFix {
        case .installed: return "Installed. Corrects USB Pro inputs and exposes the original wired Steam Controller’s vendor interface for native access. \(scope)"
        case .pending: return "Applies at the next start while the environment is closed. \(scope)"
        case .disabled: return "Original driver restored; automatic correction is off. \(scope)"
        case .modified: return "Unrecognized or edited driver preserved. No automatic correction was made."
        case .unavailable: return ""
        }
    }
    func changeInputFix(_ on: Bool) {
        guard let c = contents else { return }
        working = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try ControllerHIDFix.setEnabled(on, contents: c) } }.value
            switch r {
            case .success: model.say(on ? "Controller input correction enabled for the next start." : "Original controller driver restored for the next start.")
            case .failure(let e): model.fail(e)
            }
            working = false; load()
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
