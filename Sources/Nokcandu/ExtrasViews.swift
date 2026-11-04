import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

// MARK: - Drives

/// Windows drive letters for this game's environment (e.g. E: → an external SSD).
struct DrivesSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var drives: [Drives.Drive] = []
    @State private var letter = "D"
    @State private var canUndo = false
    @State private var undoing = false
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drives").font(.subheadline.bold())
            ForEach(drives.filter { !$0.builtIn }) { d in
                HStack {
                    Text("\(d.letter):").font(.body.monospaced().bold()).frame(width: 28, alignment: .leading)
                    Image(systemName: d.gameDisc ? "opticaldisc" : d.connected ? "externaldrive.fill" : "externaldrive.badge.xmark")
                        .foregroundStyle(d.connected ? Color.secondary : Color.orange)
                    if d.gameDisc {
                        Text("The game's disc image").foregroundStyle(.secondary)
                        Text("linked each time the game starts").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        Text(d.target).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if !d.connected { Text("not connected").font(.caption).foregroundStyle(.orange) }
                        Spacer()
                        if d.connected { Button("Show") { NSWorkspace.shared.open(URL(fileURLWithPath: d.target)) }.buttonStyle(.link) }
                        Button("Remove") { remove(d) }.buttonStyle(.link)
                    }
                }
            }
            HStack {
                Picker("", selection: $letter) {
                    ForEach(freeLetters, id: \.self) { Text("\($0):").tag($0) }
                }
                .labelsHidden().frame(width: 70)
                Button("Add Drive…", action: add)
                if canUndo {
                    Button("Undo drive cleanup") {
                        undoing = true
                        Task {
                            let selected = game
                            do {
                                try await Task.detached(priority: .utility) { try AutomaticDriveMappings.undo(for: selected) }.value
                                reload()
                            } catch { model.fail(error) }
                            undoing = false
                        }
                    }.buttonStyle(.link).disabled(undoing)
                }
                Spacer()
            }
            Text(game.usesSharedSteam ? "Drives for the shared Steam, used by all Steam games. A drive letter points at a Mac folder or external drive; games and stores (Steam libraries, Battle.net install locations) can install there."
                                      : "A drive letter points at a Mac folder or external drive, so games and stores (Battle.net install locations, Steam libraries) can install there. Restart the game after changes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: "\(game.id)-\(model.libraryRevision)-\(refresh)") {
            let games = model.games, selected = game
            let result = await Task.detached(priority: .utility) {
                AutomaticDriveMappings.reconcile(games: games)
                return (Drives.list(for: selected), AutomaticDriveMappings.hasUndo(for: selected))
            }.value
            if !Task.isCancelled {
                drives = result.0; canUndo = result.1
                if !freeLetters.contains(letter) { letter = freeLetters.first ?? "D" }
            }
        }
    }
    var freeLetters: [String] {
        let used = Set(drives.map(\.letter))
        return "DEFGHIJKLMNOPQRSTUVWXY".map(String.init).filter { !used.contains($0) }
    }
    func reload() { refresh += 1 }

    func add() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: "/Volumes")
        p.message = "Choose the folder or drive that \(letter): should open in Windows."
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Drives.add(letter, to: u, for: game); model.say("\(letter): → \(u.path)"); reload() } catch { model.fail(error) }
    }

    func remove(_ d: Drives.Drive) {
        do { try Drives.remove(d.letter, for: game); model.say("Removed \(d.letter): (the files themselves are untouched)."); reload() }
        catch { model.fail(error) }
    }
}

// MARK: - Performance

struct PerformanceSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var s = Performance.Settings()
    @State private var loaded = false
    @State private var buffer: Int?

    var steam: Bool { game.usesSharedSteam || game.isSteamHost }
    var graphics: GraphicsPreset? { game.hosted != nil ? HostedSettings.graphics(game) : RecipeSettings.supports(game) ? RecipeSettings.graphics(game) : game.custom?.graphics }
    var metal: Bool { graphics == .appleMetal || graphics == .dxmt }
    var d3dmetal: Bool { graphics == .appleMetal }
    var dxmt: Bool { graphics == .dxmt }

    var when: String { steam ? "Applies to all Steam games when Steam next starts." : "Takes effect the next time the game starts." }

    var body: some View {
        SettingsSection(title: "Performance") {
            SettingToggle(title: "Show FPS counter", info: "Shows frames per second (and optionally a frame-time graph) in a corner of the game.",
                          isOn: Binding(get: { s.fpsCounter }, set: { s.fpsCounter = $0; save() }))
            if s.fpsCounter {
                SettingRow(title: "Counter style") {
                    Picker("Counter style", selection: Binding(get: { s.hud ?? "graph" }, set: { s.hud = $0; save() })) {
                        Text("FPS only").tag("fps"); Text("FPS + frame graph").tag("graph"); Text("Full details").tag("full")
                    }.labelsHidden().frame(width: 150)
                    Picker("Counter size", selection: Binding(get: { s.hudSize ?? "small" }, set: { s.hudSize = $0; save() })) {
                        Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                    }.labelsHidden().frame(width: 66)
                }
            }
            if !metal {
                SettingToggle(title: "Low-latency mode",
                              info: "The graphics layer prepares at most one frame ahead instead of up to three, so what you see reacts to the mouse sooner, at a small cost in FPS. Works in Classic 3D and Modern 3D (Apple Metal and DXMT have no such setting). \(when)",
                              isOn: Binding(get: { s.lowLatency == true }, set: { s.lowLatency = $0 ? true : nil; save() }))
            }
            if let c = game.custom, LowLatency.supported(c) {
                SettingToggle(title: "Low-latency aiming",
                              info: "For competitive play: turns the game's vsync off (the Mac never tears and always shows the newest frame)\(c.steamAppID == 730 ? " and has CS2 read the mouse as late as possible before each frame" : ""). Uses the game's launch options. Takes effect the next time the game starts.",
                              isOn: Binding(get: { LowLatency.isOn(c) }, set: { setLowLatency($0) }))
                SettingRow(title: "Game frame cap",
                           info: "Recommended is twice your \(refresh) Hz screen: every frame you see then carries fresher mouse input. Higher caps use more power; if the Mac gets hot, pick a lower one.") {
                    Picker("Game frame cap", selection: Binding(get: { LowLatency.cap(c) ?? -1 }, set: { setCap($0 < 0 ? nil : $0) })) {
                        Text("Game's default").tag(-1)
                        if let cur = LowLatency.cap(c), !LowLatency.caps.contains(cur) { Text("\(cur) FPS").tag(cur) }
                        ForEach(LowLatency.caps, id: \.self) { f in
                            Text(f == 0 ? "Unlimited" : f == autoFPS ? "\(f) FPS (recommended)" : "\(f) FPS").tag(f)
                        }
                    }.labelsHidden().frame(width: settingControlWidth)
                }
            }
            SettingToggle(title: "Vsync",
                          info: metal ? "Every screen refresh gets a new frame, with low delay. Without it, the game's frames drift against the screen's refresh and now and then one is shown twice: a visible hitch when you turn. With it, frames wait for the refresh, but at most one at a time, so it adds far less delay than a game's own vsync (keep that off). Pair it with a \(refresh) FPS frame limit."
                                      : "Smoother motion and no tearing, at the cost of a little delay.",
                          isOn: Binding(get: { s.vsync }, set: { s.vsync = $0; save() }))
            SettingRow(title: "Frame limit",
                       info: d3dmetal ? "The frame limit doesn't work with Apple Metal: use the game's own cap instead (e.g. +fps_max 60 for Source games)."
                           : dxmt ? "DXMT's frame limit spaces frames evenly through Metal's own timing, without vsync's queue of waiting frames. Set it to your screen's \(refresh) Hz and the game's own cap to unlimited for the smoothest motion with the least delay. It can't go above the screen's refresh. \(when)"
                           : "A frame limit keeps the Mac cooler and quieter, makes motion more even, and leaves CPU for sound. \(when)") {
                Picker("Frame limit", selection: Binding(get: { s.fpsLimit }, set: { s.fpsLimit = $0; save() })) {
                    Text("Off").tag(0)
                    // DXMT paces through the screen's refresh: limits above it act like the refresh itself.
                    ForEach([30, 60, 90, 120].filter { !dxmt || $0 <= max(refresh, 60) || $0 == s.fpsLimit }, id: \.self) { Text("\($0) FPS").tag($0) }
                }
                .labelsHidden().frame(width: settingControlWidth).disabled(d3dmetal)
            }
            if let b = buffer {
                SettingRow(title: "Audio buffer",
                           info: "If sound crackles or has static, choose Large: games get a bigger sound buffer, so a busy moment doesn't cause gaps (adds a little sound delay). \(steam ? "Applies to all Steam games; quit Steam first." : "Quit the game first.")") {
                    Picker("Audio buffer", selection: Binding(get: { b }, set: { setBuffer($0) })) {
                        Text("Normal (10 ms)").tag(10); Text("Large (20 ms)").tag(20); Text("Extra large (40 ms)").tag(40)
                    }.labelsHidden().frame(width: settingControlWidth)
                }
            }
            if GameMicrophone.supported(game) { MicrophoneSettingRow(game: game) }
        }
        .onAppear { s = PendingSettings.performance(for: game) ?? Performance.settings(for: game); buffer = game.hosted == nil ? PendingSettings.audioBuffer(for: game) ?? AudioBuffer.current(for: game) : nil; loaded = true }
    }

    /// Fastest refresh among connected screens (ProMotion and external monitors report 120+).
    var refresh: Int { NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60 }
    var autoFPS: Int { LowLatency.autoFPS(refresh: refresh) }

    func setLowLatency(_ on: Bool) {
        model.changeSetting(for: game, title: "Low-latency Aiming", change: .lowLatency(on))
    }

    func setCap(_ fps: Int?) {
        model.changeSetting(for: game, title: "Game Frame Cap", change: .frameCap(fps))
    }

    func setBuffer(_ ms: Int) {
        model.changeSetting(for: game, title: "Audio Buffer", success: "Audio buffer: \(ms) ms chunks.", change: .audioBuffer(ms), completion: { _ in buffer = PendingSettings.audioBuffer(for: game) ?? AudioBuffer.current(for: game) })
    }

    func save() {
        guard loaded else { return }
        let value = s
        model.changeSetting(for: game, title: "Performance", success: "Performance settings applied.", change: .performance(value), completion: { _ in s = PendingSettings.performance(for: game) ?? Performance.settings(for: game) })
    }

}

// MARK: - Storage

struct StorageView: View {
    @EnvironmentObject var model: AppModel
    var embedded = false
    @Environment(\.dismiss) var dismiss
    @State private var section: StorageInventory.Section = .drives
    @State private var volumes: [Storage.VolumeInfo] = []
    @State private var snapshot: StorageInventory.Snapshot?
    @State private var displayedSection: StorageInventory.Section?
    @State private var loading = false
    @State private var cleaning = false
    @State private var search = ""
    @State private var refresh = 0
    struct Request: Equatable { var section: StorageInventory.Section; var games: [InstalledGame]; var refresh: Int; var libraryRevision: Int }

    var items: [Storage.Item] {
        guard displayedSection == section else { return [] }
        if section != .games { return snapshot?.items ?? [] }
        return (snapshot?.items ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }
    }
    var leftovers: [GameRemoval.Item] { displayedSection == section ? snapshot?.leftovers ?? [] : [] }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !embedded { Text("Storage").font(.title2.bold()) }
                if loading { ProgressView().controlSize(.small); Text("Measuring…").font(.caption).foregroundStyle(.secondary) }
                else if displayedSection == section, let date = snapshot?.measuredAt {
                    Text("Measured \(date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", action: reload).disabled(loading || cleaning)
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }.padding(14)
            Picker("Storage section", selection: $section) {
                ForEach(StorageInventory.Section.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            if section == .drives {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        GroupBox {
                            ForEach(volumes) { v in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text(v.name).bold(); Spacer(); Text("\(Storage.format(v.free)) free of \(Storage.format(v.total))").font(.caption).foregroundStyle(.secondary) }
                                    ProgressView(value: Double(max(v.total - v.free, 0)), total: Double(max(v.total, 1)))
                                        .tint(Double(v.free) / Double(max(v.total, 1)) < 0.1 ? .orange : .accentColor)
                                }.padding(6)
                            }
                        } label: { Label("Drives", systemImage: "internaldrive").font(.headline) }
                        GameFoldersBox(refreshToken: refresh)
                    }.padding(20)
                }
            } else {
                if section == .games {
                    TextField("Search games", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.top, 12)
                }
                List {
                    if section == .leftovers {
                        ForEach(leftovers) { item in
                            HStack {
                                VStack(alignment: .leading) { Text(item.what); Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(); Text(Storage.format(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    } else {
                        if section == .games, loading, displayedSection != .games {
                            ForEach(model.games.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { game in
                                HStack { Text(game.name); Spacer(); Text("Measuring…").foregroundStyle(.secondary) }
                            }
                        }
                        ForEach(items) { item in
                            HStack {
                                row(item)
                                if section == .appData {
                                    if ["Downloads", "Work folder"].contains(item.title) {
                                        Button("Empty") { cleanup { Storage.format(Storage.empty(item.url)) + " freed." } }.disabled(item.bytes == 0 || cleaning || loading)
                                    } else if item.title == "Engines cache" {
                                        Button("Remove Unused") {
                                            let games = model.games
                                            cleanup { let removed = RuntimeManager.removeUnused(games: games); return removed.isEmpty ? "Every cached engine is in use." : "Removed \(removed.count) unused engine(s)." }
                                        }.disabled(cleaning || loading)
                                    }
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    if !loading, displayedSection == section, (section == .leftovers ? leftovers.isEmpty : items.isEmpty) {
                        Text(section == .leftovers ? "No leftovers found." : (section == .games && !search.isEmpty) ? "No matching games." : "Nothing here yet.").foregroundStyle(.secondary)
                    }
                }.listStyle(.inset)
                Divider()
                HStack(alignment: .center) {
                    if section == .games {
                        Text("Allocated estimates can share APFS blocks; they aren’t guaranteed deletion savings.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear All Logs") { let games = model.games; cleanup { "Cleared " + Storage.format(Storage.clearLogs(games)) + " of logs." } }.disabled(cleaning || loading)
                    } else if section == .leftovers {
                        Text("History and backups kept for removed games.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Move to Trash") { let saved = leftovers; cleanup {
                            let current = Set(GameRemoval.orphans(library: GameLibrary.scan()).map(\.id))
                            return "Moved \(GameRemoval.clean(saved.filter { current.contains($0.id) })) leftover item(s) to the Trash."
                        } }.disabled(leftovers.isEmpty || cleaning || loading)
                    } else {
                        Text("Cleanup leaves installed games and saves in place.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    if cleaning { ProgressView().controlSize(.small) }
                }.padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 660, minHeight: 480)
        .task(id: Request(section: section, games: model.games, refresh: refresh, libraryRevision: model.libraryRevision)) {
            loading = true
            let selected = section, games = model.games
            let result = await StorageInventory.shared.load(selected, library: games)
            if !Task.isCancelled {
                snapshot = result; displayedSection = selected; volumes = result.volumes; loading = false
            }
        }
    }
    func row(_ item: Storage.Item) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            Text((item.incomplete ? "At least " : "") + Storage.format(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if let game = model.games.first(where: { $0.appURL == item.url }),
               game.native == nil, !game.isSteamHost, !game.usesSharedSteam,
               game.battleNet == nil, game.hosted == nil, !BattleNet.isHost(game), PCLaunchers.kind(of: game) == nil {
                Button("Move…") { model.moveToChosenFolder(game) }.fixedSize()
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
    }
    func reload() {
        Task { await StorageInventory.shared.invalidate(); refresh += 1 }
    }
    func cleanup(_ operation: @escaping @Sendable () -> String) {
        cleaning = true
        Task {
            let message = await Task.detached(priority: .utility) { operation() }.value
            model.say(message); cleaning = false
            await StorageInventory.shared.invalidate(); refresh += 1
        }
    }
}

// MARK: - Game resolution

struct GameResolutionSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var options: [GameDisplay.Resolution] = []
    @State private var working = false
    @State private var status = ""

    @State private var showSettingsBackups = false
    @State private var confirmBFSetup = false
    var current: [Int]? { game.custom?.displayPixels }
    var selection: String { current.map { "\($0[0])x\($0[1])" } ?? "desktop" }
    var gameSelection: String { BF1942DisplayFix.resolution(for: game).map { "\($0[0])x\($0[1])" } ?? "current" }
    var body: some View {
        SettingsSection(title: "Display") {
                if game.native == nil, WineTools.hostContents(for: game) != nil {
                    ResizableWindowSection(game: game, embedded: true).id("resizable-\(game.id)")
                    Divider()
                }
                SettingRow(title: "Mac screen resolution",
                           info: "Changes your Mac's display while the game runs and restores it afterward. Desktop keeps your current screen resolution. Nokcandu doesn't edit the game's own settings, but many games (like Counter-Strike 2) only offer resolutions that fit the screen, so pick the size here first, then choose it in the game.\(game.usesSharedSteam ? " Changing it needs Steam closed." : "")") {
                    Picker("Mac screen resolution", selection: Binding(get: { selection }, set: choose)) {
                        Text("Desktop (don't switch)").tag("desktop")
                        if let c = current, !options.contains(where: { $0.pixels == c }) { Text("\(c[0]) × \(c[1])").tag("\(c[0])x\(c[1])") }
                        Section("Full screen — your Mac's screen switches") {
                            ForEach(Array(options.enumerated()), id: \.element.id) { i, r in
                                Text("\(r.width) × \(r.height)\(i == 0 ? " — native" : "")").tag(r.id)
                            }
                        }
                    }.labelsHidden().frame(width: settingControlWidth)
                        .disabled(WindowedPresentation.setting(for: game) != nil)
                }
                if WindowedPresentation.setting(for: game) != nil {
                    SettingNote("The game is in a resizable window, so your Mac's screen isn't switched.")
                }
                SettingRow(title: "Window style",
                           info: CompatibilityFixes.unavailable(.borderless, for: game) ?? "Game default: the game decides. Fullscreen (Borderless): the game's window fills its screen without borders, leaving the Mac's display mode alone. Fullscreen: the same, and with the resizable window the game opens in Mac full screen in its own Space (Control-Command-F switches back); without it, the borderless window covers the whole Mac screen. For either fullscreen style, choose Windowed inside the game.") {
                    Picker("Window style", selection: Binding(get: { GameWindowStyle.current(game) }, set: windowStyle)) {
                        ForEach(GameWindowStyle.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: settingControlWidth)
                        .disabled(CompatibilityFixes.unavailable(.borderless, for: game) != nil && game.custom?.borderless != true)
                }
                if OpenUASettings.supports(game) {
                    Divider()
                    Text("OpenUA display").font(.body.bold())
                    Text("Fixes the invisible window and tiny menu text using the settings confirmed on this Mac. The original menu fills the screen; mission resolution stays under the game’s control. These settings are included when you save or share a profile.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(CompatibilityFixes.isInstalled(.openUA, for: game) ? "Undo OpenUA Display Settings" : "Apply Recommended OpenUA Display Settings") { openUASettings() }
                } else if BF1942DisplayFix.supports(game) || BF1942DisplayFix.hasChanges(for: game) {
                    Divider()
                    HStack {
                        Text("Game resolution")
                        Picker("BF1942 game resolution", selection: Binding(get: { gameSelection }, set: gameResolution)) {
                            if gameSelection == "current" { Text("Current game settings").tag("current") }
                            ForEach(BF1942DisplayFix.resolutions, id: \.self) { size in
                                Text("\(size[0]) × \(size[1])").tag("\(size[0])x\(size[1])")
                            }
                        }.labelsHidden().frame(width: 280)
                    }
                    Text("The recommended menu correction also restores the Internet server browser through master.bf1942.org. The original executable is kept; Undo BF1942 Display Settings removes the correction.").font(.caption).foregroundStyle(.secondary)
                    Text("Updates BF1942's gameplay resolution in its video profiles, with a backup for Undo. The game's menu resolution is handled separately below.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Apply Recommended BF1942 Setup…") { confirmBFSetup = true }
                        .disabled(BF1942DisplayFix.menuUnavailable(for: game) != nil)
                    Text("Includes Older 3D graphics, DirectX 8 compatibility, Microsoft shader libraries, the menu and mod-restart correction, the community Internet server list, and Fullscreen (Borderless). Keeps your saved game resolution; new setups start at 1280 × 800. Saved and shared profiles include these fixes.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(BF1942DisplayFix.isRecommended(for: game) ? "Reapply Recommended BF1942 Display Settings" : "Apply Recommended BF1942 Display Settings") {
                            applyRecommended()
                        }.disabled(BF1942DisplayFix.menuUnavailable(for: game) != nil)
                        if BF1942DisplayFix.hasChanges(for: game) { Button("Undo BF1942 Display Settings") { undoGameDisplay() } }
                    }
                    Text("Uses a verified copy for the 1280 × 800 menu, sets gameplay to 1280 × 800 windowed, and enables Fullscreen (Borderless). Keeps the original executable and leaves the Mac at its desktop resolution. Graphics and shader fixes are available separately under Fixes.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = BF1942DisplayFix.menuUnavailable(for: game) {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingRow(title: "Game settings backups", info: "Copies of the game's own settings files, kept before Nokcandu or the game changes them, so you can put an earlier set back.") {
                    Button("Settings Backups…") { showSettingsBackups = true }
                }
                if working { ProgressView().controlSize(.small) }
                if !status.isEmpty { SettingNote(status) }
        }
        .disabled(working)
        .onAppear { options = GameDisplay.resolutions() }
        .confirmationDialog("Apply recommended Battlefield 1942 setup?", isPresented: $confirmBFSetup, titleVisibility: .visible) {
            Button("Apply Recommended Setup") { completeBFSetup() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Downloads missing DirectX components from Microsoft and the d3d8to9 project, uses Older 3D graphics, and applies the verified menu/mod restart correction and borderless window. Keeps your saved game resolution. Originals and settings backups are retained; each fix has Undo. If a step fails, completed fixes remain available and you can retry.")
        }
        .sheet(isPresented: $showSettingsBackups) { SettingsBackupsView(game: game).environmentObject(model) }
    }
    var logger: @Sendable (String) -> Void { { line in Task { @MainActor in status = line } } }

    func choose(_ tag: String) {
        let px: [Int]? = tag == "desktop" ? nil : tag.split(separator: "x").compactMap { Int($0) }
        working = true
        model.changeSetting(for: game, title: "Mac Screen Resolution", success: "Saved the Mac screen resolution for this game.", change: .display(px), completion: { _ in working = false })
    }
    func windowStyle(_ style: GameWindowStyle) {
        working = true; status = ""
        model.changeSetting(for: game, title: "Window Style", change: .windowStyle(style), completion: { _ in working = false })
    }
    func openUASettings() {
        working = true; status = ""
        Task {
            do {
                if CompatibilityFixes.isInstalled(.openUA, for: game) { try CompatibilityFixes.undo(.openUA, for: game, log: logger) }
                else { try await CompatibilityFixes.install(.openUA, for: game, log: logger) }
                model.refresh()
            } catch { model.fail(error) }
            working = false
        }
    }
    func gameResolution(_ tag: String) {
        guard tag != "current" else { return }
        let size = tag.split(separator: "x").compactMap { Int($0) }
        applyGameDisplay(size: size, recommended: false)
    }
    func completeBFSetup() {
        working = true; status = ""
        Task {
            do {
                try await BF1942DisplayFix.applyRecommendedSetup(to: game, log: logger)
                model.refresh(); model.say("Applied recommended BF1942 setup. Undo is available in Display and Fixes.")
            } catch { model.fail(error); model.refresh() }
            working = false
        }
    }
    func applyRecommended() { applyGameDisplay(size: [1280, 800], recommended: true) }
    func applyGameDisplay(size: [Int], recommended: Bool) {
        working = true; status = ""
        Task {
            do {
                try await BF1942DisplayFix.apply(to: game, size: size, recommended: recommended, log: logger)
                model.refresh(); model.say("Saved BF1942 display settings. Undo is available in Display.")
            } catch { model.fail(error); model.refresh() }
            working = false
        }
    }
    func undoGameDisplay() {
        working = true; status = ""
        do { try BF1942DisplayFix.undo(for: game, log: logger); model.refresh(); model.say("Restored BF1942's previous display settings.") }
        catch { model.fail(error) }
        working = false
    }
}

// MARK: - Discs

/// A disc-based game's discs: which one is in drive D:, swapping (also while playing), adding more.
struct GameDiscsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var current = 0
    @State private var busy = false

    var discs: [DiscSpec] { game.custom.map(Discs.all) ?? [] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(discs.enumerated()), id: \.offset) { i, d in
                    HStack(spacing: 8) {
                        Image(systemName: i == current ? "opticaldisc.fill" : "opticaldisc").foregroundStyle(i == current ? Color.accentColor : .secondary)
                        Text("Disc \(i + 1)").bold()
                        Text(d.volumeLabel.isEmpty ? d.imageName : d.volumeLabel).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if i == current { Text("In drive D:").font(.caption).foregroundStyle(.secondary) }
                        else { Button("Put in Drive D:") { insert(i) }.disabled(busy) }
                        Button("Run Setup") { runSetup(i) }.disabled(busy)
                            .help("Runs this disc's installer — for expansion packs and add-on discs.")
                    }
                }
                HStack {
                    Button("Add Discs…", action: addDiscs).disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text("Works while the game is running, like swapping a real CD — use it when the game asks for another disc. The disc in D: is kept for next time. Formats: .iso, .cdr, .bin/.cue, .img/.ccd, .mdf (CD-audio music tracks can't be used).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text(discs.count > 1 ? "Discs" : "Disc").font(.headline) }
        .onAppear { current = Discs.current(support: game.support) }
    }

    func insert(_ i: Int) {
        do { try Discs.insert(i, for: game); current = i; model.say("Disc \(i + 1) is in drive D:.") }
        catch { model.fail(error) }
    }

    func runSetup(_ i: Int) {
        guard let c = game.custom else { return }
        var env = WineTools.environment(contents: game.contents)
        env["WINEPREFIX"] = game.prefix.path
        let g = game, imgs = Discs.all(c).map(\.imageName)
        busy = true; current = i
        model.say("Starting disc \(i + 1)'s setup — finish it in its own window.")
        Task {
            do {
                try await Discs.runSetup(i, images: imgs, support: g.support, prefix: g.prefix, env: env, log: { _ in })
                model.say("Disc \(i + 1)'s setup finished.")
            } catch { model.fail(error) }
            busy = false
        }
    }

    func addDiscs() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.message = "Choose the game's other discs."
        p.allowedContentTypes = Discs.imageTypes.compactMap { UTType(filenameExtension: $0) }
        guard p.runModal() == .OK, let c = game.custom else { return }
        let urls = Discs.sorted(p.urls), g = game
        busy = true
        Task {
            let r = await Task.detached { Result { () -> [String] in
                let (n, notes) = try Discs.add(urls, to: g, current: c)
                try CustomGames.saveAll(n, to: g)
                return notes
            } }.value
            busy = false
            switch r {
            case .success(let notes): model.say((["Discs added."] + notes).joined(separator: " ")); model.refresh()
            case .failure(let e): model.fail(e)
            }
        }
    }
}


// MARK: - Remove game

/// Preview exactly which app and separate installation will go to the Trash.
struct RemoveGameSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var preview: GameRemoval.Plan?
    @State private var confirm = false
    @State private var preparing = false
    @State private var working = false
    @State private var removeFiles = false

    var body: some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remove \(game.name)").font(.body.bold())
                    Text("Choose whether to remove only the Nokcandu app or also its separately stored game files. Review the drive and folder before anything moves to the Trash.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if preparing { ProgressView().controlSize(.small) }
                Button(preparing ? "Checking…" : "Remove Game…", role: .destructive, action: prepare).disabled(preparing)
            }.padding(6)
        }
        .sheet(isPresented: $confirm) {
            if let plan = preview {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Remove \(game.name)?").font(.title2.bold())
                    if let folder = plan.gameFolder {
                        Picker("Remove", selection: $removeFiles) {
                            Text("Nokcandu app only").tag(false)
                            Text("App and game files").tag(true)
                        }.pickerStyle(.radioGroup).disabled(working)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Game files: \(Storage.format(folder.bytes)) on \(folder.drive)").font(.headline)
                            Text(folder.url.path).font(.caption.monospaced()).textSelection(.enabled)
                            Text(removeFiles ? "This entire game folder will move to the Trash, including any saves or mods inside it." : "This game folder will stay where it is.")
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    } else if let reason = plan.folderUnavailable {
                        Text(reason).foregroundStyle(.secondary)
                    }
                    if plan.shared {
                        if removeFiles {
                            Text("\(plan.launcherName ?? "The launcher") and its Windows games will be fully closed before removing the files. Save your progress first.")
                        } else {
                            Text("Only the small Nokcandu app and its records will be removed. If the game files are still installed, the game stays in \(plan.launcherName ?? "the launcher")’s list and can be added again.")
                        }
                    } else {
                        Text("Game files and saves stored inside the app go with the app. Saves outside the listed locations and your saved profiles stay.")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.appItems) { item in Text("• \(item.what) — \(Storage.format(item.bytes))").font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 130)
                    Text("Removed items go to the Trash. No permanent deletion is used.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if working { ProgressView().controlSize(.small); Text("Removing…").font(.caption) }
                        Spacer()
                        Button("Cancel") { confirm = false }.keyboardShortcut(.cancelAction).disabled(working)
                        Button(removeFiles ? "Move App and Game Files to Trash" : "Move App to Trash", role: .destructive, action: remove).disabled(working)
                    }
                }.padding(24).frame(width: 570).interactiveDismissDisabled(working)
            }
        }
    }
    func prepare() {
        if let reason = GameRemoval.blocker(game, library: model.games) { model.fail(NokError(reason)); return }
        preparing = true
        let g = game, library = model.games
        Task {
            preview = await Task.detached(priority: .userInitiated) { GameRemoval.plan(for: g, library: library) }.value
            preparing = false; removeFiles = false; confirm = true
        }
    }
    func remove() {
        guard let plan = preview else { return }
        let g = game, library = model.games, mode: GameRemoval.Mode = removeFiles ? .appAndGameFiles : .appOnly
        let expected = plan.gameFolder
        working = true
        Task {
            do {
                if removeFiles && plan.shared {
                    // Check the folder is still the one reviewed before closing the launcher and its games.
                    let now = await Task.detached { GameRemoval.plan(for: g, library: library).gameFolder }.value
                    guard let now, let expected, now.url == expected.url, GameRemoval.sameFolder(now, expected) else {
                        throw NokError("The game folder changed or is no longer available. Nothing was removed; open Remove Game again to review its location.")
                    }
                    try await WineTools.stopAll(for: g)
                }
                let failed = try await Task.detached { try GameRemoval.remove(g, library: library, mode: mode, expectedFolder: expected) }.value
                working = false; confirm = false
                model.say(failed.isEmpty ? "\(g.name) moved to the Trash." : "Removal stopped: \(failed.joined(separator: "; "))")
                if !FileManager.default.fileExists(atPath: g.appURL.path) { model.selection = nil }
                model.refresh()
            } catch { working = false; model.fail(error) }
        }
    }
}

/// Where the game app lives, and moving it (e.g. to an external drive).
struct GameLocationSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame

    var body: some View {
        let folder = GameFolders.folder(of: game)
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage & Location").font(.body.bold())
                    Text("App: " + Storage.driveName(game.appURL) + " · " + GameFolderLabel.text(folder))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let ext = GameMover.externalFiles(game) {
                        Text("Game files: \(ext.path)" + (GameMover.missingDrive(game) != nil ? " — drive not connected" : ""))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let b = GameMover.blocker(game), b != "Quit the game first.", GameMover.filesBlocker(game).map({ $0 != "Quit the game first." }) ?? false {
                        Text(b).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Move it to another folder or drive to free up space. On APFS or Mac OS Extended drives the whole app moves; on ExFAT drives (most USB drives) only the game's files move and the app, Wine runtime and private Windows setup stay on this Mac. Keep the drive connected to play.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Show in Finder") { model.reveal(game.appURL) }
                if [GameMover.blocker(game), GameMover.filesBlocker(game)].contains(where: { $0 == nil || $0 == "Quit the game first." }) {
                    Menu("Move To") { GameContextMenuMoveItems(game: game) }
                        .fixedSize()
                        .disabled(model.moving.contains(game.id))
                }
            }
            .padding(6)
        }
    }
}

struct GameContextMenuMoveItems: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    var body: some View {
        let ok: (String?) -> Bool = { $0 == nil || $0 == "Quit the game first." }
        let appOK = ok(GameMover.blocker(game)), filesOK = ok(GameMover.filesBlocker(game))
        ForEach(GameFolders.all.filter { $0 != GameFolders.folder(of: game) }, id: \.self) { f in
            Button(GameFolderLabel.text(f)) { model.move(game, to: f) }
                .disabled(!GameFolders.isAvailable(f) || !(GameFolders.holdsApps(f) ? appOK : filesOK))
        }
        if GameMover.externalFiles(game) != nil {
            Button("Bring Game Files Back to This Mac") { model.moveFiles(game, to: nil) }
        }
        Divider()
        Button("Other Folder…") { model.moveToChosenFolder(game) }
    }
}

/// Storage → Game Folders: where games live and where new ones install.
struct GameFoldersBox: View {
    @EnvironmentObject var model: AppModel
    var refreshToken = 0
    struct Folder: Identifiable {
        var id: URL { url }
        var url: URL; var title: String; var detail: String
        var available: Bool; var standard: Bool; var selected: Bool
    }
    struct Request: Equatable { var games: [InstalledGame]; var refresh: Int; var revision: Int; var libraryRevision: Int }
    @State private var folders: [Folder] = []
    @State private var revision = 0
    @State private var error: String?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(folders) { f in
                    HStack {
                        Image(systemName: f.url.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.title)
                            Text(f.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !f.selected, f.available {
                            Button("Install Here") { GameFolders.setInstallFolder(f.url); reload() }
                        }
                        Button("Show") { model.reveal(f.url) }.disabled(!f.available)
                        if !f.standard {
                            Button("Remove") { GameFolders.remove(f.url); reload() }
                                .help("Stops showing this folder in Nokcandu. The games in it stay on disk.")
                        }
                    }
                }
                if folders.isEmpty { Text("Checking game folders…").foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text("Steam, Battle.net and their games stay in the standard folder (pick a drive in their own settings instead). Other games can live anywhere — move one from its page or by right-clicking it. On ExFAT drives only the game's files are stored; the app, Wine runtime and private Windows setup stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add Folder…", action: add)
                }
            }.padding(6)
        } label: { Label("Game Folders", systemImage: "folder").font(.headline) }
        .task(id: Request(games: model.games, refresh: refreshToken, revision: revision, libraryRevision: model.libraryRevision)) {
            let games = model.games
            let result = await Task.detached(priority: .utility) {
                let installTo = GameFolders.installFolder.standardizedFileURL
                let locations = games.map { (GameFolders.folder(of: $0), GameMover.externalFiles($0)?.path) }
                return GameFolders.all.map { url in
                    let available = GameFolders.isAvailable(url), selected = url == installTo
                    let count = locations.filter { $0.0 == url || ($0.1?.hasPrefix(url.path + "/") ?? false) }.count
                    let free = available ? (GameFolders.freeSpace(url).map { " · \(Storage.format($0)) free" } ?? "") : ""
                    return Folder(url: url, title: GameFolderLabel.text(url),
                        detail: "\(count) app\(count == 1 ? "" : "s")\(free)\(selected ? " · new games install here" : "")",
                        available: available, standard: GameFolders.isStandard(url), selected: selected)
                }
            }.value
            if !Task.isCancelled { folders = result }
        }
    }
    func reload() { revision += 1; model.refresh() }
    func add() {
        error = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder or drive for games. Picking a whole drive makes a “Nokcandu Games” folder on it."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do { try GameFolders.add(u); reload() } catch { self.error = error.localizedDescription }
    }
}

/// A single background size scan on the game page; details below retain the existing Move controls.
struct GameStorageSummary: View {
    let game: InstalledGame
    @State private var usage: Storage.GameUsage?
    @State private var measurement = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(usage?.summary ?? "Measuring storage…", systemImage: "internaldrive").font(.callout).foregroundStyle(.secondary)
                Button { measurement += 1 } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                    .buttonStyle(.borderless).help("Recalculate storage size").disabled(usage == nil)
            }
            if let usage, usage.parts.count > 1 {
                Text(usage.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("Allocated-size estimate, including separately stored game files and known settings folders. APFS copies can share disk blocks, so removing a game may free less than this estimate. Shared Steam/Battle.net runtime space is counted with its launcher.")
        .task(id: "\(game.id)-\(GameMover.externalFiles(game)?.path ?? "local")-\(measurement)") {
            let g = game
            usage = nil
            let result = await Task.detached(priority: .utility) { Storage.usage(for: g) }.value
            if !Task.isCancelled { usage = result }
        }
    }
}

/// Shared settings recovery: readable versions and an in-app Restore action.
struct SettingsBackupsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    @State private var items: [SettingsBackups.Item] = []
    @State private var selected: SettingsBackups.Item?
    @State private var confirmRestore = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings Backups — \(game.name)").font(.title2.bold())
            Text("Restore a saved settings file here. Your current file is backed up first. Quit the game before restoring.").foregroundStyle(.secondary)
            if items.isEmpty { Text("No settings backups are available for this game yet.").padding() }
            else {
                List(items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.original.lastPathComponent).bold()
                            Text(item.original.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(item.date.formatted(date: .abbreviated, time: .standard) + " · " + item.reason).font(.caption)
                        }
                        Spacer()
                        Button("Show in Finder") { model.reveal(item.backup) }
                        Button("Restore…") { selected = item; confirmRestore = true }
                    }.padding(.vertical, 5)
                }.frame(minHeight: 260)
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth: 720, minHeight: 360)
            .onAppear { items = SettingsBackups.list(for: game) }
            .confirmationDialog("Restore this saved settings file?", isPresented: $confirmRestore) {
                Button("Restore Saved Version") {
                    guard let item = selected else { return }
                    do { try SettingsBackups.restore(item, for: game); message = "Restored \(item.original.lastPathComponent). The previous file is also backed up."; items = SettingsBackups.list(for: game); model.refresh() }
                    catch { model.fail(error) }
                    selected = nil
                }
                Button("Cancel", role: .cancel) { selected = nil }
            } message: { Text("This replaces \(selected?.original.lastPathComponent ?? "the settings file"). Your current version is backed up first.") }
    }
}


// MARK: - Resizable window (virtual screen)

/// Every Windows game can have its own choice; games sharing a launcher get it when they start (the launcher
/// restarts if it's running with another choice).
struct ResizableWindowSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    /// Shown inside a game's Display section (its rows only), rather than as a section of its own.
    var embedded = false
    @State private var size: [Int]?
    @State private var working = false
    @State private var status = ""

    var tag: String { size.map(WindowedPresentation.text) ?? "" }
    var shared: Bool { game.usesSharedSteam || game.battleNet != nil || game.hosted != nil || game.isSteamHost || BattleNet.isHost(game) || PCLaunchers.kind(of: game) != nil }

    var body: some View {
        if embedded { rows } else { SettingsSection(title: "Display") { rows } }
    }

    @ViewBuilder var rows: some View {
        let reason = WindowedPresentation.unavailable(for: game)
            SettingToggle(title: "Play in a resizable window",
                          info: "Runs the game on a virtual screen shown in a normal Mac window you can move, resize, minimize or make full screen. Your Mac's display isn't changed.\n\nWorks best with the game set to full screen in its own settings: it then fills the virtual screen exactly. A game set to its own windowed mode still works, shown as its own window.\n\nAutomatic starts like your Mac's screen (or at the game's last resolution) and follows the resolution the game picks; a fixed size suits games that use the desktop resolution.\n\nCtrl-Cmd-C frees the mouse from the game or gives it back (Shift-Cmd-Esc always frees it). Ctrl-Cmd-F switches full screen.\n\nChanging the resolution while the game runs switches it right away, like changing a monitor's mode. Only the game's picture goes in the window; launcher windows (like Steam's) stay separate. Turning the window on or off while the game or its launcher runs needs a restart, which Nokcandu offers when you play.",
                          isOn: Binding(get: { size != nil }, set: { on in set(on ? (size ?? WindowedPresentation.lastChoice(for: game)) : nil) }))
                .disabled(working || (reason != nil && size == nil))
            if size != nil {
                SettingRow(title: "Virtual screen") {
                    Picker("Virtual screen", selection: Binding(get: { tag }, set: { t in
                        if let px = WindowedPresentation.parse(t) { set(px) }
                    })) {
                        Text("Automatic").tag("auto")
                        if let w = size, w != WindowedPresentation.automatic, !WindowedPresentation.resolutions.contains(w) { Text("\(w[0]) × \(w[1])").tag(tag) }
                        ForEach(WindowedPresentation.resolutions, id: \.self) { r in Text("\(r[0]) × \(r[1])").tag("\(r[0])x\(r[1])") }
                    }.labelsHidden().frame(width: settingControlWidth)
                }
                .disabled(working)
            }
            if size != nil { SettingNote("Works best with the game set to full screen in its own settings.") }
            if let reason { SettingNote(reason) }
            if working { ProgressView().controlSize(.small) }
            if !status.isEmpty { SettingNote(status) }
            Color.clear.frame(height: 0).onAppear { size = WindowedPresentation.setting(for: game) }
    }

    func set(_ new: [Int]?) {
        let old = size
        size = new; working = true; status = ""
        let g = game
        Task {
            do {
                let live = try await WindowedPresentation.save(new, for: g)
                ProgramSettings.refresh(GameLibrary.inspect(g.appURL) ?? g, games: model.games)
                if live { status = new == WindowedPresentation.automatic ? "Automatic — the running game keeps its resolution until it picks another." : "Switched the running game to \(WindowedPresentation.title(new!))." }
                else if await WineTools.environmentIsRunning(for: g) { status = "Takes effect the next time the game starts." }
                else { status = "" }
                model.refresh()
            } catch {
                size = old
                model.fail(error)
            }
            working = false
        }
    }
}


/// Per-game consent control, also used for games whose performance settings live in a shared client.
struct MicrophoneSettingRow: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    var body: some View {
        SettingToggle(title: "Microphone",
                              info: "Off blocks this game's microphone access while keeping sound output working. On lets macOS ask for permission when needed. After macOS permission has been granted, changes apply while playing. First-time permission may need one close/reopen because macOS caches the app’s privacy metadata. If a game does not retry its microphone after enabling it, refresh its voice-chat settings. For games in a shared launcher, macOS lists the launcher in Privacy & Security; each game's switch still controls its own microphone access. Shared launchers also have their own switch.",
                              isOn: Binding(get: { GameMicrophone.isOn(game) }, set: { on in
                                  model.changeMicrophone(on, for: game)
                              }))
    }
}
