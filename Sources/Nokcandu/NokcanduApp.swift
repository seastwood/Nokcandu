import SwiftUI
import AppKit
import NokcanduCore

@main
struct NokcanduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarSetting.key) private var menuBarMenu = true
    init() { ListCache.installImageCache() }      // store artwork loads once, not on every visit

    var body: some Scene {
        WindowGroup("Nokcandu", id: "library") {
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
                Button("Add a Folder of Games…") { model.chooseFolderOfGames() }
                Button("Game Stores…") { model.openStores() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Refresh Library") { model.refresh() }.keyboardShortcut("r")
                Button("Check for Game Updates") { Task { await model.checkStoreUpdates(); model.say(model.storeUpdates.isEmpty ? "Your GOG and Epic games are up to date." : "\(model.storeUpdates.count) game update(s) available.") } }
                Button("Updates…") { model.showUpdates = true }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Setup Checklist…") { model.welcomePage = .games; model.showWelcome = true }
            }
            CommandMenu("Game") {
                GameCommands(model: model)
            }
            CommandMenu("Stream") { StreamCommands() }
            CommandGroup(after: .help) {
                Button("Getting Started…") { model.welcomePage = .choose; model.showWelcome = true }
                Button("Controller Input Test…") { openWindow(id: "pad-input-test") }
                Button("What's New in Nokcandu") { model.showWhatsNew = true }
                Button("Report a Problem…") { model.showReport = true }
            }
        }
        Window("Controller Input Test", id: "pad-input-test") { PadInputTest() }
        Settings {
            SettingsView().environmentObject(model)
        }
        MenuBarExtra("Nokcandu", systemImage: "gamecontroller", isInserted: $menuBarMenu) {
            MenuBarMenu().environmentObject(model)
        }
        Window("Game Installation", id: "installer") {
            InstallerView(m: model.installer).environmentObject(model)
                .handlesExternalEvents(preferring: [], allowing: [])
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        WindowGroup("Controller Profile", id: "padprofile", for: PadEditorTarget.self) { $target in
            if let target { ControllerProfileWindow(target: target).environmentObject(model) }
        }
        .defaultSize(width: 1100, height: 760)
        .handlesExternalEvents(matching: [])
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
        // `kill` (and tools that end apps with it) quits Nokcandu like the Quit command does, so a running
        // stream is ended properly instead of vanishing from the host. A forced kill can't be caught.
        for number in [SIGTERM, SIGINT] {
            // A handler that does nothing, not "ignore": an ignored signal stays ignored in every game and tool
            // Nokcandu starts, which could then no longer be ended with it.
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            quitSignals.append(source)
        }
    }
    private var quitSignals: [DispatchSourceSignal] = []
    private var endingStream = false
    /// Quit (the command, logging out, shutting down, an update): a running stream is ended first, the way End
    /// Stream does, and Nokcandu quits when the host has been told, or after five seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if endingStream { return .terminateLater }
            guard StreamsModel.shared.endStreamBeforeQuit(then: { NSApp.reply(toApplicationShouldTerminate: true) }) else { return .terminateNow }
            endingStream = true
            return .terminateLater
        }
    }
    /// With the menu bar menu on, Nokcandu keeps running after its window closes (the menu brings it back).
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { StreamsModel.shared.endStreamForQuit(); PadProfileEdits.shared.flushAll(); MacGameKeys.shared.stop(); DesktopPad.shared.stop() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarSetting.on }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var categoryName = ""

    func expanded(_ id: String) -> Binding<Bool> {
        // Searching shows matches even inside a collapsed section.
        filtering ? .constant(true) : model.sectionExpanded(id)
    }

    func showSettings(_ tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        openSettings()
    }

    @ViewBuilder var gamesList: some View {
        List(selection: $model.selection) {
            if !model.favoriteGames.filter(model.matchesLibrary).isEmpty {
                Section("Favorites") {
                    ForEach(model.favoriteGames.filter(model.matchesLibrary)) { g in row(g) }
                }
            }
            ForEach(model.libraryCategories) { c in
                // While searching or filtering, a category with nothing to show steps aside.
                if !filtering || c.games.contains(where: model.matchesLibrary) {
                    Section(isExpanded: expanded("category:" + c.name)) {
                        ForEach(c.games.filter(model.matchesLibrary)) { g in row(g) }
                        if c.games.isEmpty {
                            Text("Right-click anything in the library to put it here.")
                                .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                        }
                    } header: {
                        Text(c.name).contextMenu { CategoryMenu(name: c.name) }
                            .draggable(AppModel.categoryDragPrefix + c.name)
                            .dropDestination(for: String.self) { items, _ in model.dropOnSection(items, category: c.name) }
                            .help("Drop a game here to put it in \(c.name). Drag this title onto another category to move it there.")
                    }
                }
            }
            Section(isExpanded: expanded("games")) {
                ForEach(model.sortedGames.filter(model.matchesLibrary)) { g in row(g) }
                    .onMove { model.moveGames(from: $0, to: $1) }
                    .moveDisabled(filtering)
            } header: {
                Text("Games").dropDestination(for: String.self) { items, _ in model.dropOnSection(items, category: nil) }
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
                Section(isExpanded: expanded("launchers")) {
                    ForEach(model.launcherApps.filter(model.matchesLibrary)) { g in row(g) }
                } header: {
                    Text("Launchers").dropDestination(for: String.self) { items, _ in model.dropOnSection(items, category: nil) }
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
        .modifier(SoftTopEdge())
        .overlay {
            if filtering && model.games.allSatisfy({ !model.matchesLibrary($0) }) {
                ContentUnavailableView.search(text: model.librarySearch)
            } else if model.libraryLoaded && model.games.isEmpty {
                ContentUnavailableView("No games yet", systemImage: "gamecontroller",
                                       description: Text("Install a game or set up Steam with the buttons below. Game apps live in \(NokPaths.gameAppsFolder.path.replacingOccurrences(of: NokPaths.home.path, with: "~"))."))
            }
        }
        .modifier(SidebarFooter {
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
        })
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Show", selection: $model.sidebarTab) {
                        Text("Games").tag(AppModel.SidebarTab.games)
                        Text("Controls").tag(AppModel.SidebarTab.profiles)
                        Text("Streams").tag(AppModel.SidebarTab.streams)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    if model.sidebarTab == .games {
                        SidebarGameSearch(query: $model.librarySearch, focusRequest: $model.focusSearch)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Group {
                    switch model.sidebarTab {
                    case .profiles: ProfilesSidebar()
                    case .streams: StreamsSidebar()
                    case .games: gamesList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
            .navigationSplitViewColumnWidth(min: 236, ideal: 260)
            .toolbar {
                if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
                // Sort and filter share one button so the sidebar's buttons all fit when it's narrow. They only
                // apply to the games list, so the button is only there on the Games tab (it used to show, and do
                // nothing visible, over Controls and Streams). It sits left of the other two, which stay put.
                if model.sidebarTab == .games { ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker("Show", selection: $model.libraryFilter) {
                            ForEach([AppModel.LibraryFilter.all, .running, .windows, .mac, .steam, .battleNet] + model.driveFilters) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Picker("Sort By", selection: Binding(get: { model.sortMode }, set: { model.setSort($0) })) {
                            ForEach(LibraryOrganizer.Sort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Text("Drag games to put them in your own order.")
                        Divider()
                        Button("New Category…") { model.categoryPrompt = .init(renaming: nil, game: nil) }
                    } label: {
                        Image(systemName: model.libraryFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .menuIndicator(.hidden)
                    .help(model.libraryFilter == .all ? "Show and sort games" : "Showing: \(model.libraryFilter.title)")
                    .accessibilityLabel(model.libraryFilter == .all ? "Show and sort games" : "Show and sort games, showing \(model.libraryFilter.title)")
                } }
                ToolbarItem(placement: .automatic) { ActivityButton() }
                ToolbarItem(placement: .automatic) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .overlay(alignment: .topTrailing) {
                                if model.updateCount > 0 { Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                            }
                    }
                    .help(model.updateCount > 0 ? "Settings — \(model.updateCount) update\(model.updateCount == 1 ? "" : "s") available" : "Settings")
                    .accessibilityLabel(model.updateCount > 0 ? "Settings, \(model.updateCount) update\(model.updateCount == 1 ? "" : "s") available" : "Settings")
                }
            }
        } detail: {
            if model.sidebarTab == .profiles {
                ProfilesTabDetail()
            } else if model.sidebarTab == .streams {
                StreamsDetail()
            } else if let g = model.selectedGame {
                GameDetailView(game: g).id(g.id)
            } else {
                ContentUnavailableView("Choose a game", systemImage: "gamecontroller")
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { RunningStrip() }
        }
        .alert(model.categoryPrompt?.renaming == nil ? "New Category" : "Rename Category",
               isPresented: Binding(get: { model.categoryPrompt != nil }, set: { if !$0 { model.categoryPrompt = nil } })) {
            TextField("Name", text: $categoryName)
            Button(model.categoryPrompt?.renaming == nil ? "Add" : "Rename") { model.finishCategoryPrompt(categoryName) }
                .disabled(categoryName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { model.categoryPrompt = nil }
        } message: {
            Text("A category is a section of your own in the sidebar, for games, launchers or anything else you installed.")
        }
        .onChange(of: model.categoryPrompt != nil) { _, open in if open { categoryName = model.categoryPrompt?.renaming ?? "" } }
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
        .modifier(LibrarySheets(model: model))
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
            .draggable(g.id)
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
        let current = model.libraryCategories.first { $0.games.contains(game) }?.name
        Menu("Category") {
            Toggle("None", isOn: Binding(get: { current == nil }, set: { if $0 { model.setCategory(game, nil) } }))
            ForEach(model.libraryCategories) { c in
                Toggle(c.name, isOn: Binding(get: { current == c.name }, set: { model.setCategory(game, $0 ? c.name : nil) }))
            }
            Divider()
            Button("New Category…") { model.categoryPrompt = .init(renaming: nil, game: game) }
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
                .overlay(alignment: .bottomTrailing) { if running { RunningDot(size: 10).offset(x: 2, y: 2) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).lineLimit(1)
                    .foregroundStyle(running ? AnyShapeStyle(.green) : model.missingDrive[game.id] != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(running ? "Running" : "")
    }

    var running: Bool { if case .launcherRunning = state { return true }; return false }

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

struct DroppedFolder: Identifiable { var url: URL; var id: String { url.path } }


/// The library window's sheets and alerts, kept apart so the window's own view stays quick to type-check.
struct LibrarySheets: ViewModifier {
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
            content
            .sheet(isPresented: $model.showReport) { ReportProblemView(game: model.selectedGame).environmentObject(model) }
            .sheet(isPresented: $model.showWelcome) {
                WelcomeView().environmentObject(model)
            }
            .sheet(isPresented: $model.showWhatsNew) { WhatsNewView() }
            .sheet(isPresented: $model.showSeveralGames) { SeveralGamesSheet().environmentObject(model) }
            .sheet(item: Binding(get: { model.droppedFolder.map(DroppedFolder.init) }, set: { model.droppedFolder = $0?.url })) { d in
                DropFolderSheet(folder: d.url).environmentObject(model)
            }
            .sheet(item: Binding(get: { model.folderOfGames.map(FolderOfGamesItem.init) }, set: { model.folderOfGames = $0?.url })) { f in
                FolderOfGamesSheet(root: f.url).environmentObject(model)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                let group = DispatchGroup(); var urls: [URL] = []; let lock = NSLock()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { lock.lock(); urls.append(u); lock.unlock() }; group.leave() }
                }
                group.notify(queue: .main) { model.handleDrop(urls) }
                return true
            }
            .alert("Found games on your drives", isPresented: Binding(get: { !model.foundFolders.isEmpty && !model.showWelcome && !model.showWhatsNew }, set: { if !$0 && !model.foundFolders.isEmpty { model.declineFoundFolders() } })) {
                Button("Add Them") { model.addFoundFolders() }
                Button("Not Now", role: .cancel) { model.declineFoundFolders() }
            } message: {
                Text(model.foundFolders.map { "\($0.games) game\($0.games == 1 ? "" : "s") in \($0.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" }.joined(separator: "\n")
                     + "\n\nThese were made with Nokcandu. Adding them uses them where they are — nothing is copied.")
            }
            .sheet(isPresented: $model.showProfiles) {
                ProfilesView(focusNumber: model.profileFocus).environmentObject(model)
            }
    }
}


/// The green mark for something running through Nokcandu, ringed so it reads on any icon.
struct RunningDot: View {
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(.green).frame(width: size, height: size)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
    }
}

/// Beside the window title, on every tab: what is running through Nokcandu right now. Click one to go to it.
struct RunningStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var streams = StreamsModel.shared
    private let limit = 6

    var body: some View {
        let running = model.runningApps
        if !running.isEmpty || streams.running != nil {
            HStack(spacing: 6) {
                Text("Running").font(.caption).foregroundStyle(.secondary)
                if streams.running != nil {
                    let name = streams.streamName ?? "Stream"
                    Button { streams.showStream() } label: {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 13, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(alignment: .bottomTrailing) { RunningDot(size: 7).offset(x: 2, y: 2) }
                    }
                    .buttonStyle(.plain)
                    .help("Streaming \(name)")
                    .accessibilityLabel("Streaming \(name)")
                    .contextMenu {
                        Button("Show Stream") { streams.showStream() }
                        Button("Show in Streams") {
                            model.sidebarTab = .streams
                            if let r = streams.running { streams.selectedHost = r.hostID; streams.selectedProfile = r.profileID }
                        }
                        Divider()
                        Button("End Stream") { streams.endStream(quitApp: false) }
                        Button("End Stream and Quit the App on the Host") { streams.endStream(quitApp: true) }
                    }
                }
                ForEach(running.prefix(limit)) { g in
                    Button { show(g) } label: {
                        Image(nsImage: g.icon).resizable().frame(width: 22, height: 22)
                            .overlay(alignment: .bottomTrailing) { RunningDot(size: 7).offset(x: 2, y: 2) }
                    }
                    .buttonStyle(.plain)
                    .help("\(g.name) is running")
                    .accessibilityLabel("\(g.name), running")
                    .contextMenu {
                        Button("Show in Library") { show(g) }
                        if g.isSteamHost { Button("Show Steam") { model.play(g) } }
                        Button("Quit…") { model.requestQuit(g) }
                    }
                }
                if running.count > limit {
                    Menu("+\(running.count - limit)") {
                        ForEach(running.dropFirst(limit)) { g in Button(g.name) { show(g) } }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Running now")
        }
    }

    func show(_ g: InstalledGame) {
        model.sidebarTab = .games
        if !model.matchesLibrary(g) { model.librarySearch = ""; model.libraryFilter = .all }
        model.selection = g.id
    }
}

/// A category's own menu (right-click its title in the sidebar).
struct CategoryMenu: View {
    @EnvironmentObject var model: AppModel
    let name: String
    var body: some View {
        let names = model.libraryCategories.map(\.name)
        Button("Rename…") { model.categoryPrompt = .init(renaming: name, game: nil) }
        Button("Move Up") { model.moveCategory(name, by: -1) }.disabled(names.first == name)
        Button("Move Down") { model.moveCategory(name, by: 1) }.disabled(names.last == name)
        Divider()
        Button("Remove Category", role: .destructive) { model.removeCategory(name) }
    }
}

