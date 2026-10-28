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
                    ForEach(Drives.freeLetters(for: game), id: \.self) { Text("\($0):").tag($0) }
                }
                .labelsHidden().frame(width: 70)
                Button("Add Drive…", action: add)
                Spacer()
            }
            Text(game.usesSharedSteam ? "Drives for the shared Steam, used by all Steam games. A drive letter points at a Mac folder or external drive; games and stores (Steam libraries, Battle.net install locations) can install there."
                                      : "A drive letter points at a Mac folder or external drive, so games and stores (Battle.net install locations, Steam libraries) can install there. Restart the game after changes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
    }

    func reload() {
        drives = Drives.list(for: game)
        if !Drives.freeLetters(for: game).contains(letter) { letter = Drives.freeLetters(for: game).first ?? "D" }
    }

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
    var metal: Bool { game.custom?.graphics == .appleMetal || game.custom?.graphics == .dxmt }
    var d3dmetal: Bool { game.custom?.graphics == .appleMetal }
    var dxmt: Bool { game.custom?.graphics == .dxmt }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Show FPS counter", isOn: Binding(get: { s.fpsCounter }, set: { s.fpsCounter = $0; save() }))
                    if s.fpsCounter {
                        Picker("", selection: Binding(get: { s.hud ?? "graph" }, set: { s.hud = $0; save() })) {
                            Text("FPS only").tag("fps"); Text("FPS + frame graph").tag("graph"); Text("Full details").tag("full")
                        }.labelsHidden().frame(width: 170)
                        Picker("", selection: Binding(get: { s.hudSize ?? "small" }, set: { s.hudSize = $0; save() })) {
                            Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                        }.labelsHidden().frame(width: 100)
                    }
                }
                if !metal {
                    Toggle("Low-latency mode", isOn: Binding(get: { s.lowLatency == true }, set: { s.lowLatency = $0 ? true : nil; save() }))
                    Text("The graphics layer prepares at most one frame ahead instead of up to three, so what you see reacts to the mouse sooner — at a small cost in FPS. Works in Classic 3D and Modern 3D (Apple Metal and DXMT have no such setting). Takes effect the next time the game\(steam ? " (and Steam)" : "") starts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let c = game.custom, LowLatency.supported(c) {
                    Toggle("Low-latency aiming", isOn: Binding(get: { LowLatency.isOn(c) }, set: { setLowLatency($0) }))
                    Text("For competitive play: turns the game's vsync off (the Mac never tears and always shows the newest frame)\(c.steamAppID == 730 ? " and has CS2 read the mouse as late as possible before each frame" : ""). Takes effect the next time the game starts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("Game frame cap")
                        Picker("", selection: Binding(get: { LowLatency.cap(c) ?? -1 }, set: { setCap($0 < 0 ? nil : $0) })) {
                            Text("Game's default").tag(-1)
                            if let cur = LowLatency.cap(c), !LowLatency.caps.contains(cur) { Text("\(cur) FPS").tag(cur) }
                            ForEach(LowLatency.caps, id: \.self) { f in
                                Text(f == 0 ? "Unlimited" : f == autoFPS ? "\(f) FPS (recommended)" : "\(f) FPS").tag(f)
                            }
                        }.labelsHidden().frame(width: 190)
                    }
                    Text("Recommended is twice your \(refresh) Hz screen: every frame you see then carries fresher mouse input. Higher caps use more power; if the Mac gets hot, pick a lower one. Both settings are the game's launch options (see Settings).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(metal ? "Vsync (every refresh gets a new frame; low delay)" : "Vsync (smoother motion, no tearing; adds a little delay)",
                       isOn: Binding(get: { s.vsync }, set: { s.vsync = $0; save() }))
                if metal {
                    Text("Without it, the game's frames drift against the screen's refresh and now and then one is shown twice — a visible hitch when you turn. With it, frames wait for the refresh, but at most one at a time, so it adds far less delay than a game's own vsync (keep that off). Pair it with Frame limit \(refresh) FPS.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Frame limit")
                    Picker("", selection: Binding(get: { s.fpsLimit }, set: { s.fpsLimit = $0; save() })) {
                        Text("Off").tag(0)
                        // DXMT paces through the screen's refresh: limits above it act like the refresh itself.
                        ForEach([30, 60, 90, 120].filter { !dxmt || $0 <= max(refresh, 60) || $0 == s.fpsLimit }, id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    .labelsHidden().frame(width: 110).disabled(d3dmetal)
                }
                if let b = buffer {
                    HStack {
                        Text("Audio buffer")
                        Picker("", selection: Binding(get: { b }, set: { setBuffer($0) })) {
                            Text("Normal (10 ms)").tag(10); Text("Large (20 ms)").tag(20); Text("Extra large (40 ms)").tag(40)
                        }.labelsHidden().frame(width: 170)
                    }
                    Text("If sound crackles or has static, choose Large: games get a 3× bigger sound buffer, so a busy moment doesn't cause gaps (adds a little sound delay). \(steam ? "Applies to all Steam games; quit Steam first." : "Quit the game first.")")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(d3dmetal ? "Apple Metal uses Apple's own overlay. The frame limit doesn't work in Apple Metal — use the game's own cap instead (e.g. +fps_max 60 for Source games)."
                     : dxmt ? "DXMT's frame limit spaces frames evenly through Metal's own timing, without vsync's queue of waiting frames — set it to your screen's \(refresh) Hz and the game's own cap to unlimited for the smoothest motion with the least delay. It can't go above the screen's refresh; for more frames than that, turn it off and use the game's own cap. \(steam ? "Applies to all Steam games when Steam next starts." : "Takes effect the next time the game starts.")"
                           : "A frame limit keeps the Mac cooler and quieter, makes motion more even, and leaves CPU for sound — also in Compatibility mode. \(steam ? "Applies to all Steam games when Steam next starts." : "Takes effect the next time the game starts.")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Performance").font(.headline) }
        .onAppear { s = Performance.settings(for: game); buffer = AudioBuffer.current(for: game); loaded = true }
    }

    /// Fastest refresh among connected screens (ProMotion and external monitors report 120+).
    var refresh: Int { NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60 }
    var autoFPS: Int { LowLatency.autoFPS(refresh: refresh) }

    func setLowLatency(_ on: Bool) {
        let g = game
        Task {
            let r = await Task.detached { Result { try LowLatency.apply(on, to: g) } }.value
            switch r {
            case .success: model.say(on ? "Low-latency aiming on. Takes effect the next time the game starts." : "Low-latency aiming off."); model.refresh()
            case .failure(let e): model.fail(e)
            }
        }
    }

    func setCap(_ fps: Int?) {
        let g = game
        Task {
            let r = await Task.detached { Result { try LowLatency.applyCap(fps, to: g) } }.value
            switch r {
            case .success: model.say("Frame cap: \(fps.map { $0 == 0 ? "unlimited" : "\($0) FPS" } ?? "game's default"). Takes effect the next time the game starts."); model.refresh()
            case .failure(let e): model.fail(e)
            }
        }
    }

    func setBuffer(_ ms: Int) {
        do { try AudioBuffer.apply(ms, for: game); buffer = AudioBuffer.current(for: game); model.say("Audio buffer: \(ms) ms chunks. Takes effect next start.") }
        catch { model.fail(error) }
    }

    func save() {
        guard loaded else { return }
        do { try Performance.apply(s, for: game); model.say(steam ? "Saved. Restart Steam to apply." : "Saved. Applies next time the game starts.") }
        catch { model.fail(error) }
    }
}

// MARK: - Storage

struct StorageView: View {
    @EnvironmentObject var model: AppModel
    /// Shown as a Settings tab (no title or Done button).
    var embedded = false
    @State private var leftovers: [GameRemoval.Item] = []
    @Environment(\.dismiss) var dismiss
    @State private var volumes: [Storage.VolumeInfo] = []
    @State private var games: [Storage.Item] = []
    @State private var data: [Storage.Item] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !embedded { Text("Storage").font(.title2.bold()) }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh", action: load).disabled(loading)
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }.padding(embedded ? 14 : 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(volumes) { v in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(v.name).font(.body.bold())
                                        Spacer()
                                        Text("\(Storage.format(v.free)) free of \(Storage.format(v.total))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: Double(v.total - v.free), total: Double(max(v.total, 1)))
                                        .tint(Double(v.free) / Double(max(v.total, 1)) < 0.1 ? .orange : .accentColor)
                                }
                            }
                        }.padding(6)
                    } label: { Label("Drives", systemImage: "internaldrive").font(.headline) }

                    GameFoldersBox()

                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(games) { i in row(i) }
                            HStack {
                                Text("Engine files are shared copies (APFS clones), so the real total is smaller than the sum.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear All Logs") {
                                    let n = Storage.clearLogs(model.games); model.say("Cleared \(Storage.format(n)) of logs."); load()
                                }
                            }
                        }.padding(6)
                    } label: { Label("Games", systemImage: "gamecontroller").font(.headline) }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(data) { i in
                                HStack {
                                    row(i)
                                    if i.title == "Downloads" || i.title == "Work folder" {
                                        Button("Empty") { let n = Storage.empty(i.url); model.say("Freed \(Storage.format(n))."); load() }
                                            .disabled(i.bytes == 0)
                                    } else if i.title == "Engines cache" {
                                        Button("Remove Unused") {
                                            let r = RuntimeManager.removeUnused(games: model.games)
                                            model.say(r.isEmpty ? "Every cached engine is in use." : "Removed \(r.count) unused engine(s)."); load()
                                        }
                                    }
                                }
                            }
                        }.padding(6)
                    } label: { Label("Nokcandu's own data", systemImage: "shippingbox").font(.headline) }

                    if !leftovers.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(leftovers) { i in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(i.what)
                                            Text(i.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(Storage.format(i.bytes)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                HStack {
                                    Text("Kept for games that are no longer installed (for example an app deleted in Finder).").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Move to Trash") {
                                        let n = GameRemoval.clean(leftovers); model.say("Moved \(n) leftover item(s) to the Trash."); load()
                                    }
                                }
                            }.padding(6)
                        } label: { Label("Leftovers from removed games", systemImage: "trash").font(.headline) }
                    }
                }.padding(20)
            }
        }
        .frame(width: 700, height: 620)
        .onAppear(perform: load)
    }

    func row(_ i: Storage.Item) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(i.title)
                if !i.detail.isEmpty { Text(i.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(Storage.format(i.bytes)).monospacedDigit().foregroundStyle(.secondary)
            if let g = model.games.first(where: { $0.appURL == i.url }),
               [GameMover.blocker(g), GameMover.filesBlocker(g)].contains(where: { $0 == nil || $0 == "Quit the game first." }) {
                Menu("Move") { GameContextMenuMoveItems(game: g) }.fixedSize().menuStyle(.borderlessButton)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
    }

    func load() {
        loading = true
        let g = model.games
        Task {
            let r = await Task.detached { (Storage.volumes(), Storage.games(g), Storage.nokcanduData(), GameRemoval.orphans(library: g)) }.value
            volumes = r.0; games = r.1; data = r.2; leftovers = r.3; loading = false
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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Mac screen resolution")
                    Picker("Mac screen resolution", selection: Binding(get: { selection }, set: choose)) {
                        Text("Desktop (don't switch)").tag("desktop")
                        if let c = current, !options.contains(where: { $0.pixels == c }) { Text("\(c[0]) × \(c[1])").tag("\(c[0])x\(c[1])") }
                        Section("Full screen — your Mac's screen switches") {
                            ForEach(Array(options.enumerated()), id: \.element.id) { i, r in
                                Text("\(r.width) × \(r.height)\(i == 0 ? " — native" : "")").tag(r.id)
                            }
                        }
                    }.labelsHidden().frame(width: 280)
                }
                Text("Changes your Mac's display while the game runs and restores it afterward. Desktop keeps your current screen resolution. This doesn't change the game's own settings.")
                    .font(.caption).foregroundStyle(.secondary)
                if game.usesSharedSteam { Text("Changing the Mac screen resolution needs Steam closed.").font(.caption).foregroundStyle(.secondary) }
                Divider()
                HStack {
                    Text("Window style")
                    Picker("Window style", selection: Binding(get: { game.custom?.borderless == true }, set: windowStyle)) {
                        Text("Game default").tag(false)
                        Text("Fullscreen (Borderless)").tag(true)
                    }.labelsHidden().frame(width: 280)
                        .disabled(CompatibilityFixes.unavailable(.borderless, for: game) != nil && game.custom?.borderless != true)
                }
                if let reason = CompatibilityFixes.unavailable(.borderless, for: game) {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Choose Windowed inside the game before using Fullscreen (Borderless). This uses the same optional borderless fix as the Fixes panel and leaves the Mac's display mode alone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if OpenUASettings.supports(game) {
                    Divider()
                    Text("OpenUA display").font(.body.bold())
                    Text("Fixes the invisible window and tiny menu text using the settings confirmed on this Mac. The original menu fills the screen; mission resolution stays under the game’s control. These settings are included when you save or share a profile.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(CompatibilityFixes.isInstalled(.openUA, for: game) ? "Undo OpenUA Display Settings" : "Apply Recommended OpenUA Display Settings") { openUASettings() }
                } else if BF1942DisplayFix.supports(game) {
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
                    Text("Updates BF1942's gameplay resolution in its video profiles, with a backup for Undo. The game's menu resolution is handled separately below.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Apply Recommended BF1942 Setup…") { confirmBFSetup = true }
                        .disabled(BF1942DisplayFix.menuUnavailable(for: game) != nil)
                    Text("Includes Older 3D graphics, DirectX 8 compatibility, Microsoft shader libraries, the menu and mod-restart correction, and Fullscreen (Borderless). Keeps your saved game resolution; new setups start at 1280 × 800. Saved and shared profiles include these fixes.")
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
                } else {
                    Text("Set this game's own resolution inside the game.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Settings Backups…") { showSettingsBackups = true }
                if working { ProgressView().controlSize(.small) }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .disabled(working)
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Display").font(.headline) }
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
        let g = game, lib = model.games
        working = true
        Task {
            let r = await Task.detached { Result { try GameDisplay.apply(px, to: g, library: lib) } }.value
            switch r {
            case .success: model.say("Saved the Mac screen resolution for this game."); model.refresh()
            case .failure(let e): model.fail(e)
            }
            working = false
        }
    }
    func windowStyle(_ borderless: Bool) {
        working = true; status = ""
        Task {
            do { try await GameWindowStyle.apply(borderless: borderless, to: game, log: logger); model.refresh() }
            catch { model.fail(error) }
            working = false
        }
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

/// Removes a game completely — its app and everything Nokcandu keeps for it — to the Trash.
struct RemoveGameSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var items: [GameRemoval.Item] = []
    @State private var confirm = false

    var body: some View {
        GroupBox {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remove \(game.name)").font(.body.bold())
                    Text("Moves the app, its dedicated external game folder when listed, and Nokcandu’s records to the Trash. Existing folders used without copying and your saved profiles stay.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Remove Game…", role: .destructive) { items = GameRemoval.items(for: game, library: model.games); confirm = true }
            }
            .padding(6)
        }
        .confirmationDialog("Move \(game.name) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(items.map { "• \($0.what) — \(Storage.format($0.bytes))" }.joined(separator: "\n")
                 + "\n\nYou can put it back from the Trash. Save games stored inside the app go with it.")
        }
    }

    func remove() {
        let g = game, lib = model.games
        Task {
            let r = await Task.detached { Result { try GameRemoval.remove(g, library: lib) } }.value
            switch r {
            case .success(let failed):
                model.say(failed.isEmpty ? "\(g.name) moved to the Trash." : "Moved to the Trash, except: \(failed.joined(separator: "; "))")
                model.selection = nil
                model.refresh()
            case .failure(let e): model.fail(e)
            }
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
                        Text("Move it to another folder or drive to free up space. On APFS or Mac OS Extended drives the whole app moves; on ExFAT drives (most USB drives) only the game's files move and the small app stays here. Keep the drive connected to play.")
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
    @State private var folders = GameFolders.all
    @State private var installTo = GameFolders.installFolder
    @State private var error: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(folders, id: \.self) { f in
                    HStack {
                        Image(systemName: f.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(GameFolderLabel.text(f))
                            let n = model.games.filter { GameFolders.folder(of: $0) == f || (GameMover.externalFiles($0)?.path.hasPrefix(f.path + "/") ?? false) }.count
                            let free = GameFolders.isAvailable(f) ? (GameFolders.freeSpace(f).map { " · \(Storage.format($0)) free" } ?? "") : ""
                            Text("\(n) app\(n == 1 ? "" : "s")\(free)\(f == installTo.standardizedFileURL ? " · new games install here" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if f != installTo.standardizedFileURL, GameFolders.isAvailable(f) {
                            Button("Install Here") { GameFolders.setInstallFolder(f); installTo = GameFolders.installFolder }
                        }
                        Button("Show") { model.reveal(f) }.disabled(!GameFolders.isAvailable(f))
                        if !GameFolders.isStandard(f) {
                            Button("Remove") { GameFolders.remove(f); reload() }
                                .help("Stops showing this folder in Nokcandu. The games in it stay on disk.")
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text("Steam, Battle.net and their games stay in the standard folder (pick a drive in their own settings instead). Other games can live anywhere — move one from its page or by right-clicking it. On ExFAT drives only the game's files are stored; the small app stays on this Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Add Folder…", action: add)
                }
            }.padding(6)
        } label: { Label("Game Folders", systemImage: "folder").font(.headline) }
    }

    func reload() { folders = GameFolders.all; installTo = GameFolders.installFolder; model.refresh() }

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
        .task(id: "\(game.id)-\(measurement)") {
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
