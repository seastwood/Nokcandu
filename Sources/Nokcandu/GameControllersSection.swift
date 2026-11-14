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
    @State private var allProfiles: [PadProfiles.Profile] = []
    @ObservedObject private var pad = DesktopPad.shared

    var contents: URL? { WineTools.hostContents(for: game) }
    var steam: Bool { contents.map(Controllers.isSteamEnvironment) ?? false }
    var running: Bool { model.isRunning(game) || (contents.map { c in model.games.contains { WineTools.hostContents(for: $0) == c && model.isRunning($0) } } ?? false) }

    var scope: String {
        if game.usesSharedSteam || game.isSteamHost { return "Applies to all Steam games." }
        if game.battleNet != nil || BattleNet.isHost(game) { return "Applies to all Battle.net games." }
        if game.hosted != nil || PCLaunchers.kind(of: game) != nil { return "Applies to all games in this launcher." }
        return "Applies to this game."
    }

    /// The setting's name says where it applies: a Steam, Battle.net or launcher environment is shared by its games.
    var routeTitle: String {
        if game.usesSharedSteam || game.isSteamHost { return "Controllers in Steam games" }
        if game.battleNet != nil || BattleNet.isHost(game) { return "Controllers in Battle.net games" }
        if game.hosted != nil || PCLaunchers.kind(of: game) != nil { return "Controllers in this launcher's games" }
        return "Controllers in this game"
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

    /// The profile this game uses now: one used everywhere wins over the game's own choice.
    var activeProfile: PadProfiles.Profile? {
        guard pad.enabled else { return nil }
        if let id = pad.everywhereID, let p = allProfiles.first(where: { $0.id == id }) { return p }
        return KeyRemap.gameContents(for: game).flatMap { PadProfiles.effective(contents: $0, shared: KeyRemap.isShared(game), all: allProfiles) }
    }
    var usedEverywhere: Bool { pad.enabled && pad.everywhereID != nil && activeProfile?.id == pad.everywhereID }
    var summaryProfile: ControllerSummary.Profile? { activeProfile.map { ControllerSummary.Profile($0, all: allProfiles) } }
    var gamepads: [Controllers.Connected] { connected.filter { $0.isGamepad || $0.isSteamControllerReceiver || ($0.vendorID == 0x28de && $0.productID == 0x1102) } }

    var body: some View {
        SettingsSection(title: "Controllers") {
            SettingRow(title: "This game gets") {
                Text(ControllerSummary.line(controllers: gamepads.map(\.displayName),
                                            steamController: gamepads.contains { $0.vendorID == 0x28de },
                                            mode: mode, steam: steam, profile: summaryProfile, everywhere: usedEverywhere, profilesOff: !pad.enabled))
                    .font(.callout.weight(.medium)).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let p = activeProfile, let type = summaryProfile?.presentAs, mode != .hidden {
                // The profile decides what games see; one place to change it.
                SettingRow(title: routeTitle, info: modeInfo) {
                    Text("\(type.title), set by profile “\(p.name)”").foregroundStyle(.secondary)
                    Button("Change…") { model.sidebarTab = .profiles; model.profileSelection = "pad:" + p.id }
                }
            } else {
                SettingRow(title: routeTitle, info: modeInfo) {
                    Picker(routeTitle, selection: Binding(get: { mode }, set: { choose($0) })) {
                        ForEach(Controllers.Mode.allCases) { m in
                            Text(m == .automatic ? "Automatic (\(steam ? "as themselves in Steam" : "Wine's default"))" : m.title).tag(m)
                        }
                    }
                    .labelsHidden().frame(width: 280)
                    .disabled(working || running)
                }
            }
            if usedEverywhere, let p = activeProfile {
                HStack {
                    SettingNote("“\(p.name)” is being used everywhere, so it replaces this game's own controller profile.")
                    Spacer()
                    Button("Stop Using Everywhere") { pad.everywhereID = nil }
                }
            }
            if running { SettingNote("Quit the game\(steam || game.battleNet != nil || game.hosted != nil ? " and its launcher" : "") to change this.") }
            if connected.isEmpty {
                SettingNote("No controller connected. Plug one in or turn it on (Bluetooth controllers pair in System Settings → Bluetooth).")
            } else {
                ForEach(connected) { c in
                    SettingRow(title: c.displayName + (c.kind == .gamepad ? "" : " · " + c.kind.title)) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(Controllers.describe(c, mode: shownMode, steam: steam, presentAs: summaryProfile?.presentAs))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                                .help("\(c.ids) · \(c.bluetooth ? "Bluetooth" : "USB")")
                            if Controllers.recommendsXbox(c, mode: shownMode, steam: steam, presentAs: summaryProfile?.presentAs) {
                                Button("Use as an Xbox Controller") { choose(.xbox) }.disabled(working || running)
                            }
                        }
                    }
                }
            }
            SettingNote("This is what Nokcandu asks Wine for; it applies from the game's next start\(steam || game.battleNet != nil || game.hosted != nil ? " (quit the launcher too)" : ""). Test Controllers shows what Windows actually sees.")
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
        .onReceive(NotificationCenter.default.publisher(for: .padProfilesChanged)) { _ in load() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in reloadDevices() }
    }

    /// The route as it will apply: a profile's emulated controller needs Wine's conversion.
    var shownMode: Controllers.Mode { summaryProfile?.presentAs != nil && mode == .native ? .xbox : mode }

    func load() {
        allProfiles = PadProfiles.profiles()
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
                mode = m; model.say("\(routeTitle): \(m == .automatic ? "automatic" : m.title.lowercased()) from the next start. \(scope)")
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
