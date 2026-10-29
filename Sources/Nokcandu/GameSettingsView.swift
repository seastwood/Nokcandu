import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

/// Editable settings for games added through Nokcandu: name, program, launch options, extra
/// environment variables and the disc image. Changes are journaled and regenerate the launcher.
struct GameSettingsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    @State private var draft: CustomGameConfig
    @State private var candidates: [CustomGames.ExeCandidate] = []
    @State private var envRows: [EnvRow]
    @State private var launcherEdited = false
    @State private var saving = false

    struct EnvRow: Identifiable, Hashable { var id = UUID(); var key: String; var value: String }

    init(game: InstalledGame) {
        self.game = game
        let c = game.custom!
        _draft = State(initialValue: c)
        _envRows = State(initialValue: (c.environment ?? [:]).sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) })
    }

    var original: CustomGameConfig { game.custom! }
    var isSteam: Bool { game.usesSharedSteam }

    var environment: [String: String]? {
        let pairs = envRows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        return pairs.isEmpty ? nil : Dictionary(pairs.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { _, b in b })
    }
    var edited: CustomGameConfig { var c = draft; c.environment = isSteam ? original.environment : environment; return c }
    var dirty: Bool { edited != original }
    var invalidKeys: [String] { envRows.map(\.key).filter { !$0.isEmpty && !CustomGames.isValidEnvName($0) } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                row("Name") {
                    TextField("Name", text: $draft.name).frame(maxWidth: 320)
                }
                if !isSteam {
                    row("Program") {
                        HStack {
                            Menu {
                                ForEach(candidates) { c in
                                    Button("\(c.url.lastPathComponent) — \(c.windowsPath)") { draft.exe = c.windowsPath }
                                }
                                Divider()
                                Button("Choose Another…") { chooseExe() }
                            } label: {
                                Text(draft.exe.split(separator: "\\").last.map(String.init) ?? draft.exe)
                            }
                            .frame(maxWidth: 320)
                            .onAppear(perform: loadCandidates)
                        }
                    }
                    Text(draft.exe).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                row("Launch options") {
                    TextField(isSteam ? "e.g. -novid -console" : "e.g. -window -opengl -nosound", text: $draft.arguments)
                        .font(.body.monospaced()).frame(maxWidth: 420)
                }
                if isSteam {
                    Text("Passed to the game when Steam starts it.").font(.caption).foregroundStyle(.secondary)
                }
                if let disc = draft.disc {
                    row("Disc image") {
                        HStack {
                            Text("\(disc.imageName) (label \(disc.volumeLabel.isEmpty ? "none" : disc.volumeLabel))").lineLimit(1).truncationMode(.middle)
                            Button("Replace…") { replaceDisc() }
                        }
                    }
                }
                if !isSteam {
                    DisclosureGroup("Advanced: environment variables") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Added to the launcher after the graphics mode, so they can override it (for example WINEDLLOVERRIDES or DXVK_HUD=fps).")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach($envRows) { $r in
                                HStack {
                                    TextField("NAME", text: $r.key).font(.body.monospaced()).frame(width: 200)
                                    Text("=")
                                    TextField("value", text: $r.value).font(.body.monospaced())
                                    Button { envRows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                                }
                            }
                            Button { envRows.append(EnvRow(key: "", value: "")) } label: { Label("Add Variable", systemImage: "plus") }
                                .buttonStyle(.borderless)
                            if !invalidKeys.isEmpty {
                                Text("Not allowed: \(invalidKeys.joined(separator: ", ")). Names use letters, digits and _; PATH, WINEPREFIX, HOME and DYLD_FALLBACK_LIBRARY_PATH are managed by Nokcandu.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 4)
                    }.disclosureGroupStyle(WholeRowDisclosureStyle())
                }
                if launcherEdited {
                    Label("The launcher was edited outside Nokcandu. Saving will replace it (the old one is kept so it can be undone).", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Save Changes") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!dirty || saving || !invalidKeys.isEmpty || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Revert") { revert() }.disabled(!dirty)
                    Spacer()
                    Button("Rebuild Launcher") { save(force: true, always: true) }
                        .help("Regenerates the launcher from these settings.")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Settings").font(.headline) }
        .onAppear(perform: checkLauncher)
    }

    func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            content()
        }
    }

    func loadCandidates() {
        let g = game
        Task {
            candidates = await Task.detached { CustomGames.executables(for: g) }.value
        }
    }

    func checkLauncher() {
        guard let l = game.launcherURL, let sha = try? Hashing.sha256(file: l) else { return }
        launcherEdited = sha != original.launcherSHA
    }

    func chooseExe() {
        let p = NSOpenPanel()
        p.directoryURL = game.prefix.appendingPathComponent("drive_c")
        p.allowedContentTypes = [UTType(filenameExtension: "exe")].compactMap { $0 }
        guard p.runModal() == .OK, let u = p.url else { return }
        if let w = CustomGames.windowsPath(forUnix: u, prefix: game.prefix) { draft.exe = w }
        else { model.fail(NokError("Choose a program inside this game's C: drive. To add files, open the C: drive from Files & Tools.")) }
    }

    func replaceDisc() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["iso", "cdr"].compactMap { UTType(filenameExtension: $0) }
        guard p.runModal() == .OK, let u = p.url else { return }
        do { draft = try CustomGames.prepareDisc(u, for: game, current: draft) } catch { model.fail(error) }
    }

    func revert() {
        draft = original
        envRows = (original.environment ?? [:]).sorted { $0.key < $1.key }.map { EnvRow(key: $0.key, value: $0.value) }
    }

    func save(force: Bool = false, always: Bool = false) {
        guard dirty || always else { return }
        saving = true
        let c = edited, g = game, f = force || launcherEdited
        model.changeSetting(for: g, title: "Game Settings", edit: { fresh in
            try await Task.detached { try CustomGames.saveAll(c, to: fresh, force: f) }.value
        }, completion: { _ in saving = false })
    }
}

/// Folders and Windows tools for any game with a Windows environment.
struct FilesToolsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    var places: [WineTools.Place] { WineTools.places(for: game) }
    var hasWine: Bool { WineTools.hostContents(for: game) != nil }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Files").font(.subheadline.bold())
                FlowButtons(items: places.map { p in (p.title, p.symbol, { NSWorkspace.shared.open(p.url) }) })
                if hasWine {
                    DrivesSection(game: game).padding(.top, 4)
                    Text("Windows tools").font(.subheadline.bold()).padding(.top, 4)
                    if game.usesSharedSteam {
                        Text("These open the shared Steam's Windows environment, which all your Steam games use.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if game.recipe?.hasInstaller == true || game.recipe?.id.hasPrefix("custom") == false {
                        Text("This game uses a tested recipe; changes made here can affect it. Diagnostics will show what differs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    FlowButtons(items: WineTools.Tool.allCases.map { t in (t.title, t.symbol, { open(t) }) }
                                + [("Run a Windows Program…", "play.rectangle", runProgram),
                                   ("Microphone Access…", "mic", { NSWorkspace.shared.open(AppPrivacy.microphoneSettings) }),
                                   ("Force Quit Windows Programs", "xmark.octagon", stopAll)])
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Files & Tools").font(.headline) }
    }

    func open(_ t: WineTools.Tool) {
        do { try WineTools.open(t, for: game); model.say("Opening \(t.title)…") } catch { model.fail(error) }
    }

    func stopAll() {
        let g = game
        Task {
            do { try await WineTools.stopAll(for: g); model.say("Stopped all Windows programs for \(g.usesSharedSteam ? "Steam" : g.name).") }
            catch { model.fail(error) }
            model.refreshRunStates()
        }
    }

    func runProgram() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["exe", "msi", "bat"].compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a Windows program to run once in \(game.name)'s Windows environment (an installer, a patch, a tool…)."
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try WineTools.runProgram(u, for: game); model.say("Starting \(u.lastPathComponent)…") } catch { model.fail(error) }
    }
}

/// Wrapping row of small bordered buttons.
struct FlowButtons: View {
    let items: [(String, String, () -> Void)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                Button(action: items[i].2) { Label(items[i].0, systemImage: items[i].1).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Shows which program a game starts and lets you switch it on the spot (saved immediately, undoable).
struct ProgramPicker: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    var onChange: () -> Void = {}
    @State private var exe: String
    @State private var candidates: [CustomGames.ExeCandidate] = []

    init(game: InstalledGame, onChange: @escaping () -> Void = {}) {
        self.game = game; self.onChange = onChange
        _exe = State(initialValue: game.custom?.exe ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Program").frame(width: 70, alignment: .leading)
                Menu {
                    ForEach(candidates) { c in
                        Button("\(c.url.lastPathComponent) — \(c.windowsPath)") { apply(c.windowsPath) }
                    }
                    Divider()
                    Button("Choose Another…", action: chooseOther)
                } label: { Text(exe.split(separator: "\\").last.map(String.init) ?? exe) }
                .frame(maxWidth: 320)
            }
            Text(exe).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .task {
            let g = game
            candidates = await Task.detached { CustomGames.executables(for: g) }.value
        }
    }

    func apply(_ path: String) {
        guard var c = game.custom, path != c.exe else { return }
        c.exe = path
        do {
            try CustomGames.saveAll(c, to: game)
            exe = path
            model.say("\(game.name) now starts \(path.split(separator: "\\").last ?? "").")
            model.refresh(); onChange()
        } catch { model.fail(error) }
    }

    func chooseOther() {
        let p = NSOpenPanel()
        p.directoryURL = game.prefix.appendingPathComponent("drive_c")
        p.allowedContentTypes = [UTType(filenameExtension: "exe")].compactMap { $0 }
        guard p.runModal() == .OK, let u = p.url else { return }
        if let w = CustomGames.windowsPath(forUnix: u, prefix: game.prefix) { apply(w) }
        else { model.fail(NokError("Choose a program inside this game's C: drive.")) }
    }
}
