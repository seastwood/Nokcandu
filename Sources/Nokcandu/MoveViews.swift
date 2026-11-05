import SwiftUI
import AppKit
import NokcanduCore

/// "Move…": shows what a game is made of, where each part is, and lets you choose where each goes.
struct MoveGameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame

    enum AppChoice: Hashable { case keep, folder(URL) }
    enum FilesChoice: Hashable { case keep, withApp, folder(URL) }

    @State private var plan: MovePlan?
    @State private var appChoice: AppChoice = .keep
    @State private var filesChoice: FilesChoice = .keep
    @State private var removeOldPoints = true
    @State private var dropRollback = false
    @State private var extraFolders: [URL] = []
    @State private var appFolders: [URL] = []
    @State private var fileFolders: [URL] = []
    @State private var problem: String?
    @State private var contentHeight: CGFloat = 0
    /// Leaves room for the title, summary and buttons inside the main window.
    var maxContentHeight: CGFloat { max(260, (NSApp.mainWindow?.frame.height ?? 720) - 230) }
    struct ContentHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move \(game.name)").font(.title2.bold())
            if let plan {
                // As tall as its contents, scrolling only when the window is too short for all of them.
                ScrollView {
                    content(plan).frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { g in Color.clear.preference(key: ContentHeight.self, value: g.size.height) })
                }
                .frame(height: min(max(contentHeight, 120), maxContentHeight))
                .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
                Divider()
                Text(summary(plan)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Move") { start(plan) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasWork(plan) || blocked(plan) != nil)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Measuring \(game.name)…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 160)
                HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(22)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
    }

    @ViewBuilder func content(_ plan: MovePlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    partHeader(plan.isLauncher ? "\(plan.name) and everything installed in it" : "The app",
                               bytes: plan.appBytes - (plan.filesExternal ? 0 : plan.filesBytes),
                               detail: plan.isLauncher
                                ? "Its Wine engine, Windows setup, sign-in and settings" + (plan.passengers.isEmpty ? "." : ", and the games installed inside it: \(plan.passengers.joined(separator: ", ")).")
                                : "Wine engine, Windows setup (registry, settings, saves kept inside Windows) and Nokcandu's settings. Needs a Mac-formatted drive (APFS or Mac OS Extended).")
                    location("Now", plan.appLocation.deletingLastPathComponent())
                    if let b = plan.appBlocker {
                        SettingNote(b, warning: true)
                    } else {
                        Picker("Move to", selection: $appChoice) {
                            Text("Keep it where it is").tag(AppChoice.keep)
                            ForEach(appFolders, id: \.self) { f in Text(label(f)).tag(AppChoice.folder(f)) }
                        }
                        .pickerStyle(.radioGroup)
                        HStack {
                            Button("Choose Another Folder…") { chooseAppFolder() }
                            Spacer()
                            if appFolders.isEmpty {
                                Text("No other Mac-formatted drive is connected. On an ExFAT drive, create an APFS games volume in Storage → Drives.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("It stays in your Applications folder (as a link to the drive)" + (plan.isLauncher ? ", so every game set up in \(plan.name) keeps working." : ".") + " Keep the drive connected to play.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(6)
            }
            if !plan.isLauncher, plan.filesLocation != nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        partHeader("The game's files", bytes: plan.filesBytes,
                                   detail: "The game's own folder. These can live on any drive, ExFAT included; the app keeps a link to them.")
                        if let loc = plan.filesLocation {
                            location("Now", plan.filesExternal ? loc.deletingLastPathComponent() : loc, inside: !plan.filesExternal)
                        }
                        if plan.filesAllocated > plan.filesBytes + 200_000_000 {
                            SettingNote("On this drive they take \(Storage.format(plan.filesAllocated)): ExFAT stores each small file in a large block. On APFS they'd take about \(Storage.format(plan.filesBytes)).", warning: true)
                        }
                        if let b = plan.filesBlocker {
                            SettingNote(b, warning: false)
                        } else {
                            Picker("Move to", selection: $filesChoice) {
                                Text("Keep them where they are").tag(FilesChoice.keep)
                                if plan.filesExternal { Text("Inside the app (wherever it goes)").tag(FilesChoice.withApp) }
                                ForEach(fileFolders, id: \.self) { f in Text(label(f)).tag(FilesChoice.folder(f)) }
                            }
                            .pickerStyle(.radioGroup)
                            Button("Choose Another Folder…") { chooseFilesFolder() }
                        }
                    }.padding(6)
                }
            }
            if plan.restorePoints > 0 || plan.rollbackBytes > 0 {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Also").font(.headline)
                        if plan.restorePoints > 0 {
                            Toggle(isOn: $removeOldPoints) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Remove its \(plan.restorePoints) restore point\(plan.restorePoints == 1 ? "" : "s") from \(Storage.driveName(plan.appLocation)) after moving (at least \(Storage.format(plan.restorePointBytes)))")
                                    Text("Restore points only work on the drive they were taken on. A fresh one is taken on the new drive (it costs no space there).")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(appChoice == .keep)
                        }
                        if plan.rollbackBytes > 0 {
                            Toggle(isOn: $dropRollback) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Keep the new Wine engine and drop the old one's copy (\(Storage.format(plan.rollbackBytes)))")
                                    Text("While a new engine is being tried, the old one is kept for rolling back. Moved to another drive, that copy takes full space there.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding(6)
                }
            }
        }
    }

    func partHeader(_ title: String, bytes: Int64, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.headline); Spacer(); Text(Storage.format(max(bytes, 0))).monospacedDigit().foregroundStyle(.secondary) }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func location(_ title: String, _ url: URL, inside: Bool = false) -> some View {
        Text("\(title): " + (inside ? "inside the app" : "\(Storage.driveName(url)) · \(url.path.replacingOccurrences(of: NokPaths.home.path, with: "~"))"))
            .font(.caption).textSelection(.enabled)
    }

    func label(_ f: URL) -> String {
        let format = GameFolders.formatName(f)
        return GameFolderLabel.text(f).replacingOccurrences(of: " (game files only)", with: "") + " — \(format)"
    }

    var request: MoveRequest {
        let app: URL? = { if case .folder(let u) = appChoice { return u }; return nil }()
        let files: FilesDestination = {
            switch filesChoice { case .keep: return .keep; case .withApp: return .withApp; case .folder(let u): return .folder(u) }
        }()
        return MoveRequest(appFolder: app, files: files, keepOldRestorePoints: !removeOldPoints, dropRollbackCopy: dropRollback)
    }

    func hasWork(_ plan: MovePlan) -> Bool { appChoice != .keep || filesChoice != .keep || dropRollback }

    func blocked(_ plan: MovePlan) -> String? {
        if appChoice != .keep, let b = plan.appBlocker { return b }
        if filesChoice != .keep, let b = plan.filesBlocker { return b }
        return nil
    }

    func summary(_ plan: MovePlan) -> String {
        var lines: [String] = []
        let filesInside = !plan.filesExternal && plan.filesLocation != nil
        if case .folder(let f) = filesChoice {
            lines.append("Copies the game's files (\(Storage.format(plan.filesBytes))) to \(GameFolders.volumeName(f)), checks every file, then removes them from \(plan.filesExternal ? Storage.driveName(plan.filesLocation!) : "the app").")
        }
        if case .folder(let f) = appChoice {
            var bytes = plan.appBytes
            if filesInside, case .folder = filesChoice { bytes -= plan.filesBytes }
            lines.append("Copies \(plan.isLauncher ? plan.name + " (with its games)" : "the app") — about \(Storage.format(max(bytes, 0))) — to \(GameFolders.volumeName(f)), checks it, then removes it from \(Storage.driveName(plan.appLocation)).")
            if filesInside, filesChoice == .keep { lines.append("The game's files are inside the app, so they go too.") }
        }
        if filesChoice == .withApp { lines.append("Brings the game's files back inside the app.") }
        if dropRollback { lines.append("Removes the old engine's copy.") }
        if lines.isEmpty { return "Choose where the app or its files should go. Nothing is removed until its copy has been checked." }
        return lines.joined(separator: " ") + " Keep the drive connected to play."
    }

    func load() async {
        let g = game, library = model.games
        let result = await Task.detached(priority: .userInitiated) { () -> (MovePlan, [URL], [URL]) in
            let plan = GameMover.plan(for: g, library: library)
            let here = plan.appLocation.deletingLastPathComponent().resolvingSymlinksInPath()
            let folders = GameFolders.all.filter(GameFolders.isAvailable)
            let apps = folders.filter { GameFolders.holdsApps($0) && $0.resolvingSymlinksInPath() != here }
            let filesHere = plan.filesExternal ? plan.filesLocation?.deletingLastPathComponent().resolvingSymlinksInPath() : nil
            let files = folders.filter { $0.resolvingSymlinksInPath() != filesHere }
            return (plan, apps, files)
        }.value
        plan = result.0; appFolders = result.1; fileFolders = result.2
        // Opened from "files waste space on ExFAT": suggest bringing them onto the app's Mac-formatted drive.
        if model.moveSuggestsFilesWithApp == game.id {
            model.moveSuggestsFilesWithApp = nil
            if result.0.filesExternal, GameFolders.holdsApps(result.0.appLocation) { filesChoice = .withApp }
        }
    }

    func chooseAppFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder on a Mac-formatted drive (APFS or Mac OS Extended) for \(game.name). Picking a whole drive makes a “Nokcandu Games” folder on it."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        guard GameFolders.holdsApps(picked) else {
            problem = "\(GameFolders.volumeName(picked)) is \(GameFolders.formatName(picked)): whole apps need APFS or Mac OS Extended. Put just the game's files there, or create an APFS games volume on it in Storage → Drives."
            return
        }
        do {
            let folder = try GameFolders.add(picked)
            if !appFolders.contains(folder) { appFolders.append(folder) }
            appChoice = .folder(folder); problem = nil
        } catch { problem = error.localizedDescription }
    }

    func chooseFilesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where \(game.name)'s files should go (any drive)."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        if let p = GameFolders.problem(with: picked) { problem = p; return }
        if !fileFolders.contains(picked) { fileFolders.append(picked) }
        filesChoice = .folder(picked); problem = nil
    }

    func start(_ plan: MovePlan) {
        model.moveSuggestsFilesWithApp = nil
        model.performMove(game, request)
        dismiss()
    }
}

extension AppModel {
    /// Runs a move in the background; the sidebar shows its progress.
    func performMove(_ g: InstalledGame, _ request: MoveRequest) {
        guard !moving.contains(g.id) else { return }
        moving.insert(g.id)
        moveStatus[g.id] = "Preparing…"
        say("Moving \(g.name)… You can keep using Nokcandu.")
        let library = games
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                Result { try GameMover.perform(g, request, library: library, progress: { line in
                    Task { @MainActor in self.moveStatus[g.id] = line }
                }) }
            }.value
            moving.remove(g.id)
            moveStatus[g.id] = nil
            await StorageInventory.shared.invalidate()
            switch r {
            case .success(let done):
                refresh()
                selection = done.app.path
                say(done.notes.isEmpty ? "Nothing needed to move." : done.notes.joined(separator: " "))
            case .failure(let e): fail(e); refresh()
            }
        }
    }
}
