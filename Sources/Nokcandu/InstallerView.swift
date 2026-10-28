import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

@MainActor
final class InstallerModel: ObservableObject {
    @Published var executor: InstallExecutor?
    @Published var log: String = ""
    @Published var running = false
    @Published var cancelling = false
    @Published var workProgress: InstallWorkProgress?
    @Published var tick = 0
    @Published var saved: [InstallState] = InstallerModel.unfinished()

    /// Installs that aren't finished and whose app isn't a working game yet (an install whose last
    /// confirmation step was skipped, but whose app plays, isn't shown).
    static func unfinished() -> [InstallState] {
        InstallExecutor.savedInstalls().filter { s in
            guard s.finishedAt == nil else { return false }
            let app = URL(fileURLWithPath: s.targetApp)
            let complete = FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
                && GameLibrary.inspect(app)?.launcherURL != nil
            return !complete
        }
    }
    @Published var exeCandidates: [CustomGames.ExeCandidate] = []
    private var task: Task<Void, Never>?

    private func wire(_ ex: InstallExecutor) {
        ex.onChange = { [weak self] in Task { @MainActor in self?.tick += 1 } }
        ex.ctx.onProgress = { [weak self] value in Task { @MainActor in self?.workProgress = value } }
        executor = ex
    }
    private var logger: @Sendable (String) -> Void {
        { [weak self] line in Task { @MainActor in self?.append(line) } }
    }

    func start(recipe: GameRecipe, library: [InstalledGame]) {
        do { wire(try InstallExecutor.make(recipe: recipe, library: library, log: logger)) }
        catch { append("✗ \(error.localizedDescription)") }
    }

    /// Shown in the chooser when a game can't be started (the log isn't visible there yet).
    @Published var startError: String?

    func startCustom(name: String, source: GameSource, library: [InstalledGame], folder: URL = GameFolders.installFolder, inputs: [String: String] = [:]) {
        startError = nil
        // Same name as an unfinished install: pick that one up again instead of refusing.
        let appName = CustomGames.safeFolderName(name.trimmingCharacters(in: .whitespacesAndNewlines)) + ".app"
        if let s = saved.first(where: { URL(fileURLWithPath: $0.targetApp).lastPathComponent.caseInsensitiveCompare(appName) == .orderedSame }) {
            resume(s.installID, library: library)
            return
        }
        do { wire(try InstallExecutor.makeCustom(name: name, source: source, library: library, folder: folder, inputs: inputs, log: logger)) }
        catch { append("✗ \(error.localizedDescription)"); startError = error.localizedDescription }
    }

    func startBattleNet(library: [InstalledGame]) {
        startError = nil
        append("Downloading the Battle.net installer…")
        Task {
            do {
                let setup = try await PCLaunchers.downloadBattleNetSetup()
                startCustom(name: "Battle.net", source: .installer, library: library, folder: NokPaths.gameAppsFolder, inputs: ["installerPath": setup.path])
                if executor != nil { continueInstall() }
            } catch { append("✗ \(error.localizedDescription)"); startError = error.localizedDescription }
        }
    }

    /// EA app / Ubisoft Connect: fetch the official installer, then the usual "Windows installer" setup.
    func startLauncher(_ k: PCLauncher, library: [InstalledGame]) {
        startError = nil
        append("Downloading the \(k.title) installer…")
        Task {
            do {
                let setup = try await PCLaunchers.downloadSetup(k)
                startCustom(name: k.title, source: .installer, library: library, folder: NokPaths.gameAppsFolder, inputs: ["installerPath": setup.path])
                if executor != nil { continueInstall() }
            } catch { append("✗ \(error.localizedDescription)"); startError = error.localizedDescription }
        }
    }

    func startSteamHost(library: [InstalledGame]) {
        do { wire(try InstallExecutor.makeSteamHost(library: library, log: logger)) }
        catch { append("✗ \(error.localizedDescription)") }
    }

    func resume(_ id: String, library: [InstalledGame]) {
        do { wire(try InstallExecutor.resume(id, library: library, log: logger)) }
        catch { append("✗ \(error.localizedDescription)") }
    }

    /// Undo a saved, unfinished install without opening it: trash the app it created and its progress.
    func removeSaved(_ id: String, library: [InstalledGame]) -> String {
        do {
            let ex = try InstallExecutor.resume(id, library: library, log: { _ in })
            let msg = ex.removeUnfinishedInstall()
            saved = InstallerModel.unfinished()
            return msg
        } catch { return error.localizedDescription }
    }

    func append(_ line: String) {
        log += line + "\n"
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    func continueInstall() {
        guard let ex = executor, !running else { return }
        if let s = ex.nextStage, case .failed = ex.statuses[s.info.id] ?? .pending { ex.resetFailure(s.info.id) }
        running = true; cancelling = false; workProgress = nil
        task = Task {
            await ex.runUntilBlocked()
            running = false; cancelling = false; workProgress = nil
            tick += 1
            refreshCandidates()
        }
    }

    func refreshCandidates() {
        guard let ex = executor, ex.isCustom, ex.nextStage?.info.id == "exe" else { return }
        let prefix = ex.ctx.prefix, hint = ex.displayName
        Task.detached {
            let c = CustomGames.findExecutables(prefix: prefix, nameHint: hint)
            await MainActor.run { self.exeCandidates = c }
        }
    }

    func cancel() { cancelling = true; task?.cancel() }

    func setInput(_ k: String, _ v: String) { executor?.setInput(k, v); tick += 1 }
}

struct InstallerView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = InstallerModel()
    @State private var steamUser = ""
    @State private var steamAppID = ""
    @State private var newName = ""
    @State private var newSource: GameSource = .installer
    @State private var installFolder: URL = GameFolders.installFolder
    @State private var confirmRemove = false
    @State private var pendingRemoval: InstallState?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(m.executor == nil ? "Add a Game" : "Install \(m.executor!.displayName)").font(.title2.bold())
                Spacer()
                Text("Preview").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.orange.opacity(0.2), in: Capsule())
            }
            .padding()
            Divider()
            if let ex = m.executor { progressView(ex) } else { chooser }
            Divider()
            footer
        }
        .frame(width: 780, height: 600)
        .confirmationDialog("Remove the unfinished install of \(pendingRemoval.map { URL(fileURLWithPath: $0.targetApp).deletingPathExtension().lastPathComponent } ?? "")?",
                            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let s = pendingRemoval { app.say(m.removeSaved(s.installID, library: app.games)); app.refresh() }
                pendingRemoval = nil
            }
        } message: { Text("Moves the half-built app (only if this install created it) to the Trash and forgets its progress. Other games aren't touched.") }
        .onAppear {
            if app.installerStartsSteamHost && m.executor == nil { m.startSteamHost(library: app.games) }
            if let p = app.pendingLauncherSetup, m.executor == nil {
                app.pendingLauncherSetup = nil
                if let k = p { m.startLauncher(k, library: app.games) } else { m.startBattleNet(library: app.games) }
            }
            if let p = app.pendingStoreInstall, m.executor == nil {
                app.pendingStoreInstall = nil
                m.startCustom(name: p.name, source: .store, library: app.games, folder: p.folder, inputs: p.inputs)
                if m.executor != nil { m.continueInstall() }
            }
        }
    }

    // MARK: Choose

    var chooser: some View {
        List {
            Section {
                Text("Every game gets its own new app with its own Windows environment. Your existing games, saves and settings aren't touched. Each step checks its own result and stops rather than guessing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let e = m.startError {
                Section { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            if !m.saved.isEmpty {
                Section("Unfinished installs") {
                    ForEach(m.saved, id: \.installID) { s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(URL(fileURLWithPath: s.targetApp).deletingPathExtension().lastPathComponent)
                                Text("\(s.completed.count) steps done · started \(s.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume") { m.resume(s.installID, library: app.games); m.refreshCandidates() }
                            Button("Remove…", role: .destructive) { pendingRemoval = s }
                        }
                    }
                }
            }
            Section("Any Windows game you own") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Game name").font(.subheadline.weight(.medium))
                    TextField("Game name", text: $newName, prompt: Text("For example: Counter-Strike 2"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                .padding(.vertical, 2)
                ForEach(GameSource.allCases) { s in
                    Button { newSource = s } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: newSource == s ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(newSource == s ? Color.accentColor : .secondary)
                            Image(systemName: s.symbol).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title)
                                Text(s.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if newSource != .steamLibrary && newSource != .store {
                    InstallFolderPicker(folder: $installFolder)
                }
                HStack {
                    Text("New games start untested. Nokcandu suggests a graphics mode; you confirm it actually plays.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(newSource == .steamLibrary ? "Open Steam Library" : newSource == .store ? "Open Store Library" : "Start") {
                        if newSource == .steamLibrary {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showSteamLibrary = true }
                        } else if newSource == .store {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showStores = true }
                        } else {
                            m.startCustom(name: newName, source: newSource, library: app.games, folder: installFolder)
                        }
                    }
                        .disabled(newSource != .steamLibrary && newSource != .store && newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            Section("Mac games") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add a Mac game").font(.headline)
                        Text("Keep Mac games (like OpenMW) in the same library. Nokcandu just opens them — nothing is changed or moved.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Choose App…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.addMacGame() }
                    }
                }
            }
            Section("Game launchers") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battle.net").font(.headline)
                        Text("Downloads Blizzard's installer and sets up Battle.net. Each Blizzard game you install in it gets its own Mac app.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let h = app.games.first(where: BattleNet.isHost) {
                        Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        Button("Show") { app.selection = h.id; dismiss() }
                    } else {
                        Button("Set Up") { m.startBattleNet(library: app.games) }.disabled(m.running)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Steam").font(.headline)
                        Text("One shared Steam for all your Steam games.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Steam Library") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showSteamLibrary = true } }
                }
                ForEach(PCLauncher.allCases.filter { !$0.isOptional }) { k in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.title).font(.headline)
                            Text("Downloads the official \(k.title) installer and sets it up as a launcher app. Games you install in it can each get their own Mac app.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let h = app.games.first(where: { PCLaunchers.kind(of: $0) == k }) {
                            Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            Button("Show") { app.selection = h.id; dismiss() }
                        } else {
                            Button("Set Up") { m.startLauncher(k, library: app.games) }.disabled(m.running)
                        }
                    }
                }
            }
            Section("Tested recipes") {
                ForEach(RecipeCatalog.all) { r in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(r.displayName).font(.headline)
                            Text(r.edition).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if r.hasInstaller {
                            Button("Choose") { m.start(recipe: r, library: app.games) }
                        } else {
                            Text("Installed manually").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Progress

    @ViewBuilder
    func progressView(_ ex: InstallExecutor) -> some View {
        let _ = m.tick
        HStack(spacing: 0) {
            List {
                ForEach(ex.stages, id: \.info.id) { s in
                    StageRow(info: s.info, status: ex.statuses[s.info.id] ?? .pending)
                }
            }
            .frame(width: 270)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                DiscSwapBar(ex: ex)
                if let s = ex.nextStage {
                    Text(s.info.title).font(.headline)
                    Text(s.info.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if case .needsUser(let why) = ex.statuses[s.info.id] ?? .pending, why != s.info.detail {
                        Label(why, systemImage: "hand.raised.fill").font(.callout).foregroundStyle(.orange)
                    }
                    if case .failed(let why) = ex.statuses[s.info.id] ?? .pending {
                        Label(why, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
                    }
                    inputs(for: s.info, ex)
                } else {
                    if ex.isSteamHost {
                        Label("Steam is set up and signed in.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Open Steam Library") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showSteamLibrary = true } }
                    } else {
                        Label("Installed and play-tested.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Text(ex.ctx.targetApp.path).font(.caption).textSelection(.enabled)
                }
                if m.running {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(m.cancelling ? "Cancelling…" : (m.workProgress?.phase ?? "Working…"))
                            Spacer()
                            if !m.cancelling, let fraction = m.workProgress?.fraction { Text("\(Int(fraction * 100))%").monospacedDigit() }
                        }.font(.callout)
                        if !m.cancelling, let fraction = m.workProgress?.fraction { ProgressView(value: fraction, total: 1) }
                        else { ProgressView().progressViewStyle(.linear) }
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Log").font(.caption.bold()).padding(.top, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(m.log).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).id("end")
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: m.log) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    func inputs(for info: StageInfo, _ ex: InstallExecutor) -> some View {
        let inputs = ex.ctx.state.inputs
        switch (ex.isCustom, info.id) {
        case (false, "steam"):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Steam account name", text: $steamUser).frame(maxWidth: 220)
                    Button("Open SteamCMD") { m.setInput("steamUser", steamUser); m.continueInstall() }
                        .disabled(steamUser.isEmpty || m.running)
                }
                HStack {
                    Button("Use Existing Game Folder…") {
                        if let u = pick(folder: true, types: []) { m.setInput("existingGameFolder", u.path); m.continueInstall() }
                    }
                    if inputs["steam.opened"] == "1" {
                        Button("Open Terminal Again") { m.setInput("steam.opened", "0"); m.continueInstall() }
                    }
                }
            }
        case (false, "generalsonline"):
            HStack {
                Button("Open playgenerals.online") { NSWorkspace.shared.open(ZeroHourInstall.generalsOnlineSite) }
                Button("Choose Installer…") {
                    if let u = pick(folder: false, types: ["exe"]) { m.setInput("goInstaller", u.path); m.continueInstall() }
                }
                if inputs["generalsonline.opened"] == "1" {
                    Button("Run Installer Again") { m.setInput("generalsonline.opened", "0"); m.continueInstall() }
                }
            }
        case (false, "icu"):
            Button("Use a Downloaded .nupkg Instead…") {
                if let u = pick(folder: false, types: ["nupkg"]) { m.setInput("icuPackage", u.path); m.continueInstall() }
            }
        case (false, "install-steam"):
            HStack {
                Button("Get SteamSetup.exe") { NSWorkspace.shared.open(CustomGames.steamSetupPage) }
                Button("Choose SteamSetup.exe…") {
                    if let u = pick(folder: false, types: ["exe"]) { m.setInput("steamSetup", u.path); m.continueInstall() }
                }
            }
        case (false, "sign-in"):
            HStack {
                Button("Open Steam Again") { try? SharedSteam.openSteam() }
                if ex.isComplete || SharedSteam.isSetUp {
                    Button("Open Steam Library") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showSteamLibrary = true } }
                }
            }
        case (true, "acquire"):
            customAcquire(ex)
        case (true, "exe"):
            exePicker(ex)
        case (_, "playtest"):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Open the New App") {
                        if let g = GameLibrary.inspect(ex.ctx.targetApp) { app.play(g) }
                    }
                    Button("It Played Well") { m.setInput("playtest", "confirmed"); m.continueInstall() }
                }
                if ex.isCustom, let g = GameLibrary.inspect(ex.ctx.targetApp), g.custom != nil {
                    if g.custom?.source != .steamLibrary {
                        ProgramPicker(game: g) { m.tick += 1 }.id(g.custom?.exe)
                    }
                    GraphicsPicker(game: g) { m.tick += 1 }
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func customAcquire(_ ex: InstallExecutor) -> some View {
        let source = ex.ctx.state.inputs["source"].flatMap(GameSource.init(rawValue:)) ?? .installer
        let inputs = ex.ctx.state.inputs
        switch source {
        case .installer:
            HStack {
                Button("Choose Installer…") {
                    if let u = pick(folder: false, types: ["exe", "msi"]) { m.setInput("installerPath", u.path); m.continueInstall() }
                }
                if inputs["acquire.opened"] == "1" {
                    Button("Run Installer Again") { m.setInput("acquire.opened", "0"); m.setInput("acquire.finished", "0"); m.continueInstall() }
                }
            }
        case .disc:
            HStack {
                Button("Choose Disc Images…") {
                    let urls = Discs.sorted(pickMany(types: Discs.imageTypes))
                    if let first = urls.first {
                        m.setInput("acquire.opened", "0"); m.setInput("acquire.finished", "0")
                        m.setInput("isoPaths", urls.map(\.path).joined(separator: "\n"))
                        m.setInput("isoPath", first.path); m.continueInstall()
                    }
                }
                if inputs["acquire.opened"] == "1" {
                    Button("Run Setup Again") { m.setInput("disc.recoveryFolder", ""); m.setInput("acquire.opened", "0"); m.setInput("acquire.finished", "0"); m.continueInstall() }
                    Button("Copy Game Folder After Setup…") {
                        if let u = pick(folder: true, types: []) {
                            m.setInput("folderMode", "copy"); m.setInput("folderPath", u.path)
                            m.setInput("disc.recoveryFolder", u.path); m.continueInstall()
                        }
                    }
                    .disabled(m.running)
                }
            }
        case .folder:
            Button("Choose Game Folder…") {
                if let u = pick(folder: true, types: []) { m.setInput("folderMode", "copy"); m.setInput("folderPath", u.path); m.continueInstall() }
            }
            Button("Use Existing Folder Without Copying…") {
                if let u = pick(folder: true, types: []) { m.setInput("folderMode", "existing"); m.setInput("folderPath", u.path); m.continueInstall() }
            }
            .disabled(m.running)
            Text("Existing files stay in that folder and are kept if you remove this game. Its drive must be connected to play.").font(.caption).foregroundStyle(.secondary)
        case .steam:
            HStack {
                TextField("Steam account name", text: $steamUser).frame(maxWidth: 180)
                TextField("App ID", text: $steamAppID).frame(maxWidth: 90)
                Button("Open SteamCMD") {
                    m.setInput("steamUser", steamUser); m.setInput("steamAppID", steamAppID); m.continueInstall()
                }
                .disabled(steamUser.isEmpty || Int(steamAppID) == nil || m.running)
            }
            appIDHint
        case .steamLibrary:
            Button("Open Steam Library") { app.showSteamLibrary = true }
        case .store:
            Button("Continue Download") { m.continueInstall() }.disabled(m.running)
        }
    }

    var appIDHint: some View {
        Text("The App ID is the number in the game's Steam store link (Counter-Strike: Source is 240).")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    func exePicker(_ ex: InstallExecutor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if m.exeCandidates.isEmpty {
                Text("Looking for programs…").font(.caption).foregroundStyle(.secondary)
                    .onAppear { m.refreshCandidates() }
            }
            ForEach(m.exeCandidates.prefix(6)) { c in
                Button {
                    m.setInput("exe", c.windowsPath); m.continueInstall()
                } label: {
                    HStack {
                        Image(systemName: "app.badge")
                        VStack(alignment: .leading) {
                            Text(c.url.lastPathComponent)
                            Text(c.windowsPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
            }
            Button("Choose Another…") {
                let p = NSOpenPanel()
                p.directoryURL = ex.ctx.prefix.appendingPathComponent("drive_c")
                p.allowedContentTypes = [UTType(filenameExtension: "exe")].compactMap { $0 }
                if p.runModal() == .OK, let u = p.url {
                    if let w = CustomGames.windowsPath(forUnix: u, prefix: ex.ctx.prefix) { m.setInput("exe", w); m.continueInstall() }
                    else { m.append("✗ Choose a program inside this game's C: drive.") }
                }
            }
            .buttonStyle(.link)
        }
    }

    // MARK: Footer

    var footer: some View {
        HStack {
            if let ex = m.executor {
                Button("Remove Unfinished Install…", role: .destructive) { confirmRemove = true }
                    .disabled(m.running || ex.isComplete)
                    .confirmationDialog("Remove this unfinished install?", isPresented: $confirmRemove) {
                        Button("Move to Trash", role: .destructive) {
                            m.append(ex.removeUnfinishedInstall())
                            app.refresh()
                        }
                    } message: { Text("Moves the new app (only if this install created it) to the Trash and undoes its setting changes. Existing games aren't touched.") }
            }
            Spacer()
            if m.running {
                ProgressView().controlSize(.small)
                Button(m.cancelling ? "Cancelling…" : "Cancel") { m.cancel() }.disabled(m.cancelling)
            } else if let ex = m.executor, !ex.isComplete {
                Button("Continue") { m.continueInstall() }.keyboardShortcut(.defaultAction)
            }
            Button("Close") { app.refresh(); dismiss() }.disabled(m.running)
        }
        .padding()
    }

    /// Several files at once (all of a game's discs). Disc order comes from their names.
    func pickMany(types: [String]) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.message = "Choose the game's disc image — or all of its discs (Disc 1, Disc 2…)."
        p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        return p.runModal() == .OK ? p.urls : []
    }

    func pick(folder: Bool, types: [String]) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = folder
        p.canChooseFiles = !folder
        p.allowsMultipleSelection = false
        if !types.isEmpty { p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) } }
        return p.runModal() == .OK ? p.url : nil
    }
}

struct StageRow: View {
    let info: StageInfo
    let status: StageStatus
    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch status {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running: ProgressView().controlSize(.small)
                case .needsUser: Image(systemName: "hand.raised.circle.fill").foregroundStyle(.orange)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title)
                if info.kind == .handoff { Text("Your step").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Graphics mode switcher for general games (used on the game page and in the play-test step).
struct GraphicsPicker: View {
    @EnvironmentObject var app: AppModel
    let game: InstalledGame
    var onChange: () -> Void = {}
    @State private var current: GraphicsPreset

    init(game: InstalledGame, onChange: @escaping () -> Void = {}) {
        self.game = game
        self.onChange = onChange
        _current = State(initialValue: game.custom?.graphics ?? .classic3D)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Graphics", selection: Binding(get: { current }, set: { apply($0) })) {
                ForEach(GraphicsPreset.allCases) { p in
                    Text(p.title + (p == game.custom?.confirmedGraphics ? " ✓" : "")).tag(p)
                }
            }
            .frame(maxWidth: 320)
            Text(current.detail + (current.validated ? "" : " Not yet tested by Nokcandu."))
                .font(.caption).foregroundStyle(.secondary)
            if current == .appleMetal, game.custom?.is64Bit == false {
                if isGameLauncher {
                    Label("Applies to the games this launcher starts (they must be 64-bit, like Diablo II: Resurrected). The launcher itself draws its window separately.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("This game is 32-bit; Apple Metal only works with 64-bit games.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// Store launchers (Battle.net…) start other games that inherit this graphics mode.
    var isGameLauncher: Bool {
        let exe = (game.custom?.exe ?? "").lowercased()
        return ["battle.net", "ubisoft", "upc.exe", "eadesktop", "origin.exe", "epicgameslauncher", "galaxyclient"].contains { exe.contains($0) }
    }

    func apply(_ p: GraphicsPreset) {
        guard var c = game.custom, p != c.graphics else { return }
        c.graphics = p
        do {
            try CustomGames.save(c, to: game)
            current = p
            app.say("Graphics: \(p.title). Open the game to try it.")
            app.refresh()
            onChange()
        } catch { app.fail(error) }
    }
}


/// While a multi-disc game installs: which disc is in D:, and buttons to swap when setup asks.
struct DiscSwapBar: View {
    let ex: InstallExecutor
    @State private var current = 0
    @State private var error: String?
    @State private var running = false

    var images: [String] { (ex.ctx.state.inputs["disc.images"] ?? "").split(separator: "\n").map(String.init) }

    var body: some View {
        if images.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "opticaldisc")
                    Text("Drive D: has Disc \(current + 1) of \(images.count).").font(.callout)
                    ForEach(images.indices, id: \.self) { i in
                        if i != current {
                            Button("Insert Disc \(i + 1)") { insert(i) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("Expansion discs with their own setup:").font(.caption).foregroundStyle(.secondary)
                    ForEach(images.indices.dropFirst(), id: \.self) { i in
                        Button("Run Setup from Disc \(i + 1)") { runSetup(i) }.disabled(running)
                    }
                    if running { ProgressView().controlSize(.small) }
                }
                Text("When setup asks for another disc, insert it here, then continue in setup. Expansions: install the base game first, then run each expansion disc's setup.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { current = Discs.current(support: ex.ctx.support) }
        }
    }

    func insert(_ i: Int) {
        do { try Discs.insert(i, images: images, support: ex.ctx.support, prefix: ex.ctx.prefix); current = i; error = nil }
        catch { self.error = error.localizedDescription }
    }

    func runSetup(_ i: Int) {
        let ctx = ex.ctx, imgs = images
        running = true; current = i
        Task {
            do { try await Discs.runSetup(i, images: imgs, support: ctx.support, prefix: ctx.prefix, env: ctx.wineEnvironment, log: ctx.log); error = nil }
            catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

/// "Install to:" — the library folders, plus adding another (e.g. on an external drive).
struct InstallFolderPicker: View {
    @Binding var folder: URL
    @State private var folders = GameFolders.all
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Install to", selection: Binding(get: { folder.standardizedFileURL }, set: { pick($0) })) {
                ForEach(folders, id: \.self) { f in
                    Text(GameFolderLabel.text(f)).tag(f).disabled(!GameFolders.isAvailable(f))
                }
                Divider()
                Text("Other Folder…").tag(URL(fileURLWithPath: "/__other__"))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            else {
                let free = GameFolders.freeSpace(folder).map { Storage.format($0) + " free" } ?? ""
                Text("\(GameFolders.volumeName(folder)) · \(free)"
                     + (GameFolders.holdsApps(folder) ? "" : " · \(GameFolders.formatName(folder)) drive: the game's files go here, its small app stays on this Mac"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func pick(_ u: URL) {
        error = nil
        guard u.path == "/__other__" else { folder = u; GameFolders.setInstallFolder(u); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where to install games. Picking a whole drive makes a “Nokcandu Games” folder on it."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        do {
            let added = try GameFolders.add(picked)
            folders = GameFolders.all
            folder = added
            GameFolders.setInstallFolder(added)
        } catch { self.error = error.localizedDescription }
    }
}

enum GameFolderLabel {
    static func text(_ f: URL) -> String {
        let path = f.path.replacingOccurrences(of: NokPaths.home.path, with: "~")
        if GameFolders.isStandard(f) { return "Standard folder (\(path))" }
        if !GameFolders.isAvailable(f) { return "\(path) — not connected" }
        let filesOnly = GameFolders.holdsApps(f) ? "" : " (game files only)"
        if f.path.hasPrefix("/Volumes/") { return "\(GameFolders.volumeName(f)): \(f.lastPathComponent)\(filesOnly)" }
        return path + filesOnly
    }
}
