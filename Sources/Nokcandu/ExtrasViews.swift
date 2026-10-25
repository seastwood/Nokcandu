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

    var steam: Bool { game.usesSharedSteam || game.isSteamHost }
    var metal: Bool { game.custom?.graphics == .appleMetal }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show FPS counter", isOn: Binding(get: { s.fpsCounter }, set: { s.fpsCounter = $0; save() }))
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
                Text(metal ? "Apple Metal shows Apple's own performance overlay; vsync and frame limit only work in Classic 3D and Modern 3D."
                           : "A frame limit keeps the Mac cooler and quieter and makes motion more even. \(steam ? "Applies to all Steam games when Steam next starts." : "Takes effect the next time the game starts.")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Performance").font(.headline) }
        .onAppear { s = Performance.settings(for: game); loaded = true }
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
