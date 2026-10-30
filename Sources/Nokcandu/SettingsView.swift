import GameController
import SwiftUI
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

    var body: some View {
        Form {
            Section("Library") {
                Picker("Sort games by", selection: Binding(get: { model.sortMode }, set: { model.setSort($0) })) {
                    ForEach(LibraryOrganizer.Sort.allCases) { Text($0.title).tag($0) }
                }
                Text("Drag games in the sidebar to put them in your own order; right-click a game to add it to Favorites.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("New games") {
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
            Text("Xbox, PlayStation and Switch Pro controllers work in most Windows games that support controllers — Windows games see them as standard game controllers. If a game ignores yours, check its own controls settings.")
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
