import SwiftUI
import NokcanduCore

/// Controls → Keyboard: keys that act as other keys while this game is in front. Sets of remaps are saved as
/// layouts that any game can use; one layout can be the default for every game that hasn't got keys of its own.
struct KeyboardSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var mappings: [KeyRemap.Mapping] = []
    @State private var layouts: [KeyRemap.Layout] = []
    @State private var choice: KeyRemap.Choice = .followDefault
    @State private var defaultID: String?
    @State private var users: [String: Int] = [:]          // layout id → environments using it directly
    @State private var profiles: [KeyRemap.KarabinerProfile] = []
    @State private var naming: Naming?
    @State private var name = ""

    enum Naming: Identifiable { case new, rename; var id: Int { self == .new ? 0 : 1 } }

    var contents: URL? { KeyRemap.gameContents(for: game) }
    var shared: Bool { KeyRemap.isShared(game) }
    var launcher: String { StartupMonitor.storeName(game) }
    var defaultLayout: KeyRemap.Layout? { layouts.first { $0.id == defaultID } }
    /// The layout whose keys are shown (the chosen one, or the default when following it).
    var shownLayout: KeyRemap.Layout? {
        switch choice {
        case .layout(let id): return layouts.first { $0.id == id }
        case .followDefault: return defaultLayout
        default: return nil
        }
    }
    var scope: String {
        if shared { return "Applies to this game only; Same as \(launcher) uses \(launcher)'s keys." }
        if game.usesSharedSteam || game.isSteamHost { return "Applies to all Steam games." }
        if game.battleNet != nil || BattleNet.isHost(game) { return "Applies to all Battle.net games." }
        if game.hosted != nil || PCLaunchers.kind(of: game) != nil { return "Applies to all games in this launcher." }
        return "Applies to this game."
    }
    var tag: String {
        switch choice { case .followDefault: "default"; case .normal: "none"; case .own: "own"; case .layout(let id): id; case .sameAsLauncher: "launcher" }
    }

    var body: some View {
        SettingsSection(title: "Keyboard", info: "Make a key act as another key while the game is in front — for example fn as Control, or Right Option as Right Control. Switching to another app, or quitting the game, puts your keyboard back. Remapped keys are real keys to macOS too: fn as Control holds like Control and doesn't open fn's shortcuts.\n\nLayouts: save a set of keys once and choose it in any game; changing a layout changes every game using it. Make one the default and every game uses it unless you choose something else for that game.\n\n\(scope) Changes apply while playing.") {
            SettingRow(title: "Keys") {
                Picker("Keys", selection: Binding(get: { tag }, set: choose)) {
                    if shared { Text("Same as \(launcher)").tag("launcher") }
                    Text("Default (\(defaultLayout?.name ?? "normal keys"))").tag("default")
                    Text("Normal keys").tag("none")
                    if choice == .own { Text("Just for this game").tag("own") }
                    if !layouts.isEmpty { Divider() }
                    ForEach(layouts) { l in Text(l.name + (l.id == defaultID ? " (default)" : "")).tag(l.id) }
                }
                .labelsHidden().frame(width: 240)
                menu
            }
            if let l = shownLayout {
                let n = (users[l.id] ?? 0) + (l.id == defaultID ? 1 : 0)
                SettingNote(choice == .followDefault
                            ? "This game uses the default layout, \(l.name). Changing these keys changes \(l.name) for every game using it."
                            : "Changing these keys changes the \(l.name) layout\(n > 1 ? " for every game using it" : "").")
            } else if choice == .followDefault {
                SettingNote("No default layout yet. Save keys as a layout, then make it the default from the ⋯ menu.")
            }
            if choice == .sameAsLauncher {
                SettingNote("Uses \(launcher)'s keys (set on \(launcher)'s page). Choose something else here to give \(game.name) keys of its own.")
            }
            ForEach(mappings) { m in row(m) }
            HStack {
                Button("Add Key") { add() }
                if choice == .own && !mappings.isEmpty {
                    Button("Save as Layout…") { name = ""; naming = .new }
                }
            }
        }
        .onAppear(perform: load)
        .alert(naming == .rename ? "Rename Layout" : "New Layout", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button(naming == .rename ? "Rename" : "Save") { finishNaming() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text(naming == .rename ? "Games using it keep using it." : "Starts with this game's current keys. Any game can then choose it from Keys.")
        }
    }

    @ViewBuilder var menu: some View {
        Menu {
            Button("New Layout…") { name = ""; naming = .new }
            if let l = shownLayout {
                Divider()
                if l.id == defaultID {
                    Button("Stop Using \(l.name) as the Default") { makeDefault(nil) }
                } else {
                    Button("Make \(l.name) the Default for All Games") { makeDefault(l) }
                }
                Button("Rename \(l.name)…") { name = l.name; naming = .rename }
                Button("Delete \(l.name)", role: .destructive) { deleteLayout(l) }
            }
            if !profiles.isEmpty {
                Divider()
                Section("Copy from Karabiner-Elements") {
                    ForEach(profiles) { p in
                        Button("\(p.name)\(p.selected ? " (current)" : "") — \(p.mappings.count) key\(p.mappings.count == 1 ? "" : "s")") { copy(p) }
                            .disabled(p.mappings.isEmpty)
                    }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Layout options").help("Layouts")
    }

    func row(_ m: KeyRemap.Mapping) -> some View {
        HStack {
            Picker("Key", selection: Binding(get: { m.from }, set: { new in
                guard !mappings.contains(where: { $0.from == new }), let i = mappings.firstIndex(of: m) else { return }
                mappings[i].from = new; commit()
            })) { ForEach(KeyRemap.keys) { Text($0.title).tag($0.code) } }
                .labelsHidden().frame(width: 170)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityLabel("acts as")
            Picker("Acts as", selection: Binding(get: { m.to ?? -1 }, set: { v in
                guard let i = mappings.firstIndex(of: m) else { return }
                mappings[i].to = v < 0 ? nil : v; commit()
            })) {
                Text("Nothing").tag(-1)
                ForEach(KeyRemap.keys) { Text($0.title).tag($0.code) }
            }
                .labelsHidden().frame(width: 170)
            Spacer()
            Button { mappings.removeAll { $0.from == m.from }; commit() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).accessibilityLabel("Remove this remap").help("Remove")
        }
    }

    // MARK: Loading and saving

    var allEnvironments: [URL] { KeyRemap.environments(model.games) + (shared ? [] : contents.map { [$0] } ?? []) }
    var sharedFolders: [URL] { KeyRemap.sharedFolders(model.games) + (shared ? contents.map { [$0] } ?? [] : []) }

    func load() {
        guard let c = contents else { return }
        layouts = KeyRemap.layouts()
        defaultID = KeyRemap.defaultLayoutID()
        choice = KeyRemap.choice(contents: c, shared: shared)
        if case .layout(let id) = choice, !layouts.contains(where: { $0.id == id }) { choice = .followDefault }
        mappings = shownLayout?.mappings ?? (choice == .own ? KeyRemap.load(contents: c) : [])
        var count: [String: Int] = [:]
        for e in KeyRemap.environments(model.games) { if case .layout(let id) = KeyRemap.choice(contents: e) { count[id, default: 0] += 1 } }
        users = count
        profiles = KeyRemap.karabinerInstalled ? KeyRemap.karabinerProfiles() : []
    }

    /// Saves the keys shown: into the layout being shown (and every game using it), or into this game's own keys.
    func commit() {
        guard let c = contents else { return }
        do {
            if var l = shownLayout {
                l.mappings = mappings
                try KeyRemap.store(l, environments: allEnvironments, shared: sharedFolders)
                if let i = layouts.firstIndex(where: { $0.id == l.id }) { layouts[i] = l }
            } else {
                choice = .own
                try KeyRemap.set(.own, contents: c, own: mappings)
                routes()
            }
        } catch { model.fail(error) }
    }

    func choose(_ t: String) {
        guard let c = contents else { return }
        let new: KeyRemap.Choice = t == "default" ? .followDefault : t == "none" ? .normal : t == "own" ? .own : t == "launcher" ? .sameAsLauncher : .layout(t)
        do {
            try KeyRemap.set(new, contents: c, own: KeyRemap.load(contents: c))
            let label: String
            switch new {
            case .followDefault: label = "the default layout"
            case .normal: label = "normal keys"
            case .own: label = "keys of its own"
            case .sameAsLauncher: label = "\(launcher)'s keys"
            case .layout(let id): label = layouts.first { $0.id == id }.map { "the \($0.name) layout" } ?? "a layout"
            }
            ChangeHistory.note(game, "Keys: \(label)", undo: .setting(GameDetailView.Tab.controls.rawValue))
        } catch { model.fail(error) }
        routes()
        load()
    }

    func add() {
        let used = Set(mappings.map(\.from))
        guard let free = KeyRemap.keys.first(where: { !used.contains($0.code) }) else { return }
        if choice == .normal || choice == .sameAsLauncher || (choice == .followDefault && defaultLayout == nil) { choice = .own }
        mappings.append(KeyRemap.Mapping(from: free.code, to: free.code == 59 ? 62 : 59))
        commit()
    }

    func finishNaming() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let c = contents, !n.isEmpty else { return }
        do {
            if naming == .rename, var l = shownLayout {
                l.name = n
                try KeyRemap.store(l, environments: [])
            } else {
                let l = KeyRemap.Layout(name: n, mappings: mappings)
                try KeyRemap.store(l, environments: [])
                try KeyRemap.set(.layout(l.id), contents: c)
                routes()
                model.say("Saved the \(n) layout. Any game can use it from Keys, and the ⋯ menu can make it the default.")
            }
        } catch { model.fail(error) }
        naming = nil
        load()
    }

    func makeDefault(_ l: KeyRemap.Layout?) {
        guard let c = contents else { return }
        do {
            try KeyRemap.setDefault(l, environments: allEnvironments, shared: sharedFolders)
            // This game follows the default from now on (it was showing that layout already).
            if let l, choice == .layout(l.id) { try KeyRemap.set(.followDefault, contents: c) }
            model.say(l.map { "\($0.name) is the default layout. Games you haven't given other keys use it." } ?? "No default layout; games without keys of their own use normal keys.")
        } catch { model.fail(error) }
        load()
    }

    func deleteLayout(_ l: KeyRemap.Layout) {
        do { try KeyRemap.delete(l, environments: allEnvironments, shared: sharedFolders); routes(); model.say("Deleted the \(l.name) layout. Games that chose it keep its keys as their own.") }
        catch { model.fail(error) }
        load()
    }

    /// Which programs of a launcher use a game's own keys (they pick it up the next time the game starts).
    func routes() {
        let games = model.games
        Task.detached(priority: .utility) { KeyRemap.refreshRoutes(games) }
        if shared { model.say("\(game.name) uses these keys from its next start.") }
    }

    /// A Karabiner profile becomes a layout of the same name (updated if it already exists) used by this game.
    func copy(_ p: KeyRemap.KarabinerProfile) {
        guard let c = contents else { return }
        do {
            var l = layouts.first { $0.name == p.name } ?? KeyRemap.Layout(name: p.name, mappings: [])
            l.mappings = p.mappings
            try KeyRemap.store(l, environments: allEnvironments, shared: sharedFolders)
            if shownLayout?.id != l.id { try KeyRemap.set(.layout(l.id), contents: c); routes() }
            model.say("Copied Karabiner's \(p.name) profile as a layout (\(p.mappings.count) key\(p.mappings.count == 1 ? "" : "s"))" + (p.skipped > 0 ? "; \(p.skipped) rule\(p.skipped == 1 ? "" : "s") it can't copy were left out." : ".") + " Turn that profile off in Karabiner while playing so keys aren't remapped twice.")
        } catch { model.fail(error) }
        load()
    }
}
