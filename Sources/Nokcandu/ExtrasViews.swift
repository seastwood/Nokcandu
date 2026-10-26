import SwiftUI
import AppKit
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
                    Image(systemName: d.connected ? "externaldrive.fill" : "externaldrive.badge.xmark")
                        .foregroundStyle(d.connected ? Color.secondary : Color.orange)
                    Text(d.target).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if !d.connected { Text("not connected").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    if d.connected { Button("Show") { NSWorkspace.shared.open(URL(fileURLWithPath: d.target)) }.buttonStyle(.link) }
                    Button("Remove") { remove(d) }.buttonStyle(.link)
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
    var metal: Bool { game.custom?.graphics == .appleMetal }

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
                Toggle("Vsync (smoother motion, no tearing; adds a little delay)", isOn: Binding(get: { s.vsync }, set: { s.vsync = $0; save() }))
                    .disabled(metal)
                HStack {
                    Text("Frame limit")
                    Picker("", selection: Binding(get: { s.fpsLimit }, set: { s.fpsLimit = $0; save() })) {
                        Text("Off").tag(0)
                        ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) FPS").tag($0) }
                    }
                    .labelsHidden().frame(width: 110).disabled(metal)
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
                Text(metal ? "Apple Metal uses Apple's own overlay. Vsync and frame limit only work in Classic 3D and Modern 3D — use the game's own settings instead (e.g. +fps_max 60 for Source games)."
                           : "A frame limit keeps the Mac cooler and quieter and makes motion more even. \(steam ? "Applies to all Steam games when Steam next starts." : "Takes effect the next time the game starts.")")
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
    @Environment(\.dismiss) var dismiss
    @State private var volumes: [Storage.VolumeInfo] = []
    @State private var games: [Storage.Item] = []
    @State private var data: [Storage.Item] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Storage").font(.title2.bold())
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh", action: load).disabled(loading)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
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
            Button { NSWorkspace.shared.activateFileViewerSelecting([i.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
    }

    func load() {
        loading = true
        let g = model.games
        Task {
            let r = await Task.detached { (Storage.volumes(), Storage.games(g), Storage.nokcanduData()) }.value
            volumes = r.0; games = r.1; data = r.2; loading = false
        }
    }
}

// MARK: - Game resolution

struct GameResolutionSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var options: [GameDisplay.Resolution] = []

    var current: [Int]? { game.custom?.displayPixels }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Game resolution")
                    Picker("", selection: Binding(get: { current.map { "\($0[0])x\($0[1])" } ?? "desktop" }, set: { choose($0) })) {
                        Text("Desktop (don't switch)").tag("desktop")
                        if let c = current, !options.contains(where: { $0.pixels == c }) { Text("\(c[0]) × \(c[1])").tag("\(c[0])x\(c[1])") }
                        ForEach(Array(options.enumerated()), id: \.element.id) { i, r in
                            Text("\(r.width) × \(r.height)\(i == 0 ? " — native" : "")").tag(r.id)
                        }
                    }.labelsHidden().frame(width: 280)
                }
                Text("While the game runs, your Mac's screen switches to exactly this many pixels (other apps look small if you alt-tab), and your desktop comes back when it quits. In the game, choose **Fullscreen Windowed**: it then matches the screen, so nothing switches while you play, and changing settings or alt-tabbing can't resize it. Lower resolutions give more FPS.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if game.usesSharedSteam {
                    Text("Changing this needs Steam closed.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Display").font(.headline) }
        .onAppear { options = GameDisplay.resolutions() }
    }

    func choose(_ tag: String) {
        let px: [Int]? = tag == "desktop" ? nil : tag.split(separator: "x").compactMap { Int($0) }
        let g = game, lib = model.games
        Task {
            let r = await Task.detached { Result { try GameDisplay.apply(px, to: g, library: lib) } }.value
            switch r {
            case .success: model.say(px.map { "Game resolution: \($0[0]) × \($0[1]). Set the game to Fullscreen Windowed." } ?? "The display won't switch for this game."); model.refresh()
            case .failure(let e): model.fail(e)
            }
        }
    }
}
