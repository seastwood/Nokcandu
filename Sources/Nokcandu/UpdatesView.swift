import SwiftUI
import AppKit
import NokcanduCore

/// Keeps Nokcandu's components current: the Wine engine and graphics/wrapper files each game uses, and the
/// cinematic fix. Nothing changes until you choose it, and every engine change can be rolled back.
struct UpdatesView: View {
    @EnvironmentObject var model: AppModel
    /// Shown as a Settings tab (no title or Done button).
    var embedded = false
    @Environment(\.dismiss) var dismiss
    @State private var checking = false
    @State private var busy: String?          // what's running now
    @State private var log: [String] = []
    @State private var tick = 0
    @State private var confirmTry: InstalledGame?     // an app whose games use the resizable window

    var cat: UpdateCatalog? { model.catalog }
    var hosts: [InstalledGame] { _ = tick; return EngineUpdate.hosts(in: model.games) }
    var newestEngine: EngineVersion? { cat?.latestEngine?.version }
    var newestTemplate: TemplateVersion { cat?.latestTemplate?.version ?? .tested }
    var targetID: String? { newestEngine.map { RuntimeManager.runtimeID(engine: $0, template: newestTemplate) } }
    var downloaded: Bool { _ = tick; return targetID.map(RuntimeManager.isCached(id:)) ?? false }
    var failedTest: Bool { _ = tick; return targetID.map(EngineSelfTests.failed) ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if !embedded { Text("Updates").font(.title2.bold()) }
                    Text(cat.map { "Checked \($0.checkedAt.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Check Now") { Task { checking = true; await model.checkForUpdates(); checking = false } }.disabled(checking)
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .padding(embedded ? 14 : 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appSection
                    engineSection
                    lavSection
                    rosettaSection
                    otherSection
                    if !log.isEmpty {
                        Text(log.suffix(10).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 640)
        .confirmationDialog("Try \(newestEngine?.description ?? "the new engine") for \(confirmTry?.name ?? "this app")?",
                            isPresented: Binding(get: { confirmTry != nil }, set: { if !$0 { confirmTry = nil } })) {
            Button("Keep the Current Engine", role: .cancel) { confirmTry = nil }
            Button("Try It Anyway") { if let g = confirmTry { tryEngine(g) }; confirmTry = nil }
        } message: {
            Text(confirmTry.flatMap { g in newestEngine.flatMap { WindowedPresentation.engineUpdateWarning(host: g, games: model.games, target: $0) } } ?? "")
        }
        .task { if cat == nil { checking = true; await model.checkForUpdates(quiet: true); checking = false } }
    }

    // MARK: Nokcandu itself

    var appSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let r = model.appUpdate {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nokcandu \(r.version) is available").font(.body.bold())
                            Text("You have \(AppUpdate.currentVersion).").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if busy == "app" { ProgressView().controlSize(.small) }
                        Button("Release Notes") { NSWorkspace.shared.open(r.page) }.buttonStyle(.link)
                        Button("Update & Restart") { updateApp(r) }.buttonStyle(.borderedProminent).disabled(busy != nil)
                    }
                    if !r.notes.isEmpty {
                        Text(r.notes).font(.caption).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                    }
                } else {
                    Text("Nokcandu \(AppUpdate.currentVersion) — up to date.").foregroundStyle(.secondary)
                }
                Text("Updates come from github.com/\(AppUpdate.repo) and are checked against GitHub's published checksum before installing. Your games and settings aren't touched.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Nokcandu", systemImage: "app.badge") .font(.headline) }
    }

    func updateApp(_ r: AppUpdate.Release) {
        busy = "app"
        Task {
            do { try await AppUpdate.install(r, log: logger(), quit: { Task { @MainActor in NSApp.terminate(nil) } }) }
            catch { model.fail(error); busy = nil }
        }
    }

    // MARK: Engine

    var engineSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let e = newestEngine {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Newest: \(e.description) with graphics/wrapper \(newestTemplate.description)").font(.body.bold())
                            Text("Nokcandu's tested setup: \(EngineVersion.tested.description) with \(TemplateVersion.tested.description). Newer engines often fix games but can also break one that worked — that's why each app tries it separately and can roll back.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if busy == "download" {
                                Text(log.last ?? "Downloading and testing…").font(.caption).foregroundStyle(.tint).lineLimit(1)
                            }
                        }
                        Spacer()
                        if failedTest {
                            Button("Test Again") { if let id = targetID { EngineSelfTests.forget(id); tick += 1; Task { _ = await prepare() } } }
                                .disabled(busy != nil)
                        } else if downloaded { Label("Downloaded · tested", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                        else if let a = cat?.latestEngine?.asset {
                            Button("Download & Test (\(ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file)))") { Task { _ = await prepare() } }
                                .disabled(busy != nil)
                        }
                    }
                    if failedTest {
                        Label("\(e.description) didn't pass Nokcandu's test on this Mac — it can't start Windows programs with this wrapper yet. Your games stay on their current engine. Nokcandu checks daily for a fixed build.", systemImage: "xmark.octagon")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    ForEach(hosts) { g in hostRow(g, newest: e) }
                    Text("Steam games all use the shared Steam's engine. Trying an engine keeps the old one and the old Windows system files; your saves, game files and settings aren't touched.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(checking ? "Checking…" : "Check for updates to see the newest engine.").foregroundStyle(.secondary)
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Wine engine & graphics", systemImage: "cpu").font(.headline) }
    }

    func hold(_ g: InstalledGame, _ on: Bool) {
        do { try EngineUpdate.setHeld(g, on); tick += 1; model.say(on ? "\(g.name) will stay on its current engine." : "\(g.name) can try new engines again.") }
        catch { model.fail(error) }
    }

    @ViewBuilder
    func hostRow(_ g: InstalledGame, newest: EngineVersion) -> some View {
        let cur = EngineUpdate.current(g)
        let st = EngineUpdate.state(for: g)
        let running: Bool = { if case .launcherRunning = model.runStates[g.id] ?? .notRunning { return true }; return false }()
        HStack(spacing: 10) {
            Image(nsImage: g.icon).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.isSteamHost ? "Steam (all Steam games)" : g.name)
                if busy == g.id {
                    // What's happening right now, instead of a version label that changes only at the end.
                    Text(log.last ?? "Working…").font(.caption).foregroundStyle(.tint).lineLimit(1)
                } else {
                Text((cur?.description ?? g.wineVersion ?? "unknown engine") + (st?.status == .trying ? " · trying it — was \(EngineVersion(versionString: st!.previousEngine)?.description ?? st!.previousEngine). Play, then Keep or Roll Back." : ""))
                    .font(.caption).foregroundStyle(st?.status == .trying ? .orange : .secondary)
                }
            }
            Spacer()
            if busy == g.id { ProgressView().controlSize(.small) }
            else if EngineUpdate.isHeld(g) {
                Label("Staying on this engine", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary)
                Button("Allow Updates") { hold(g, false) }.disabled(busy != nil)
            } else if st?.status == .trying {
                Button("Keep") { keep(g) }.disabled(busy != nil)
                Button("Roll Back") { rollBack(g) }.disabled(busy != nil || running)
            } else if let c = cur, c < newest, failedTest {
                Text("Newest didn't pass test").font(.caption).foregroundStyle(.secondary)
            } else if let c = cur, c < newest, let warning = WindowedPresentation.engineUpdateWarning(host: g, games: model.games, target: newest) {
                // Games here use the resizable window, which this engine doesn't support yet: held back by default.
                InfoButton(warning)
                Text("Kept for the resizable window").font(.caption).foregroundStyle(.secondary)
                Button("Try Anyway…") { confirmTry = g }.disabled(busy != nil || running)
            } else if let c = cur, c < newest {
                Button("Try \(newest.description)") { tryEngine(g) }.disabled(busy != nil || running)
                    .help(running ? "Quit it first." : "Switches this app to the newest engine; you can roll back.")
                Button { hold(g, true) } label: { Image(systemName: "pin") }.buttonStyle(.borderless)
                    .help("Keep \(g.name) on its current engine (for a game that plays well as it is).")
            } else if cur != nil {
                Text("Up to date").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func logger() -> @Sendable (String) -> Void { { line in Task { @MainActor in log.append(line) } } }

    /// Downloads and assembles the newest engine + template in the cache.
    func prepare() async -> String? {
        guard let cat, let e = newestEngine else { return nil }
        if let id = targetID, RuntimeManager.isCached(id: id) { return id }
        busy = "download"; defer { busy = nil; tick += 1 }
        let l = logger(), t = newestTemplate
        do { return try await RuntimeManager.build(engine: e, template: t, catalog: cat, log: l) }
        catch { model.fail(error); return nil }
    }

    func tryEngine(_ g: InstalledGame) {
        Task {
            guard let id = await prepare() else { return }
            busy = g.id; defer { busy = nil; tick += 1 }
            let l = logger()
            do {
                try await EngineUpdate.apply(g, runtimeID: id, log: l)
                model.refresh()
                model.say("\(g.isSteamHost ? "Steam" : g.name) is trying \(newestEngine?.description ?? "the new engine"). Play it, then Keep or Roll Back.")
            } catch { model.fail(error); model.refresh() }
        }
    }

    func keep(_ g: InstalledGame) {
        do { try EngineUpdate.keep(g); tick += 1; model.refresh(); model.say("Kept. The old engine's space was freed.") } catch { model.fail(error) }
    }

    func rollBack(_ g: InstalledGame) {
        Task {
            busy = g.id; defer { busy = nil; tick += 1 }
            do { try await EngineUpdate.rollBack(g, log: logger()); model.refresh(); model.say("Rolled back.") }
            catch { model.fail(error) }
        }
    }

    // MARK: LAV Filters

    var lavSection: some View {
        let withFix = hosts.filter { CinematicFix.isPresent(for: $0) }
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Newest: LAV Filters \(cat?.lav?.version ?? CinematicFix.version)" + (cat?.lav == nil ? " (tested)" : ""))
                    .font(.body.bold())
                if withFix.isEmpty {
                    Text("No game has the cinematic fix installed.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(withFix) { g in
                    let v = CinematicFix.state(for: g)?.version ?? "installed by hand"
                    HStack {
                        Image(nsImage: g.icon).resizable().frame(width: 22, height: 22)
                        Text(g.isSteamHost ? "Steam (all Steam games)" : g.name)
                        Text(v).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if busy == "lav-\(g.id)" { ProgressView().controlSize(.small) }
                        else if let lav = cat?.lav, v != lav.version {
                            Button("Update to \(lav.version)") { updateLAV(g, lav) }.disabled(busy != nil)
                        } else { Text("Up to date").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Cinematic fix", systemImage: "film").font(.headline) }
    }

    func updateLAV(_ g: InstalledGame, _ r: CinematicFix.Release) {
        Task {
            busy = "lav-\(g.id)"; defer { busy = nil; tick += 1 }
            do { try await CinematicFix.install(for: g, release: r, log: logger()); model.say("Cinematic fix updated to \(r.version).") }
            catch { model.fail(error) }
        }
    }

    // MARK: Apple silicon / macOS 28

    var rosettaSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let n = cat?.nativeEngines, !n.isEmpty {
                    Label("An engine built for Apple silicon is available: \(n.joined(separator: ", ")).", systemImage: "sparkles")
                        .foregroundStyle(.green)
                } else {
                    Text("All current Wine engines are Intel code that runs through Rosetta. Apple has said full Rosetta ends with macOS 28. Nokcandu checks daily for an engine built for Apple silicon and will show it here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Until one exists, wait before upgrading to macOS 28.").font(.caption.bold())
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Apple silicon & macOS 28", systemImage: "apple.logo").font(.headline) }
    }

    var otherSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Steam and Battle.net update themselves when they start. Games bought on those stores update there too.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(RuntimeManager.cachedRuntimes().count) engine\(RuntimeManager.cachedRuntimes().count == 1 ? "" : "s") kept in Nokcandu's cache.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Unused Engines") {
                        let r = RuntimeManager.removeUnused(games: model.games); tick += 1
                        model.say(r.isEmpty ? "Nothing to remove." : "Removed \(r.count) unused engine\(r.count == 1 ? "" : "s").")
                    }
                    .disabled(busy != nil)
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Everything else", systemImage: "shippingbox").font(.headline) }
    }
}

/// Shown on a game's page while it's trying a new engine.
struct EngineTrialBanner: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    let state: EngineUpdate.State
    @State private var working = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Trying \(EngineVersion(versionString: state.engine)?.description ?? state.engine)").font(.body.bold())
                Text("Play \(game.isSteamHost ? "your Steam games" : "it") a bit. If it works as well or better, Keep it; otherwise Roll Back to \(EngineVersion(versionString: state.previousEngine)?.description ?? state.previousEngine).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("Keep") {
                do { try EngineUpdate.keep(game); model.refresh(); model.say("Kept the new engine.") } catch { model.fail(error) }
            }.buttonStyle(.borderedProminent).disabled(working)
            Button("Roll Back") {
                working = true
                Task {
                    do { try await EngineUpdate.rollBack(game) { _ in }; model.refresh(); model.say("Rolled back.") } catch { model.fail(error) }
                    working = false
                }
            }.disabled(working)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
