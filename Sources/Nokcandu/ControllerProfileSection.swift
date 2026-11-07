import SwiftUI
import NokcanduCore

/// Controls → Controller Profile: what the controller's buttons, sticks, triggers and gyro do in this game.
/// Profiles are shared like keyboard layouts (one can be the default for every game) and can build on each other.
struct ControllerProfileSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var profiles: [PadProfiles.Profile] = []
    @State private var choice: PadProfiles.Choice = .followDefault
    @State private var defaultID: String?
    @Environment(\.openWindow) private var openWindow
    @State private var naming: Naming?
    @State private var name = ""

    enum Naming: Identifiable { case new, rename, duplicate; var id: Int { hashValue } }

    var contents: URL? { KeyRemap.gameContents(for: game) }
    var shared: Bool { KeyRemap.isShared(game) }
    var launcher: String { StartupMonitor.storeName(game) }
    var defaultProfile: PadProfiles.Profile? { profiles.first { $0.id == defaultID } }
    var shownProfile: PadProfiles.Profile? {
        switch choice {
        case .profile(let id): return profiles.first { $0.id == id }
        case .followDefault: return defaultProfile
        case .own: return contents.flatMap { PadProfiles.own(contents: $0) }
        default: return nil
        }
    }
    var tag: String {
        switch choice { case .followDefault: "default"; case .normal: "none"; case .own: "own"; case .profile(let id): id; case .sameAsLauncher: "launcher" }
    }
    var allEnvironments: [URL] { KeyRemap.environments(model.games) + (shared ? [] : contents.map { [$0] } ?? []) }
    var sharedFolders: [URL] { KeyRemap.sharedFolders(model.games) + (shared ? contents.map { [$0] } ?? [] : []) }

    static let info = """
    Change what any button, trigger, stick or the gyro does in this game: a button can press a key, a mouse button, another controller button or a combination (Shift+R), and do different things on a tap, a hold or a double tap, or when pressed together with another button. Sticks can be a mouse, flick stick or keys; the gyro can aim like a mouse or move a stick.

    Layers: while a button is held (or after it's pressed once), other buttons do something else.

    Profiles are shared: changing one changes every game using it, and one can be the default for all games. A profile can build on others — anything it doesn't set comes from them.

    Nokcandu applies the profile while the game is in front — keys and clicks as a real keyboard and mouse, movement straight into the game. “Controller as it is” leaves the controller to the game's own controls. Changes apply on the next press, even while playing. All profiles are also in the sidebar's Profiles tab.
    """

    var body: some View {
        SettingsSection(title: "Controller Profile", info: Self.info) {
            SettingRow(title: "Profile") {
                Picker("Profile", selection: Binding(get: { tag }, set: choose)) {
                    if shared { Text("Same as \(launcher)").tag("launcher") }
                    Text("Default (\(defaultProfile?.name ?? "controller as it is"))").tag("default")
                    Text("Controller as it is (the game's own controls)").tag("none")
                    if choice == .own { Text("Just for this game").tag("own") }
                    if !profiles.isEmpty { Divider() }
                    ForEach(profiles) { p in Text(p.name + (p.id == defaultID ? " (default)" : "")).tag(p.id) }
                }
                .labelsHidden().frame(width: 240)
                menu
            }
            if let p = shownProfile {
                SettingNote(summary(p))
                if game.native != nil {
                    SettingNote("A Mac game sees the controller itself too, so buttons set to keys or mouse also do their own thing in the game. Best for games without controller support, or with theirs turned off. Buttons set to other controller buttons don't change anything in Mac games.")
                }
                HStack {
                    Button("Edit \(choice == .own ? "This Game's Profile" : p.name)…") {
                        if choice == .own { edit(p, own: true) } else { model.sidebarTab = .profiles; model.profileSelection = "pad:" + p.id }
                    }
                    if choice == .followDefault { Text("Editing changes the default for every game using it.").font(.caption).foregroundStyle(.secondary) }
                }
            } else if choice == .sameAsLauncher {
                SettingNote("Uses \(launcher)'s controller profile (set on \(launcher)'s page). Choose something else to give \(game.name) its own.")
            } else {
                SettingNote(choice == .followDefault ? "No default profile yet: controllers work as they are. Make one from the ⋯ menu." : "Controllers work as they are.")
                HStack {
                    Button("New Profile…") { name = ""; naming = .new }
                    Menu("Start From") { starters }.fixedSize()
                }
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .padProfilesChanged)) { _ in load() }
        .alert(naming == .rename ? "Rename Profile" : "New Controller Profile", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button(naming == .rename ? "Rename" : "Create") { finishNaming() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text(naming == .rename ? "Games using it keep using it." : naming == .duplicate ? "A copy you can change without changing the original." : "Any game can then choose it.")
        }
    }

    @ViewBuilder var starters: some View {
        ForEach(PadProfiles.starters()) { s in Button(s.name) { adopt(s) } }
    }

    @ViewBuilder var menu: some View {
        Menu {
            Button("New Profile…") { name = ""; naming = .new }
            Menu("New From") { starters }
            if let p = shownProfile, choice != .own {
                Divider()
                if p.id == defaultID { Button("Stop Using \(p.name) as the Default") { makeDefault(nil) } }
                else { Button("Set \(p.name) as Default") { makeDefault(p) } }
                Button("Rename \(p.name)…") { name = p.name; naming = .rename }
                Button("Duplicate \(p.name)…") { name = p.name + " copy"; naming = .duplicate }
                Button("Copy to This Game Only") { makeOwn(from: p) }
                Button("Delete \(p.name)", role: .destructive) { delete(p) }
            } else if let p = shownProfile, choice == .own {
                Divider()
                Button("Save as Shared Profile…") { name = p.name == "This game" ? game.name : p.name; naming = .duplicate }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Profile options").help("Controller profiles")
    }

    func summary(_ p: PadProfiles.Profile) -> String {
        let m = PadProfiles.merged(p, all: profiles)
        var parts: [String] = []
        let changed = m.layers.first?.bindings.count ?? 0
        if changed > 0 { parts.append("\(changed) button\(changed == 1 ? "" : "s") changed") }
        if m.layers.count > 1 { parts.append("\(m.layers.count - 1) layer\(m.layers.count == 2 ? "" : "s")") }
        if m.gyro.output != .off { parts.append("gyro: \(m.gyro.output.title.lowercased())") }
        if m.left.mode != .stick { parts.append("left stick: \(m.left.mode.title.lowercased())") }
        if m.right.mode != .stick { parts.append("right stick: \(m.right.mode.title.lowercased())") }
        let under = p.buildsOn.compactMap { id in profiles.first { $0.id == id }?.name }
        if !under.isEmpty { parts.append("builds on " + under.joined(separator: ", ")) }
        return parts.isEmpty ? "Nothing changed yet." : parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst()
    }

    func load() {
        guard let c = contents else { return }
        profiles = PadProfiles.profiles()
        defaultID = PadProfiles.defaultID()
        choice = PadProfiles.choice(contents: c, shared: shared)
        if case .profile(let id) = choice, !profiles.contains(where: { $0.id == id }) { choice = .followDefault }
    }

    func routes() {
        let games = model.games
        Task.detached(priority: .utility) { PadProfiles.refreshRoutes(games) }
    }

    func choose(_ t: String) {
        guard let c = contents else { return }
        let new: PadProfiles.Choice = t == "default" ? .followDefault : t == "none" ? .normal : t == "own" ? .own : t == "launcher" ? .sameAsLauncher : .profile(t)
        do {
            try PadProfiles.set(new, contents: c)
            let label: String
            switch new {
            case .followDefault: label = "the default"
            case .normal: label = "controller as it is"
            case .own: label = "a profile of its own"
            case .sameAsLauncher: label = "\(launcher)'s"
            case .profile(let id): label = profiles.first { $0.id == id }?.name ?? "a profile"
            }
            ChangeHistory.note(game, "Controller profile: \(label)", undo: .setting(GameDetailView.Tab.controls.rawValue))
            noteRestart()
        } catch { model.fail(error) }
        routes()
        load()
    }

    /// The controller makers that reach Windows as themselves need a restart to go through the profile instead.
    func noteRestart() {
        NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        guard let host = WineTools.hostContents(for: game) else { return }
        if model.games.contains(where: { WineTools.hostContents(for: $0) == host && model.isRunning($0) }) {
            model.say("Applies from the next press.")
        } else {
            Task.detached(priority: .utility) { Controllers.refresh(contents: host) }
        }
    }

    func edit(_ p: PadProfiles.Profile, own: Bool) {
        openWindow(id: "padprofile", value: PadEditorTarget(gameID: game.id, profileID: own ? nil : p.id))
    }

    func adopt(_ starter: PadProfiles.Profile) {
        guard let c = contents else { return }
        var p = starter; p.id = UUID().uuidString
        var n = p.name, i = 2
        while profiles.contains(where: { $0.name == n }) { n = "\(p.name) \(i)"; i += 1 }
        p.name = n
        do {
            try PadProfiles.store(p, environments: [])
            try PadProfiles.set(.profile(p.id), contents: c)
            routes(); noteRestart()
            load()
            edit(p, own: false)
        } catch { model.fail(error) }
    }

    func finishNaming() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let c = contents, !n.isEmpty else { return }
        do {
            switch naming {
            case .rename:
                if var p = shownProfile { p.name = n; try PadProfiles.store(p, environments: []) }
            case .duplicate:
                if var p = shownProfile {
                    p.id = UUID().uuidString; p.name = n
                    try PadProfiles.store(p, environments: [])
                    try PadProfiles.set(.profile(p.id), contents: c)
                    routes()
                    model.say("Saved \(n). Any game can use it from Profile.")
                }
            default:
                let p = PadProfiles.Profile(name: n)
                try PadProfiles.store(p, environments: [])
                try PadProfiles.set(.profile(p.id), contents: c)
                routes(); noteRestart()
                naming = nil
                load()
                edit(p, own: false)
                return
            }
        } catch { model.fail(error) }
        naming = nil
        load()
    }

    func makeDefault(_ p: PadProfiles.Profile?) {
        guard let c = contents else { return }
        do {
            try PadProfiles.setDefault(p, environments: allEnvironments, shared: sharedFolders)
            if let p, choice == .profile(p.id) { try PadProfiles.set(.followDefault, contents: c) }
            model.say(p.map { "\($0.name) is the default controller profile. Games you haven't given another one use it." }
                      ?? "No default controller profile; games without one of their own use controllers as they are.")
        } catch { model.fail(error) }
        load()
    }

    func makeOwn(from p: PadProfiles.Profile) {
        guard let c = contents else { return }
        var copy = p; copy.id = UUID().uuidString; copy.name = "This game"
        do { try PadProfiles.set(.own, contents: c, own: copy); routes() } catch { model.fail(error) }
        load()
    }

    func delete(_ p: PadProfiles.Profile) {
        do {
            try PadProfiles.delete(p, environments: allEnvironments, shared: sharedFolders)
            routes()
            model.say("Deleted \(p.name). Games that chose it keep a copy as their own.")
        } catch { model.fail(error) }
        load()
    }
}


extension Notification.Name { static let padProfilesChanged = Notification.Name("nokcandu.padProfilesChanged") }

/// Which profile a Controller Profile window edits: a shared one, or a game's own (profileID nil).
struct PadEditorTarget: Codable, Hashable { var gameID: String; var profileID: String? }

/// The Controller Profile window: finds the game and profile, and saves every change.
struct ControllerProfileWindow: View {
    @EnvironmentObject var model: AppModel
    let target: PadEditorTarget

    var game: InstalledGame? { model.games.first { $0.id == target.gameID } }

    var body: some View {
        if game == nil, let id = target.profileID, let p = PadProfiles.profiles().first(where: { $0.id == id }) {
            ControllerProfileEditor(profile: p, own: false, gameName: "", all: PadProfiles.profiles()) { new in
                do {
                    try PadProfiles.store(new, environments: KeyRemap.environments(model.games), shared: KeyRemap.sharedFolders(model.games))
                    NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
                } catch { model.fail(error) }
            }
            .navigationTitle(p.name)
        } else if let g = game, let c = KeyRemap.gameContents(for: g), let p = target.profileID.map({ id in PadProfiles.profiles().first { $0.id == id } }) ?? PadProfiles.own(contents: c) {
            ControllerProfileEditor(profile: p, own: target.profileID == nil, gameName: g.name, all: PadProfiles.profiles()) { new in
                save(new, game: g, contents: c)
            }
            .navigationTitle(target.profileID == nil ? "\(g.name) — Controller Profile" : p.name)
        } else {
            ContentUnavailableView("Profile not found", systemImage: "gamecontroller", description: Text("It may have been deleted."))
                .frame(width: 420, height: 300)
        }
    }

    func save(_ p: PadProfiles.Profile, game g: InstalledGame, contents c: URL) {
        do {
            if target.profileID == nil { try PadProfiles.set(.own, contents: c, own: p) }
            else {
                let envs = KeyRemap.environments(model.games), shared = KeyRemap.sharedFolders(model.games)
                try PadProfiles.store(p, environments: envs, shared: shared)
            }
            NotificationCenter.default.post(name: .padProfilesChanged, object: nil)
        } catch { model.fail(error) }
    }
}
