import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

@MainActor
final class ProfileStore: ObservableObject {
    @Published var entries: [CatalogEntry] = Profiles.cached()
    @Published var loading = false
    @Published var offline = false
    func load() {
        loading = true
        Task {
            let r = await Profiles.fetch()
            entries = r.entries; offline = r.offline; loading = false
        }
    }
}

struct RatingBadge: View {
    let rating: GameProfile.Rating
    var body: some View {
        Text(rating.title).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
    var color: Color { switch rating { case .works: .green; case .playable: .orange; case .broken: .red } }
}

/// Browse and search everyone's shared game profiles.
struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var store = ProfileStore()
    @State private var query = ""
    @State private var selected: CatalogEntry?
    @State private var showBroken = false
    var focusNumber: Int?

    var filtered: [CatalogEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return store.entries.filter { q.isEmpty || $0.profile.title.lowercased().contains(q) || ($0.profile.notes ?? "").lowercased().contains(q) }
            .sorted { $0.score > $1.score }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Game Profiles").font(.title2.bold())
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button("Import File…", action: importFile)
                Button("Website") { NSWorkspace.shared.open(Profiles.catalogPage) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
            TextField("Search for a game", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 16)
            if store.offline { Text("Offline — showing the last downloaded catalog.").font(.caption).foregroundStyle(.orange).padding(.top, 4) }
            HStack(spacing: 0) {
                List(selection: Binding(get: { selected?.number }, set: { n in selected = store.entries.first { $0.number == n } })) {
                    ForEach(filtered.filter { !$0.reportedBroken }) { row($0).tag($0.number) }
                    let broken = filtered.filter(\.reportedBroken)
                    if !broken.isEmpty {
                        DisclosureGroup("Reported not working (\(broken.count))", isExpanded: $showBroken) {
                            ForEach(broken) { row($0).tag($0.number) }
                        }
                    }
                }
                .frame(width: 300)
                .overlay {
                    if filtered.isEmpty && !store.loading {
                        ContentUnavailableView(query.isEmpty ? "No profiles yet" : "No profile for “\(query)” yet", systemImage: "square.stack.3d.up.slash",
                                               description: Text("When you get a game working, use Share This Setup on its page so others can play it too."))
                    }
                }
                Divider()
                if let e = selected { ProfileDetail(entry: e).id(e.number) }
                else { ContentUnavailableView("Choose a profile", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity) }
            }
        }
        .frame(width: 900, height: 620)
        .onAppear {
            store.load()
            if let n = focusNumber { selected = store.entries.first { $0.number == n } }
        }
        .onChange(of: store.entries) { if let n = focusNumber, selected == nil { selected = store.entries.first { $0.number == n } } }
    }

    func row(_ e: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(e.profile.title).font(.headline)
            HStack(spacing: 8) {
                RatingBadge(rating: e.profile.rating)
                Label("\(e.up)", systemImage: "hand.thumbsup").font(.caption)
                Label("\(e.down)", systemImage: "hand.thumbsdown").font(.caption)
                Label("\(e.comments)", systemImage: "bubble.left").font(.caption)
            }.foregroundStyle(.secondary)
        }.padding(.vertical, 2)
    }

    func importFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url, let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        do {
            let prof = try GameProfile.parse(text)
            let problems = prof.problems
            guard problems.isEmpty else { throw NokError("This profile isn't safe to use: \(problems.joined(separator: "; "))") }
            selected = CatalogEntry(number: 0, url: Profiles.catalogPage, author: "file", up: 0, down: 0, comments: 0, updated: "", profile: prof)
        } catch { model.fail(error) }
    }
}

/// One profile: what it does, votes, and Apply.
struct ProfileDetail: View {
    @EnvironmentObject var model: AppModel
    let entry: CatalogEntry
    @State private var target: InstalledGame.ID?
    @State private var includeShared = true
    @State private var working = false
    @State private var undoSnapshot: Profiles.Snapshot?

    var p: GameProfile { entry.profile }
    var matching: [InstalledGame] { model.games.filter { Profiles.matches(p, $0) } }
    /// Other games it can be tried on (handy for similar games with no profile yet).
    var others: [InstalledGame] { model.games.filter { Profiles.canTry($0) && !Profiles.matches(p, $0) } }
    var choices: [InstalledGame] { matching + others }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.title).font(.title2.bold())
                    RatingBadge(rating: p.rating)
                    Spacer()
                }
                if entry.number > 0 {
                    HStack(spacing: 14) {
                        Label("\(entry.up) found it works", systemImage: "hand.thumbsup")
                        Label("\(entry.down) say it doesn't", systemImage: "hand.thumbsdown")
                        Label("\(entry.comments) comments", systemImage: "bubble.left")
                        Spacer()
                        Button("Vote or Comment on GitHub") { NSWorkspace.shared.open(entry.url) }
                    }.font(.callout).foregroundStyle(.secondary)
                    if entry.reportedBroken {
                        Label("Many people report this profile doesn't work. Read the comments first.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("Shared by \(entry.author)").font(.caption).foregroundStyle(.secondary)
                }
                if let t = p.tested {
                    Text("Tested on \([t.mac, t.macOS, t.engine, t.nokcandu.map { "Nokcandu \($0)" }].compactMap { $0 }.joined(separator: " · "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let n = p.notes, !n.isEmpty { section("Notes") { Text(n).textSelection(.enabled) } }
                if let i = p.install, !i.isEmpty { section("How to install") { Text(i).textSelection(.enabled) } }
                section("Apply to") {
                    if matching.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(notInstalledText).foregroundStyle(.secondary)
                            HStack {
                                if p.source == "steam", let id = p.match.steamAppID {
                                    Button("Install in Steam") { do { try SharedSteam.install(appID: id) } catch { model.fail(error) } }
                                }
                                if p.source == "battlenet", let h = BattleNet.host(in: model.games) { Button("Open Battle.net") { model.play(h) } }
                                if ["installer", "disc", "folder"].contains(p.source) { Button("Install a Game…") { model.showProfiles = false; model.showInstaller = true } }
                            }
                        }
                    }
                    if !choices.isEmpty {
                        Picker(matching.isEmpty ? "Try on another game" : "Game", selection: Binding(get: { target ?? choices.first?.id }, set: { target = $0 })) {
                            if !matching.isEmpty {
                                Section("Made for this game") { ForEach(matching) { Text($0.name).tag(Optional($0.id)) } }
                            }
                            if !others.isEmpty {
                                Section("Try on another game") { ForEach(others) { Text($0.name).tag(Optional($0.id)) } }
                            }
                        }.frame(maxWidth: 340)
                        if let g = chosen {
                            if !Profiles.matches(p, g) {
                                Label("Made for \(p.title), not \(g.name). Similar games often need the same settings — try it, and Undo if it doesn't help.", systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            let plan = Profiles.plan(p, for: g)
                            ForEach(plan.gameSettings, id: \.self) { Label($0, systemImage: "checkmark") }
                            if !plan.sharedSettings.isEmpty {
                                Toggle("Also set: " + plan.sharedSettings.joined(separator: "; "), isOn: $includeShared).toggleStyle(.checkbox)
                            }
                            if plan.needsCinematicFix { Label("Installs the cinematic fix (LAV Filters)", systemImage: "film") }
                            ForEach(plan.skipped, id: \.self) { Label($0, systemImage: "minus.circle").foregroundStyle(.secondary) }
                            HStack {
                                Button(Profiles.matches(p, g) ? "Apply" : "Try It") { apply(g, plan) }.buttonStyle(.borderedProminent).disabled(working)
                                if let u = undoSnapshot {
                                    Button("Undo (\(u.gameName))") { undo(u) }.disabled(working)
                                }
                                if working { ProgressView().controlSize(.small) }
                            }
                            Text("Undo puts back the settings from before. The cinematic fix has its own Undo in the game's Fixes.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Profile details") { Text(p.json()).font(.caption.monospaced()).textSelection(.enabled) }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var chosen: InstalledGame? { choices.first { $0.id == (target ?? choices.first?.id) } }

    var notInstalledText: String {
        switch p.source {
        case "steam": "Install this game in Steam, add it from Steam → Steam Games, then come back here."
        case "battlenet": "Install it in Battle.net, add it from Battle.net → Blizzard Games, then come back here."
        default: "Install the game with Install a Game… (it uses \(p.match.exeName ?? "the game's program")), then come back here."
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); c() }
    }

    func undo(_ snap: Profiles.Snapshot) {
        do { try Profiles.undo(snap); undoSnapshot = nil; model.refresh(); model.say("Put back \(snap.gameName)'s previous settings.") }
        catch { model.fail(error) }
    }

    func apply(_ g: InstalledGame, _ plan: Profiles.Plan) {
        working = true
        Task {
            do {
                undoSnapshot = try Profiles.apply(p, to: g, includeShared: includeShared)
                if plan.needsCinematicFix { try await CinematicFix.install(for: g) { _ in } }
                model.refresh()
                model.say("Applied “\(p.title)” to \(g.name).")
            } catch { model.fail(error) }
            working = false
        }
    }
}

/// On a game's page: profiles others shared for it, and sharing this setup.
struct ProfilesSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var entries: [CatalogEntry] = []
    @State private var sharing = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if entries.isEmpty {
                    Text("No shared profiles for this game yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(entries.prefix(3)) { e in
                        HStack {
                            RatingBadge(rating: e.profile.rating)
                            Text("👍 \(e.up)  👎 \(e.down)").font(.caption).foregroundStyle(.secondary)
                            Text(e.profile.notes?.components(separatedBy: .newlines).first ?? "").lineLimit(1).font(.caption)
                            Spacer()
                            Button("View") { model.profileFocus = e.number; model.showProfiles = true }
                        }
                    }
                }
                HStack {
                    Button("Browse All Profiles…") { model.profileFocus = nil; model.showProfiles = true }
                    Button("Share This Setup…") { sharing = true }
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Shared Profiles").font(.headline) }
        .task {
            entries = Profiles.forGame(game, in: Profiles.cached())
            let r = await Profiles.fetch()
            entries = Profiles.forGame(game, in: r.entries)
        }
        .sheet(isPresented: $sharing) { ShareProfileView(game: game).environmentObject(model) }
    }
}

struct ShareProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let game: InstalledGame
    @State private var rating: GameProfile.Rating = .works
    @State private var notes = ""
    @State private var install = ""

    var profile: GameProfile { Profiles.make(from: game, rating: rating, notes: notes.isEmpty ? nil : notes, install: install.isEmpty ? nil : install) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share This Setup").font(.title2.bold())
            Text("Publishes \(game.name)'s working settings so anyone can apply them. Only settings are shared — no files, paths, accounts or personal details. It appears in Game Profiles after an automatic safety check; people vote and comment on GitHub.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("How well does it run?", selection: $rating) { ForEach(GameProfile.Rating.allCases) { Text($0.title).tag($0) } }
            Text("Notes (what works, known issues, tips)").font(.caption)
            TextEditor(text: $notes).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            Text("How to install (optional)").font(.caption)
            TextEditor(text: $install).frame(height: 50).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            DisclosureGroup("What will be shared") { Text(profile.json()).font(.caption.monospaced()).textSelection(.enabled) }
            if !profile.problems.isEmpty {
                Text(profile.problems.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Save File…", action: save)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Submit on GitHub…") { NSWorkspace.shared.open(Profiles.submitURL(profile)); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!profile.problems.isEmpty)
            }
            Text("GitHub opens with everything filled in — sign in and click Submit.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 560)
    }

    func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(CustomGames.safeFolderName(profile.title)).nokcandu-profile.json"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Data(profile.json().utf8).write(to: u) } catch { model.fail(error) }
    }
}
