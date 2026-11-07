import GameController
import SwiftUI
import ServiceManagement
import AppKit
import NokcanduCore

/// Nokcandu ▸ Settings… (⌘,) and the gear above the games list: everything about Nokcandu itself,
/// as opposed to a single game.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            StorageView(embedded: true).tabItem { Label("Storage", systemImage: "internaldrive") }.tag("storage")
            AccountsSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag("accounts")
            UpdatesView(embedded: true)
                .tabItem { Label(model.updateCount > 0 ? "Updates (\(model.updateCount))" : "Updates", systemImage: "arrow.down.circle") }
                .tag("updates")
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag("advanced")
            CreditsSettings().tabItem { Label("Credits", systemImage: "heart") }.tag("credits")
        }
        .frame(width: 780, height: 640)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var installTo = GameFolders.installFolder
    @State private var discordTick = 0

    var body: some View {
        Form {
            Section("Library") {
                Picker("Sort games by", selection: Binding(get: { model.sortMode }, set: { model.setSort($0) })) {
                    ForEach(LibraryOrganizer.Sort.allCases) { Text($0.title).tag($0) }
                }
                Text("Drag games in the sidebar to put them in your own order; right-click a game to add it to Favorites.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Ask before quitting a game", isOn: Binding(get: { !model.quitWithoutAsking }, set: { model.quitWithoutAsking = !$0 }))
                Text("Quitting a game loses unsaved progress. Launchers with no game running in them always quit without asking.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show Nokcandu in the menu bar", isOn: Binding(get: { MenuBarSetting.on }, set: { UserDefaults.standard.set($0, forKey: MenuBarSetting.key); model.objectWillChange.send() }))
                Text("Running games with Quit, recent games with Play, and the way back to your library. Nokcandu keeps running in the menu bar when you close its window.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mac notifications while Nokcandu is in the background", isOn: Binding(get: { Notifier.enabled }, set: { Notifier.enabled = $0; model.objectWillChange.send() }))
                Text("When a store game is added, a game doesn't start, or a game is running low on memory. Click one to open that game.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Lower store apps' priority while a game is in front", isOn: Binding(
                    get: { !FileManager.default.fileExists(atPath: NokPaths.support.appendingPathComponent("launchers-normal-priority").path) },
                    set: { on in
                        let f = NokPaths.support.appendingPathComponent("launchers-normal-priority")
                        if on { try? FileManager.default.removeItem(at: f) } else { try? NokPaths.ensure(NokPaths.support); FileManager.default.createFile(atPath: f.path, contents: Data()) }
                        model.objectWillChange.send()
                    }))
                Text("Steam, Battle.net, the EA app and Ubisoft Connect keep running (downloads, sign-in, friends) but stop competing with the game for the processor until you switch to them. Games also ask macOS for its fastest cores.")
                    .font(.caption).foregroundStyle(.secondary)
                NetworkSteadySetting()
                Toggle("Take a restore point before big changes", isOn: Binding(get: { RestorePoints.automaticChosen }, set: { RestorePoints.automaticChosen = $0; model.objectWillChange.send() }))
                Text("Before a fix, an engine change or Reset to Recommended, keeps one copy of the game's Windows environment to go back to (the newest replaces the last). Off by default: those changes have their own Undo, and you can take a restore point yourself any time in a game's Storage tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DesktopPadSettings()
            Section("Discord") {
                Toggle("Show what you're playing in Discord", isOn: Binding(get: { DiscordBridge.enabled }, set: { DiscordBridge.enabled = $0; discordTick += 1 }))
                Text("Windows games that support Discord Rich Presence show up in your Discord status. Nokcandu adds a small bridge (rpc-bridge, the one Sikarugir uses) to each game's Windows environment the next time it starts; turning this off removes it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .id(discordTick)
            }
            Section("New games") {
                DefaultWineSetting()
                InstallFolderPicker(folder: $installTo)
                Text("Where installs go unless you choose otherwise. Manage folders and drives under Storage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: AppUpdate.currentVersion)
                if let r = model.appUpdate {
                    LabeledContent("Available") {
                        Button("Nokcandu \(r.version) — see Updates") { UserDefaults.standard.set("updates", forKey: "settingsTab") }
                    }
                }
                HStack {
                    Button("Setup Checklist…") { model.showWelcome = true }
                    Button("Nokcandu on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/seastwood/Nokcandu")!) }
                    Button("Report a Problem") { NSWorkspace.shared.open(URL(string: "https://github.com/seastwood/Nokcandu/issues/new")!) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var tick = 0

    var body: some View {
        Form {
            Section("Steam") {
                if let a = SharedSteam.accounts().first {
                    LabeledContent("Signed in", value: a.personaName.isEmpty ? a.accountName : "\(a.personaName) (\(a.accountName))")
                } else {
                    Text(SharedSteam.isSetUp ? "Steam is set up; sign in inside Steam." : "Steam isn't set up yet.").foregroundStyle(.secondary)
                }
                Button("Open Steam Library…") { model.showSteamLibrary = true; NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
            }
            Section("GOG, Epic & Amazon") {
                ForEach(Store.allCases) { s in
                    HStack {
                        Image(systemName: s.symbol)
                        Text(s.title)
                        Spacer()
                        let _ = tick
                        if StoreAccounts.isSignedIn(s) {
                            Text("Signed in").foregroundStyle(.secondary)
                            Button("Sign Out") { Task { await StoreAccounts.signOut(s); tick += 1 } }
                        } else {
                            Text("Not signed in").foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Open Store Library…") { model.openStores() }
                Text("Sign-ins are kept in Nokcandu's own folder and used only by the open-source store clients (gogdl, Legendary, nile).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var caches: [Caches.Cache] = []
    @State private var loading = true
    @State private var gameApps = GameApp.enabled
    @State private var cloudSaves = CloudSaves.enabled

    var body: some View {
        Form {
            Section {
                Toggle("Sync Epic cloud saves", isOn: Binding(get: { cloudSaves }, set: { cloudSaves = $0; CloudSaves.enabled = $0 }))
            } header: { Text("Cloud saves") } footer: {
                Text("For games installed from Epic: a newer cloud save is downloaded before the game starts, and your save is uploaded after it quits. The newer save always wins. (Steam games sync through Steam. GOG cloud saves aren't supported yet.)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ControllersSection()
            Section {
                Toggle("Run games as their own apps", isOn: Binding(get: { gameApps }, set: { on in
                    gameApps = on; GameApp.enabled = on
                    let games = model.games
                    Task.detached(priority: .utility) { RawMouse.refreshLibraries(games) }
                    model.say(on ? "Games will show under their own names from their next start." : "Games will run as plain Wine from their next start.")
                }))
            } header: { Text("Dock names and Game Mode") } footer: {
                Text("Each game runs inside a small app named after it, so the Dock, Cmd-Tab and Activity Monitor show its name, and macOS turns on Game Mode when it's full screen. Switch off if a game misbehaves; takes effect the next time a game (or Steam) starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if loading { ProgressView().controlSize(.small) }
                if !loading && caches.isEmpty { Text("No shader caches yet.").foregroundStyle(.secondary) }
                ForEach(caches) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Storage.format(c.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button("Clear") {
                            do { try Caches.clear(c); model.say("Cleared \(c.title).") } catch { model.fail(error) }
                            load()
                        }
                    }
                }
            } header: { Text("Shader caches") } footer: {
                Text("Compiled graphics shaders, kept so games don't stutter. On a Mac the cache is shared by all Wine games, not per game. Clearing is safe — the next play stutters a little while it rebuilds. Useful after a graphics driver/macOS update if a game shows glitches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Logs") {
                HStack {
                    Text("Each game keeps logs of its last run (used by Diagnostics and fixes).")
                    Spacer()
                    Button("Clear All Logs") { let n = Storage.clearLogs(model.games); model.say("Cleared \(Storage.format(n)) of logs.") }
                }
            }
            Section("Folders") {
                HStack {
                    Button("Nokcandu's Data") { NSWorkspace.shared.open(NokPaths.support) }
                    Button("Store Clients") { try? NokPaths.ensure(StoreTools.dir); NSWorkspace.shared.open(StoreTools.dir) }
                    Button("Standard Game Folder") { NSWorkspace.shared.open(NokPaths.gameAppsFolder) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    func load() {
        loading = true
        let g = model.games
        Task {
            caches = await Task.detached(priority: .utility) { Caches.metal() }.value
            let more = await Task.detached(priority: .utility) { Caches.others(g) }.value
            caches += more
            loading = false
        }
    }
}



/// Game controllers macOS sees right now (Wine's games see the same ones).
struct ControllersSection: View {
    @State private var pads: [String] = []
    var body: some View {
        Section {
            if pads.isEmpty {
                Text("No controller connected. Pair one in System Settings → Bluetooth, or plug it in.").foregroundStyle(.secondary)
            }
            ForEach(pads, id: \.self) { p in Label(p, systemImage: "gamecontroller.fill") }
        } header: { Text("Controllers") } footer: {
            Text("Xbox, PlayStation, Switch and other controllers work in Windows games that support controllers. Whether a game sees a controller as itself (gyro, touchpad, every button) or as an Xbox controller is chosen per game in its Controls tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reload() }
    }
    func reload() {
        GCController.startWirelessControllerDiscovery {}
        pads = GCController.controllers().map { c in
            let kind = c.extendedGamepad != nil ? "full gamepad" : c.microGamepad != nil ? "simple gamepad" : "controller"
            let battery = c.battery.map { " · battery \(Int($0.batteryLevel * 100))%" } ?? ""
            return "\(c.vendorName ?? "Controller") (\(kind))\(battery)"
        }
    }
}


/// Settings → General: steadier Wi-Fi while playing (a small system helper switches AWDL off during games).
struct NetworkSteadySetting: View {
    @State private var installed = NetworkSteady.installed
    @State private var enabled = NetworkSteady.enabled
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Toggle("Steadier Wi-Fi while playing", isOn: Binding(get: { installed && enabled }, set: { on in
            if on && !installed { install() } else { NetworkSteady.enabled = on; enabled = on }
        }))
        .disabled(working)
        Text("Turns off AWDL — the wireless link AirDrop, AirPlay, Sidecar and Universal Control use — while a game runs, and back on when it stops. It makes Wi-Fi hop channels every few seconds, which shows up as lag spikes online. Needs a small helper, installed once with your password\(installed ? "" : " when you turn this on"). A wired connection avoids the spikes altogether.")
            .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        if installed {
            Button("Remove the Wi-Fi Helper…") { uninstall() }.buttonStyle(.link).font(.caption).disabled(working)
        }
    }

    func install() {
        working = true; error = nil
        Task.detached {
            let r = Result { try NetworkSteady.install() }
            await MainActor.run {
                working = false
                installed = NetworkSteady.installed
                if case .failure(let e) = r, e.localizedDescription != "Cancelled." { error = e.localizedDescription }
                if installed { NetworkSteady.enabled = true; enabled = true }
            }
        }
    }
    func uninstall() {
        working = true; error = nil
        Task.detached {
            let r = Result { try NetworkSteady.uninstall() }
            await MainActor.run {
                working = false
                installed = NetworkSteady.installed
                if case .failure(let e) = r, e.localizedDescription != "Cancelled." { error = e.localizedDescription }
            }
        }
    }
}


/// Settings → General → Controller on the Mac: a controller profile for the Mac itself and per-app choices.
struct DesktopPadSettings: View {
    @ObservedObject var pad = DesktopPad.shared
    @Environment(\.openWindow) private var openWindow
    @State private var profiles = PadProfiles.profiles()

    var body: some View {
        Section("Controller on the Mac") {
            Toggle("Controller profiles", isOn: $pad.enabled)
            Text("Off turns every controller profile off — in games and on the Mac — so controllers work as they are.").font(.caption).foregroundStyle(.secondary)
            Toggle("Use a controller profile on the Mac", isOn: $pad.on).disabled(!pad.enabled)
            Text("Move the pointer, click and type with your controller in any app — to pick a game, browse, or play Mac games and others that don't support controllers. Nokcandu games use the profile chosen on their Controls tab instead, and apps set to Off below are left alone. Buttons set to controller buttons only change anything inside Windows games.")
                .font(.caption).foregroundStyle(.secondary)
            if pad.on {
                LabeledContent("Now") { Text(pad.status).foregroundStyle(pad.status.hasPrefix("Needs") ? .orange : .secondary) }
                if !pad.trusted {
                    HStack {
                        Text("macOS needs to let Nokcandu control the pointer and keyboard (Privacy & Security → Accessibility).").font(.caption)
                        Button("Allow…") { pad.askForAccess() }
                    }
                }
                Picker("Profile", selection: Binding(get: { pad.profileID ?? "" }, set: { pad.profileID = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(profiles) { p in Text(p.name).tag(p.id) }
                }
                HStack {
                    if let id = pad.profileID, profiles.contains(where: { $0.id == id }) {
                        Button("Edit Profile…") { openWindow(id: "padprofile", value: PadEditorTarget(gameID: "", profileID: id)) }
                    }
                    Menu("New From") {
                        ForEach(PadProfiles.starters()) { s in Button(s.name) { adopt(s) } }
                        Button("Pointer and Clicks") { adopt(PadProfiles.desktopStarter()) }
                    }.fixedSize()
                }
                ForEach(pad.rules.keys.sorted(), id: \.self) { bundle in
                    LabeledContent(appName(bundle)) {
                        HStack {
                            Picker("", selection: Binding(get: { pad.rules[bundle] ?? "off" }, set: { pad.rules[bundle] = $0 })) {
                                Text("Off").tag("off")
                                ForEach(profiles) { p in Text(p.name).tag(p.id) }
                            }.labelsHidden().frame(width: 180)
                            Button { pad.rules[bundle] = nil } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove")
                        }
                    }
                }
                Toggle("Show a note when a layer or the gyro switches", isOn: Binding(get: { PadHUD.enabled }, set: { PadHUD.enabled = $0; pad.objectWillChange.send() }))
                Button("Add an App…") { addApp() }
                Toggle("Open Nokcandu at login, in the menu bar", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                    if on { try? SMAppService.mainApp.register(); UserDefaults.standard.set(true, forKey: MenuBarSetting.key) } else { try? SMAppService.mainApp.unregister() }
                    pad.objectWillChange.send()
                }))
                .help("So your controller works on the Mac from the moment you sign in, without opening Nokcandu.")
                    .help("Choose an app to give its own profile, or to turn the controller profile off in (for example games with their own controller support).")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .padProfilesChanged)) { _ in profiles = PadProfiles.profiles() }
        .onAppear { profiles = PadProfiles.profiles(); DesktopPad.shared.start() }
    }

    func appName(_ bundle: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
    }
    func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.prompt = "Choose"
        if p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier { pad.rules[id] = "off" }
    }
    func adopt(_ starter: PadProfiles.Profile) {
        var p = starter; p.id = UUID().uuidString
        var n = p.name, i = 2
        while profiles.contains(where: { $0.name == n }) { n = "\(p.name) \(i)"; i += 1 }
        p.name = n
        try? PadProfiles.store(p, environments: [])
        profiles = PadProfiles.profiles()
        pad.profileID = p.id
        openWindow(id: "padprofile", value: PadEditorTarget(gameID: "", profileID: p.id))
    }
}
