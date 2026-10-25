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

/// Browse everyone's shared profiles, organized by game (most 👍 first).
struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var store = ProfileStore()
    @State private var query = ""
    @State private var sort: Profiles.Sort = .liked
    @State private var storeFilter = "all"
    @State private var selectedGroup: String?
    @State private var detail: CatalogEntry?
    var focusNumber: Int?

    var groups: [ProfileGroup] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return Profiles.groups(store.entries, sort: sort).filter { g in
            let storeOK = storeFilter == "all" || (storeFilter == "other" ? !["steam", "battlenet"].contains(g.source) : g.source == storeFilter)
            return storeOK && (q.isEmpty || g.title.lowercased().contains(q) || g.entries.contains { $0.profile.title.lowercased().contains(q) || ($0.profile.notes ?? "").lowercased().contains(q) })
        }
    }
    var selected: ProfileGroup? { groups.first { $0.id == selectedGroup } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Game Profiles").font(.title2.bold())
                if store.offline { Text("offline — last downloaded catalog").font(.caption).foregroundStyle(.orange) }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { store.load() }.disabled(store.loading)
                Button("Import File…", action: importFile)
                Button("Website") { NSWorkspace.shared.open(Profiles.catalogPage) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Search for a game", text: $query).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("", selection: $sort) { ForEach(Profiles.Sort.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                        Picker("", selection: $storeFilter) {
                            Text("All").tag("all"); Text("Steam").tag("steam"); Text("Battle.net").tag("battlenet"); Text("Other").tag("other")
                        }.labelsHidden()
                    }
                    List(selection: $selectedGroup) {
                        ForEach(groups) { g in groupRow(g).tag(g.id) }
                    }
                    .listStyle(.sidebar)
                    .overlay {
                        if groups.isEmpty && !store.loading {
                            ContentUnavailableView(query.isEmpty ? "No profiles yet" : "No profile for “\(query)” yet", systemImage: "square.stack.3d.up.slash",
                                                   description: Text("When you get a game working, use Share This Setup on its page."))
                        }
                    }
                    Text("\(groups.count) games · \(groups.reduce(0) { $0 + $1.entries.count }) profiles").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(width: 330)
                Divider()
                if let g = selected { GroupDetail(group: g, open: { detail = $0 }).id(g.id) }
                else { ContentUnavailableView("Choose a game", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .frame(width: 980, height: 660)
        .onAppear { store.load(); focus() }
        .onChange(of: store.entries) { focus() }
        .sheet(item: $detail) { e in
            VStack(spacing: 0) {
                ProfileDetail(entry: e)
                Divider()
                HStack { Spacer(); Button("Close") { detail = nil }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .frame(width: 640, height: 600)
            .environmentObject(model)
        }
    }

    func focus() {
        guard let n = focusNumber, let e = store.entries.first(where: { $0.number == n }) else {
            if selectedGroup == nil { selectedGroup = groups.first?.id }
            return
        }
        selectedGroup = Profiles.groupKey(e.profile)
        if detail == nil { detail = e }
    }

    func groupRow(_ g: ProfileGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(g.title).font(.headline).lineLimit(1)
            HStack(spacing: 8) {
                RatingBadge(rating: g.bestRating)
                Text("\(g.entries.count) profile\(g.entries.count == 1 ? "" : "s")")
                Label("\(g.totalUp)", systemImage: "hand.thumbsup")
                if let d = g.newest { Text(d.formatted(.relative(presentation: .named))) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 2)
    }

    func importFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url, let text = try? String(contentsOf: u, encoding: .utf8) else { return }
        do {
            let prof = try GameProfile.parse(text)
            let problems = prof.problems
            guard problems.isEmpty else { throw NokError("This profile isn't safe to use: \(problems.joined(separator: "; "))") }
            detail = CatalogEntry(number: 0, url: Profiles.catalogPage, author: "a file", up: 0, down: 0, comments: 0, updated: "", profile: prof)
        } catch { model.fail(error) }
    }
}

/// One game's profiles, best first.
struct GroupDetail: View {
    let group: ProfileGroup
    let open: (CatalogEntry) -> Void
    @State private var showBroken = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.title).font(.title2.bold())
                    Spacer()
                    if let id = group.steamAppID {
                        Link("Steam page", destination: URL(string: "https://store.steampowered.com/app/\(id)")!)
                    }
                }
                Text("\(group.entries.count) profile\(group.entries.count == 1 ? "" : "s") · most 👍 first").font(.caption).foregroundStyle(.secondary)
                ForEach(group.entries.filter { !$0.reportedBroken }) { ProfileCard(entry: $0, open: open) }
                let broken = group.entries.filter(\.reportedBroken)
                if !broken.isEmpty {
                    DisclosureGroup("Reported not working (\(broken.count))", isExpanded: $showBroken) {
                        ForEach(broken) { ProfileCard(entry: $0, open: open).opacity(0.7) }
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProfileCard: View {
    let entry: CatalogEntry
    let open: (CatalogEntry) -> Void
    var p: GameProfile { entry.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RatingBadge(rating: p.rating)
                Label("\(entry.up)", systemImage: "hand.thumbsup")
                Label("\(entry.down)", systemImage: "hand.thumbsdown")
                Label("\(entry.comments)", systemImage: "bubble.left")
                Spacer()
                Text(dates).foregroundStyle(.secondary)
            }.font(.caption)
            if let n = p.notes, !n.isEmpty { Text(n).lineLimit(4).fixedSize(horizontal: false, vertical: true) }
            Text(ProfileText.summary(p)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let t = p.tested { Text("Tested on " + [t.mac, t.macOS, t.engine].compactMap { $0 }.joined(separator: " · ")) }
                if entry.testedOnOtherEngine { Label("different engine than today's", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("View & Apply…") { open(entry) }.buttonStyle(.borderedProminent)
                Button("Vote or Comment") { NSWorkspace.shared.open(entry.url) }
                Spacer()
                Text("by \(entry.author)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    var dates: String {
        var parts: [String] = []
        if let c = entry.createdDate { parts.append("shared \(c.formatted(date: .abbreviated, time: .omitted))") }
        if let u = entry.updatedDate, u.timeIntervalSince(entry.createdDate ?? .distantPast) > 3600 { parts.append("updated \(u.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

enum ProfileText {
    static func summary(_ p: GameProfile) -> String {
        var s: [String] = []
        if let g = p.graphics { s.append(g.title) }
        if let prog = p.program { s.append(prog.split(separator: "\\").last.map(String.init) ?? prog) }
        if let a = p.arguments, !a.isEmpty { s.append(a) }
        if let a = p.hostArguments, !a.isEmpty { s.append("Battle.net: \(a)") }
        if let e = p.environment, !e.isEmpty { s.append(e.keys.sorted().joined(separator: ", ")) }
        if let r = p.rawMouse, r > 0 { s.append("raw mouse \(String(format: "%.2g", r))×") }
        if p.fixes?.contains("cinematic") == true { s.append("cinematic fix") }
        if let d = p.drives { s.append(d.map { "\($0):" }.joined(separator: " ")) }
        if p.disc == true { s.append("disc image") }
        return s.joined(separator: " · ")
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
                    Text("Shared by \(entry.author)" + (entry.createdDate.map { " on \($0.formatted(date: .long, time: .omitted))" } ?? "") + (entry.updatedDate.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
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
            let left = Profiles.notShared(from: game)
            if !left.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not shared:").font(.caption.bold())
                    ForEach(left, id: \.self) { Text("• " + $0).font(.caption) }
                }.foregroundStyle(.secondary)
            }
            if profile.fixes?.contains("cinematic") == true {
                Label("Includes the cinematic fix (LAV Filters) — Apply installs it for others.", systemImage: "film").font(.caption)
            }
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
        .onAppear { if notes.isEmpty { notes = Profiles.suggestedNotes(for: game) } }
    }

    func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(CustomGames.safeFolderName(profile.title)).nokcandu-profile.json"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Data(profile.json().utf8).write(to: u) } catch { model.fail(error) }
    }
}
