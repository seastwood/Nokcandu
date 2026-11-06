import SwiftUI
import AppKit
import NokcanduCore

@main
struct NokcanduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    init() { ListCache.installImageCache() }      // store artwork loads once, not on every visit

    var body: some Scene {
        WindowGroup("Nokcandu") {
            LibraryView()
                .environmentObject(model)
                .onOpenURL { url in model.openURL(url) }
                // Links (nokcandu://, battlenet://) go to the open window instead of opening another one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .frame(minWidth: 860, minHeight: 680)
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add a Game…") { model.showInstaller = true }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Game Stores…") { model.openStores() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Refresh Library") { model.refresh() }.keyboardShortcut("r")
                Button("Check for Game Updates") { Task { await model.checkStoreUpdates(); model.say(model.storeUpdates.isEmpty ? "Your GOG and Epic games are up to date." : "\(model.storeUpdates.count) game update(s) available.") } }
                Button("Updates…") { model.showUpdates = true }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Setup Checklist…") { model.showWelcome = true }
            }
            CommandMenu("Game") {
                GameCommands(model: model)
            }
            CommandGroup(after: .help) {
                Button("Report a Problem…") { model.showReport = true }
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
        Window("Game Installation", id: "installer") {
            InstallerView(m: model.installer).environmentObject(model)
                .handlesExternalEvents(preferring: [], allowing: [])
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        Window("Game Stores", id: "stores") {
            StoreLibraryView().environmentObject(model)
                .handlesExternalEvents(preferring: [], allowing: [])
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built as a plain SwiftPM executable: make sure it behaves like a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func showSettings(_ tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        openSettings()
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                if !model.favoriteGames.filter(model.matchesLibrary).isEmpty {
                    Section("Favorites") {
                        ForEach(model.favoriteGames.filter(model.matchesLibrary)) { g in row(g) }
                    }
                }
                Section {
                    ForEach(model.sortedGames.filter(model.matchesLibrary)) { g in row(g) }
                        .onMove { model.moveGames(from: $0, to: $1) }
                        .moveDisabled(filtering)
                } header: {
                    Text("Games")
                }
                if !model.offlineApps.isEmpty {
                    Section("Drive not connected") {
                        ForEach(model.offlineApps.indices, id: \.self) { i in
                            let o = model.offlineApps[i]
                            HStack(spacing: 10) {
                                Image(systemName: "externaldrive.badge.xmark").font(.title2).foregroundStyle(.orange).frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.name).font(.headline).foregroundStyle(.secondary)
                                    Text("Connect \(o.drive) to play").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 2)
                            .selectionDisabled()
                        }
                    }
                }
                if !model.launcherApps.filter(model.matchesLibrary).isEmpty {
                    Section("Launchers") {
                        ForEach(model.launcherApps.filter(model.matchesLibrary)) { g in row(g) }
                    }
                }
            }
            // The list's own primary action: double-click (or Return) plays, without the extra tap
            // recognizer that delayed or swallowed single clicks on rows.
            .contextMenu(forSelectionType: InstalledGame.ID.self) { ids in
                if let id = ids.first, let g = model.games.first(where: { $0.id == id }) { GameContextMenu(game: g) }
            } primaryAction: { ids in
                guard let id = ids.first, let g = model.games.first(where: { $0.id == id }) else { return }
                if !model.isRunning(g) || g.isSteamHost { model.play(g) }
            }
            .searchable(text: $model.librarySearch, placement: .sidebar, prompt: "Search games")
            .modifier(SearchFocusModifier(request: $model.focusSearch))
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .modifier(SoftTopEdge())
            .toolbar {
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Sort By", selection: Binding(get: { model.sortMode }, set: { model.setSort($0) })) {
                            ForEach(LibraryOrganizer.Sort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Text("Drag games to put them in your own order.")
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuIndicator(.hidden)
                    .help("Sort games")
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Show", selection: $model.libraryFilter) {
                            ForEach([AppModel.LibraryFilter.all, .running, .windows, .mac, .steam, .battleNet] + model.driveFilters) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: model.libraryFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .menuIndicator(.hidden)
                    .help(model.libraryFilter == .all ? "Show only some games" : "Showing: \(model.libraryFilter.title)")
                }
                ToolbarItem(placement: .automatic) { ActivityButton() }
                ToolbarItem(placement: .automatic) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .overlay(alignment: .topTrailing) {
                                if model.updateCount > 0 { Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                            }
                    }
                    .help(model.updateCount > 0 ? "Settings — \(model.updateCount) update\(model.updateCount == 1 ? "" : "s") available" : "Settings")
                }
            }
            .overlay {
                if filtering && model.games.allSatisfy({ !model.matchesLibrary($0) }) {
                    ContentUnavailableView.search(text: model.librarySearch)
                } else if model.libraryLoaded && model.games.isEmpty {
                    ContentUnavailableView("No games yet", systemImage: "gamecontroller",
                                           description: Text("Install a game or set up Steam with the buttons below. Game apps live in \(NokPaths.gameAppsFolder.path.replacingOccurrences(of: NokPaths.home.path, with: "~"))."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { model.openStores() } label: {
                        Label("Game Stores…", systemImage: "bag")
                    }
                    InstallationShortcut(m: model.installer) { model.showInstaller = true }
                    Button { model.showInstaller = true } label: {
                        Label("Add a Game…", systemImage: "plus.circle")
                    }
                    Button { model.profileFocus = nil; model.showProfiles = true } label: {
                        Label("Game Profiles…", systemImage: "square.stack.3d.up")
                    }
                }
                .buttonStyle(.borderless)
                .labelStyle(AlignedIconLabelStyle())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let g = model.selectedGame {
                GameDetailView(game: g).id(g.id)
            } else {
                ContentUnavailableView("Choose a game", systemImage: "gamecontroller")
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .onChange(of: model.showInstaller) {
            if model.showInstaller { openWindow(id: "installer"); model.showInstaller = false }
        }
        .sheet(item: $model.renaming) { g in RenameGameSheet(game: g).environmentObject(model) }
        .sheet(item: $model.movingGame) { g in MoveGameSheet(game: g).environmentObject(model) }
        .alert("Quit \(model.quitting?.name ?? "the game")?", isPresented: Binding(get: { model.quitting != nil }, set: { if !$0 { model.quitting = nil } }),
               presenting: model.quitting) { g in
            Button("Quit", role: .destructive) { model.quit(g); model.quitting = nil }
            Button("Always Quit Without Asking") { model.quitWithoutAsking = true; model.quit(g); model.quitting = nil }
            Button("Cancel", role: .cancel) { model.quitting = nil }
        } message: { g in
            Text((g.native != nil ? "Unsaved progress may be lost." : GameLauncher.quitScope(g)) + " You can turn asking back on in Settings → General.")
        }
        .sheet(isPresented: $model.showReport) { ReportProblemView(game: model.selectedGame).environmentObject(model) }
        .sheet(isPresented: $model.showWelcome) {
            WelcomeView().environmentObject(model)
        }
        .sheet(isPresented: $model.showProfiles) {
            ProfilesView(focusNumber: model.profileFocus).environmentObject(model)
        }
        .onChange(of: model.showStorage) { if model.showStorage { showSettings("storage"); model.showStorage = false } }
        .onChange(of: model.showUpdates) { if model.showUpdates { showSettings("updates"); model.showUpdates = false } }
        .onChange(of: model.showSteamLibrary) {
            if model.showSteamLibrary { UserDefaults.standard.set(StoreTab.steam.rawValue, forKey: "storeTab"); openWindow(id: "stores"); model.showSteamLibrary = false }
        }
        .onChange(of: model.showStores) {
            // Its own window rather than a sheet: as a sheet, its scrolling game list sent SwiftUI into an endless update loop.
            if model.showStores { openWindow(id: "stores"); model.showStores = false }
        }
        .overlay(alignment: .bottom) {
            if let b = model.banner {
                BannerView(banner: b) {
                    if model.banner?.id == b.id { model.banner = nil }
                }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
    }
}

extension LibraryView {
    var filtering: Bool { !model.librarySearch.isEmpty || model.libraryFilter != .all }
    func row(_ g: InstalledGame) -> some View {
        GameRow(game: g, state: model.runStates[g.id] ?? .notRunning)
            .tag(g.id)
            .contentShape(Rectangle())
    }
}

struct GameContextMenu: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    var body: some View {
        if model.isRunning(game) {
            if game.isSteamHost { Button("Show Steam") { model.play(game) } }
            Button("Quit…") { model.requestQuit(game) }
            Divider()
        } else {
            Button(game.isSteamHost ? "Open Steam" : "Play") { model.play(game) }
            Divider()
        }
        if !LibraryOrganizer.isLauncher(game) {
            let fav = model.favoriteGames.contains(game)
            Button(fav ? "Remove from Favorites" : "Add to Favorites") { model.setFavorite(game, !fav) }
        }
        Button("Rename…") { model.renaming = game }
        Button("Show in Finder") { model.reveal(game.appURL) }
        if game.native == nil {
            Button("Move…") { model.movingGame = game }.disabled(model.moving.contains(game.id))
        }
    }
}

struct GameRow: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    let state: RunState

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: game.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(model.missingDrive[game.id] != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 2)
    }

    var subtitle: String {
        if case .launcherRunning = state { return "Running" }
        if state == .unknown { return "Status unavailable" }
        if model.moving.contains(game.id) { return model.moveStatus[game.id] ?? "Moving…" }
        if let d = model.missingDrive[game.id] { return "Connect \(d) to play" }
        if let u = model.updating[game.id] { return "Updating" + (u.progress.map { " · \($0.label)" } ?? "…") }
        if model.storeUpdates[game.id] != nil { return "Update available" }
        if let custom = model.subtitles[game.id] { return custom }
        var s: String
        if let n = game.native { s = n.store.map { "Mac game · \($0.store.title)" } ?? "Mac game" }
        else if game.isSteamHost { s = "Shared Steam" }
        else if BattleNet.isHost(game) { s = "Battle.net" }
        else if game.usesSharedSteam { s = "Steam game" }
        else if game.battleNet != nil { s = "Battle.net game" }
        else if let k = PCLaunchers.kind(of: game) { s = k.title }
        else if let h = game.hosted { s = "\(h.launcher.title) game" }
        else { s = game.isManaged ? "Ready" : "Not set up by Nokcandu" }
        let folder = GameFolders.folder(of: game)
        if !GameFolders.isStandard(folder), folder.path.hasPrefix("/Volumes/") { s += " · " + GameFolders.volumeName(folder) }
        else if let ext = GameMover.externalFiles(game), ext.path.hasPrefix("/Volumes/") { s += " · " + ext.pathComponents[2] }
        return s
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
            Text(banner.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
        .task(id: banner.id) {
            // An old progress task is cancelled when an error replaces it.
            // Cancellation must never dismiss the new banner; errors stay put.
            guard !banner.isError else { return }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}

/// Icons in a fixed-width column so the titles line up, whatever each symbol's width.
struct AlignedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.frame(width: 18, alignment: .center)
            configuration.title
        }
    }
}

/// Disclosure groups that open from anywhere on their title row, not just the small arrow.
struct WholeRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content.padding(.leading, 18)
            }
        }
    }
}

/// Rename a game and give it your own subtitle. Matching with profiles, fixes and anti-cheat data keeps
/// using the game's real title, so a short name like "CS2" doesn't lose anything.
struct RenameGameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let game: InstalledGame
    @State private var name = ""
    @State private var subtitle = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(game.name)").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Subtitle (optional — leave empty for the usual status)", text: $subtitle).textFieldStyle(.roundedBorder)
            Text("Shown in Nokcandu, the Dock and Finder. Nokcandu still recognizes it as “\(LibraryOrganizer.canonicalName(game))” for profiles, known fixes and anti-cheat info.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try LibraryOrganizer.rename(game, to: name, subtitle: subtitle)
                        model.refresh()
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { name = game.name; subtitle = LibraryOrganizer.subtitle(game) ?? "" }
    }
}


/// The sidebar's top edge while scrolled: a soft fade under the title bar rather than a hard line across it.
/// The line itself is the title bar separator AppKit draws over the sidebar once its list scrolls; it's turned
/// off for the window and for each split-view column.
struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        let base = content.background(NoTitlebarSeparator())
        if #available(macOS 26.0, *) { base.scrollEdgeEffectStyle(.soft, for: .top) } else { base }
    }
}

private struct NoTitlebarSeparator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }
        func apply() {
            guard let window else { return }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            var vc = window.contentViewController
            var seen = 0
            while let c = vc, seen < 8 {
                if let split = c as? NSSplitViewController {
                    for item in split.splitViewItems where item.titlebarSeparatorStyle != .none { item.titlebarSeparatorStyle = .none }
                    break
                }
                vc = c.children.first; seen += 1
            }
            // SwiftUI may host the split view controller deeper; search the whole tree once.
            func walk(_ c: NSViewController) {
                if let split = c as? NSSplitViewController {
                    for item in split.splitViewItems where item.titlebarSeparatorStyle != .none { item.titlebarSeparatorStyle = .none }
                }
                c.children.forEach(walk)
            }
            if let root = window.contentViewController { walk(root) }
        }
    }
}
