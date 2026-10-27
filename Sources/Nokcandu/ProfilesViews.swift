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
    @State private var tab = "community"
    @State private var mine: [MyProfile] = MyProfiles.all()
    @State private var selectedMine: MyProfile.ID?
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
                    Picker("", selection: $tab) {
                        Text("Community").tag("community")
                        Text("Favorites (\(mine.filter { $0.favoriteOf != nil }.count))").tag("favorites")
                        Text("Mine (\(mine.filter { $0.favoriteOf == nil }.count))").tag("mine")
                    }.pickerStyle(.segmented).labelsHidden()
                    if tab == "mine" || tab == "favorites" {
                        List(selection: $selectedMine) {
                            ForEach(mine.filter { (tab == "favorites") == ($0.favoriteOf != nil) }) { m in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name).font(.headline).lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(m.profile.title)
                                        Text("· \(m.updated.formatted(.relative(presentation: .named)))")
                                        if m.sharedAt != nil { Image(systemName: "person.2").help("Shared with everyone") }
                                        if m.favoriteOf != nil { Image(systemName: "star.fill").foregroundStyle(.yellow).help("Favorite from the community") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.tag(m.id)
                            }
                        }
                        .listStyle(.sidebar)
                        .overlay {
                            if !mine.contains(where: { (tab == "favorites") == ($0.favoriteOf != nil) }) {
                                if tab == "favorites" {
                                    ContentUnavailableView("No favorites yet", systemImage: "star",
                                                           description: Text("Click the ☆ on any community profile. It's kept exactly as it was then, even if its author changes it later."))
                                } else {
                                    ContentUnavailableView("No saved profiles", systemImage: "tray",
                                                           description: Text("Use Save Setup as Profile… on a game's page, or Import File…. They stay on this Mac until you share them."))
                                }
                            }
                        }
                    } else {
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
                }
                .padding(12)
                .frame(width: 330)
                Divider()
                if tab == "mine" || tab == "favorites" {
                    if let m = mine.first(where: { $0.id == selectedMine && (tab == "favorites") == ($0.favoriteOf != nil) }) {
                        MyProfileDetail(item: m, changed: reloadMine, openInCatalog: openInCatalog).id(m.id)
                    } else {
                        ContentUnavailableView("Choose a profile", systemImage: "tray").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let g = selected { GroupDetail(group: g, open: { detail = $0 }).id(g.id) }
                else { ContentUnavailableView("Choose a game", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .frame(width: 980, height: 660)
        .onAppear { store.load(); focus() }
        .onReceive(NotificationCenter.default.publisher(for: MyProfiles.changed)) { _ in mine = MyProfiles.all() }
        .onChange(of: tab) { mine = MyProfiles.all(); selectedMine = mine.first { (tab == "favorites") == ($0.favoriteOf != nil) }?.id }
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
                RatingBadge(rating: g.bestRating).help("The best rating among this game's profiles")
                Text("\(g.entries.count) profile\(g.entries.count == 1 ? "" : "s")")
                if let d = g.newest { Text(d.formatted(.relative(presentation: .named))) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 2)
    }

    /// From a favorite: show its profile in the Community list.
    func openInCatalog(_ number: Int) {
        guard let e = store.entries.first(where: { $0.number == number }) else {
            model.say("That profile isn't in the catalog anymore (its author may have removed it). Your saved copy stays.")
            return
        }
        tab = "community"
        query = ""
        selectedGroup = Profiles.groupKey(e.profile)
        detail = e
    }

    func reloadMine() {
        mine = MyProfiles.all()
        if !mine.contains(where: { $0.id == selectedMine }) { selectedMine = mine.first?.id }
    }

    /// Imported profiles go to My Profiles (checked first — settings only).
    func importFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        var last: MyProfile?
        for u in p.urls {
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            do { last = try MyProfiles.importText(text) } catch { model.fail(error) }
        }
        if let last { tab = "mine"; reloadMine(); selectedMine = last.id; model.say("Added to My Profiles.") }
    }
}

/// One of your own profiles: rename, share, export, delete — and apply it below.
struct MyProfileDetail: View {
    @EnvironmentObject var model: AppModel
    let item: MyProfile
    let changed: () -> Void
    var openInCatalog: (Int) -> Void = { _ in }
    @State private var name: String = ""
    @State private var sharing = false
    @State private var confirmDelete = false
    @State private var latest: CatalogEntry?
    @State private var showLatest = false
    @State private var inCatalog = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name", text: $name, onCommit: rename).textFieldStyle(.roundedBorder).font(.title3).frame(maxWidth: 360)
                    Spacer()
                    if item.favoriteOf == nil { Button(item.sharedAt == nil ? "Share with Everyone…" : "Share Again…") { sharing = true } }
                    Button("Export…", action: export)
                    Button("Delete…") { confirmDelete = true }
                }
                if let n = item.favoriteOf {
                    HStack {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text("Favorite — shared by \(item.favoriteAuthor ?? "someone"). Kept exactly as it was when you starred it.")
                        if latest != nil {
                            Picker("", selection: $showLatest) {
                                Text("My Saved Version").tag(false)
                                Text("Latest Version").tag(true)
                            }.pickerStyle(.segmented).frame(width: 260).labelsHidden()
                        }
                        Spacer()
                        Button("Open in Catalog") { openInCatalog(n) }.buttonStyle(.link)
                            .help("Shows this profile in the Community tab, with its current votes and comments")
                    }.font(.caption)
                    if let l = latest {
                        Text("Its author updated it since you starred it" + (l.updatedDate.map { " (\($0.formatted(.relative(presentation: .named))))" } ?? "") + ". Switch to Latest Version above to see or apply the new one — your saved version doesn't change.")
                            .font(.caption).foregroundStyle(.orange)
                    } else if inCatalog {
                        Label("Up to date — the shared profile hasn't changed since you starred it.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("No longer in the catalog — your saved copy is all that's left.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Saved \(item.created.formatted(date: .abbreviated, time: .shortened))"
                     + (item.updated.timeIntervalSince(item.created) > 60 ? " · changed \(item.updated.formatted(.relative(presentation: .named)))" : "")
                     + (item.sharedAt.map { " · shared \($0.formatted(date: .abbreviated, time: .omitted))" } ?? " · only on this Mac"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if showLatest, let l = latest {
                ProfileDetail(entry: l).id("latest")
            } else {
                ProfileDetail(entry: CatalogEntry(number: 0, url: Profiles.catalogPage, author: item.favoriteAuthor ?? "you", up: 0, down: 0, comments: 0,
                                                  updated: "", profile: item.profile)).id("saved")
            }
        }
        .onAppear {
            name = item.name
            // A newer version in the catalog than the one saved?
            if let n = item.favoriteOf {
                let e = Profiles.cached().first(where: { $0.number == n })
                inCatalog = e != nil
                if let e, e.profile != item.profile { latest = e }
            }
        }
        .sheet(isPresented: $sharing) {
            SubmitProfileSheet(profile: item.profile) { try? MyProfiles.markShared(item); changed() }.environmentObject(model)
        }
        .confirmationDialog("Delete “\(item.name)”?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                do { try MyProfiles.delete(item); changed() } catch { model.fail(error) }
            }
        } message: { Text(item.sharedAt == nil ? "It's only on this Mac." : "The shared copy on GitHub stays; close its issue to remove it.") }
    }

    func rename() {
        guard name != item.name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do { try MyProfiles.rename(item, to: name); changed() } catch { model.fail(error) }
    }

    func export() {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(CustomGames.safeFolderName(item.name)).nokcandu-profile.json"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Data(item.profile.json().utf8).write(to: u) } catch { model.fail(error) }
    }
}

/// Review rating and notes, then open the pre-filled GitHub submission.
struct SubmitProfileSheet: View {
    @Environment(\.dismiss) var dismiss
    @State var profile: GameProfile
    let onShared: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share “\(profile.title)” with Everyone").font(.title2.bold())
            Text("It's published in the Game Profiles catalog after an automatic safety check; people vote and comment on GitHub.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("How well does it run?", selection: $profile.rating) { ForEach(GameProfile.Rating.allCases) { Text($0.title).tag($0) } }
            Text("Notes").font(.caption)
            TextEditor(text: Binding(get: { profile.notes ?? "" }, set: { profile.notes = $0.isEmpty ? nil : $0 }))
                .frame(height: 80).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Submit on GitHub…") { NSWorkspace.shared.open(Profiles.submitURL(profile)); onShared(); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!profile.problems.isEmpty)
            }
        }
        .padding(20).frame(width: 520)
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
                    }.disclosureGroupStyle(WholeRowDisclosureStyle())
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProfileCard: View {
    let entry: CatalogEntry
    let open: (CatalogEntry) -> Void
    @State private var showComments = false
    @State private var expanded = false
    @State private var favorite = false
    @State private var liveVotes: (up: Int, down: Int)?
    var p: GameProfile { entry.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RatingBadge(rating: p.rating)
                Label("\(liveVotes?.up ?? entry.up)", systemImage: "hand.thumbsup")
                Label("\(liveVotes?.down ?? entry.down)", systemImage: "hand.thumbsdown")
                Label("\(entry.comments)", systemImage: "bubble.left")
                Spacer()
                Text(dates).foregroundStyle(.secondary)
                Button {
                    if favorite { MyProfiles.removeFavorite(of: entry.number) } else { _ = try? MyProfiles.addFavorite(entry) }
                    favorite = MyProfiles.favorite(of: entry.number) != nil
                } label: { Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? .yellow : .secondary) }
                .buttonStyle(.borderless)
                .help(favorite ? "Remove from favorites" : "Favorite: keeps this version in My Profiles, even if it changes later")
            }.font(.caption)
            if let n = p.notes, !n.isEmpty {
                Text(n).lineLimit(expanded ? nil : 4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if n.count > 220 || n.contains("\n") {
                    Button(expanded ? "Show Less" : "Show More") { withAnimation { expanded.toggle() } }.buttonStyle(.link).font(.caption)
                }
            }
            Text(ProfileText.summary(p)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let t = p.tested { Text("Tested on " + [t.mac, t.macOS, t.engine].compactMap { $0 }.joined(separator: " · ")) }
                if entry.testedOnOtherEngine { Label("different engine than today's", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("View & Apply…") { open(entry) }.buttonStyle(.borderedProminent)
                Button {
                    withAnimation { showComments.toggle() }
                } label: {
                    Label(showComments ? "Hide Comments" : "Comments (\(entry.comments))", systemImage: "bubble.left")
                }
                Button("Vote on GitHub") { NSWorkspace.shared.open(entry.url) }
                Spacer()
                Text("by \(entry.author)").font(.caption).foregroundStyle(.secondary)
            }
            if showComments { ProfileCommentsView(entry: entry) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .task {
            favorite = MyProfiles.favorite(of: entry.number) != nil
            // The catalog's vote counts lag; read the current ones from GitHub.
            liveVotes = await ProfileComments.votes(issue: entry.number)
        }
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
        for fix in CompatibilityFix.allCases where p.fixes?.contains(fix.id) == true { s.append(fix.title) }
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
                        Button("Vote on GitHub") { NSWorkspace.shared.open(entry.url) }
                    }.font(.callout).foregroundStyle(.secondary)
                    if entry.reportedBroken {
                        Label("Many people report this profile doesn't work. Read the comments first.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("Shared by \(entry.author)" + (entry.createdDate.map { " on \($0.formatted(date: .long, time: .omitted))" } ?? "") + (entry.updatedDate.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    ProfileCommentsView(entry: entry).id("comments-\(entry.number)")
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
                                if ["installer", "disc", "folder"].contains(p.source) { Button("Add a Game…") { model.showProfiles = false; model.showInstaller = true } }
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
                            ForEach(plan.componentFixes) { fix in Label("Installs \(fix.title)", systemImage: "wrench") }
                            ForEach(plan.skipped, id: \.self) { Label($0, systemImage: "minus.circle").foregroundStyle(.secondary) }
                            HStack {
                                Button(Profiles.matches(p, g) ? "Apply" : "Try It") { apply(g, plan) }.buttonStyle(.borderedProminent).disabled(working)
                                if let u = undoSnapshot {
                                    Button("Undo (\(u.gameName))") { undo(u) }.disabled(working)
                                }
                                if working { ProgressView().controlSize(.small) }
                            }
                            Text(undoSnapshot == nil
                                 ? "After you apply, an Undo button appears here that puts back the settings from before."
                                 : "Undo puts back the settings from before. Installed components have their own Undo in the game's Fixes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DisclosureGroup("Profile details") { Text(p.json()).font(.caption.monospaced()).textSelection(.enabled) }.disclosureGroupStyle(WholeRowDisclosureStyle())
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var chosen: InstalledGame? { choices.first { $0.id == (target ?? choices.first?.id) } }

    var notInstalledText: String {
        switch p.source {
        case "steam": "Install this game in Steam, add it from Steam → Steam Games, then come back here."
        case "battlenet": "Install it in Battle.net, add it from Battle.net → Blizzard Games, then come back here."
        default: "Install the game with Add a Game… (it uses \(p.match.exeName ?? "the game's program")), then come back here."
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
                for fix in plan.componentFixes { try await CompatibilityFixes.install(fix, for: g) { _ in } }
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
    @State private var mine: [MyProfile] = []
    @State private var sharing = false
    @State private var saving = false
    @State private var open: CatalogEntry?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if entries.isEmpty {
                    Text("No shared profiles for this game yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(entries.prefix(3)) { e in
                        HStack {
                            if mine.contains(where: { $0.favoriteOf == e.number }) {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).help("In your favorites")
                            }
                            RatingBadge(rating: e.profile.rating)
                            Text("👍 \(e.up)  👎 \(e.down)").font(.caption).foregroundStyle(.secondary)
                            Text(e.profile.notes?.components(separatedBy: .newlines).first ?? "").lineLimit(1).font(.caption)
                            Spacer()
                            Button("View") { model.profileFocus = e.number; model.showProfiles = true }
                        }
                    }
                }
                if !mine.isEmpty {
                    Divider()
                    Text("My profiles and favorites for this game").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(mine.sorted { ($0.favoriteOf != nil ? 0 : 1) < ($1.favoriteOf != nil ? 0 : 1) }) { m in
                        HStack {
                            if m.favoriteOf != nil {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).help("Your favorite (saved as it was when you starred it)")
                            } else {
                                Image(systemName: m.sharedAt == nil ? "tray" : "person.2").foregroundStyle(.secondary)
                                    .help(m.sharedAt == nil ? "Saved on this Mac" : "You shared it")
                            }
                            Text(m.name)
                            Text(m.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Apply…") {
                                open = CatalogEntry(number: 0, url: Profiles.catalogPage, author: "you", up: 0, down: 0, comments: 0, updated: "", profile: m.profile)
                            }
                        }
                    }
                }
                HStack {
                    Button("Browse All Profiles…") { model.profileFocus = nil; model.showProfiles = true }
                    Button("Save Setup as Profile…") { saving = true }
                    Button("Share This Setup…") { sharing = true }
                }
                Text("Saved profiles stay on this Mac; share any of them later from Game Profiles → My Profiles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Shared Profiles").font(.headline) }
        .task {
            entries = Profiles.forGame(game, in: Profiles.cached())
            let r = await Profiles.fetch()
            entries = Profiles.forGame(game, in: r.entries)
        }
        .onAppear { mine = MyProfiles.forGame(game) }
        .onReceive(NotificationCenter.default.publisher(for: MyProfiles.changed)) { _ in mine = MyProfiles.forGame(game) }
        .sheet(isPresented: $sharing, onDismiss: { mine = MyProfiles.forGame(game) }) { ShareProfileView(game: game).environmentObject(model) }
        .sheet(isPresented: $saving, onDismiss: { mine = MyProfiles.forGame(game) }) { ShareProfileView(game: game, saveOnly: true).environmentObject(model) }
        .sheet(item: $open) { e in
            VStack(spacing: 0) {
                ProfileDetail(entry: e)
                Divider()
                HStack { Spacer(); Button("Close") { open = nil }.keyboardShortcut(.cancelAction) }.padding(12)
            }.frame(width: 640, height: 560).environmentObject(model)
        }
    }
}

struct ShareProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let game: InstalledGame
    var saveOnly = false
    @State private var rating: GameProfile.Rating = .works
    @State private var name = ""
    @State private var notes = ""
    @State private var install = ""

    var profile: GameProfile { Profiles.make(from: game, rating: rating, notes: notes.isEmpty ? nil : notes, install: install.isEmpty ? nil : install) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(saveOnly ? "Save Setup as Profile" : "Share This Setup").font(.title2.bold())
            Text(saveOnly ? "Keeps \(game.name)'s current settings as a profile on this Mac only. Apply it again any time, to this or another game, and share it later if you want."
                          : "Publishes \(game.name)'s working settings so anyone can apply them. Only settings are shared — no files, accounts or personal details. It appears in Game Profiles after an automatic safety check; people vote and comment on GitHub.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if saveOnly {
                TextField("Name, e.g. \(game.name) — windowed", text: $name).textFieldStyle(.roundedBorder)
            }
            Picker("How well does it run?", selection: $rating) { ForEach(GameProfile.Rating.allCases) { Text($0.title).tag($0) } }
            Text("Notes (what works, known issues, tips)").font(.caption)
            TextEditor(text: $notes).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            Text("How to install (optional)").font(.caption)
            TextEditor(text: $install).frame(height: 50).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            DisclosureGroup("What will be shared") { Text(profile.json()).font(.caption.monospaced()).textSelection(.enabled) }.disclosureGroupStyle(WholeRowDisclosureStyle())
            let left = Profiles.notShared(from: game)
            if !left.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not shared:").font(.caption.bold())
                    ForEach(left, id: \.self) { Text("• " + $0).font(.caption) }
                }.foregroundStyle(.secondary)
            }
            ForEach(CompatibilityFix.allCases.filter { profile.fixes?.contains($0.id) == true }) { fix in
                Label("Includes \(fix.title) — Apply installs it for others.", systemImage: "wrench").font(.caption)
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
                if saveOnly {
                    Button("Save") { saveMine() }.buttonStyle(.borderedProminent).disabled(!profile.problems.isEmpty)
                } else {
                    Button("Save to My Profiles") { saveMine() }.disabled(!profile.problems.isEmpty)
                }
                if !saveOnly {
                    Button("Submit on GitHub…") {
                        if let item = try? MyProfiles.save(profile, name: name.isEmpty ? profile.title : name) { try? MyProfiles.markShared(item) }
                        NSWorkspace.shared.open(Profiles.submitURL(profile)); dismiss()
                    }
                    .buttonStyle(.borderedProminent).disabled(!profile.problems.isEmpty)
                }
            }
            Text(saveOnly ? "Saved profiles are in Game Profiles → My Profiles." : "GitHub opens with everything filled in — sign in and click Submit. A copy is kept in My Profiles.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 560)
        .onAppear { if notes.isEmpty { notes = Profiles.suggestedNotes(for: game) } }
    }

    func saveMine() {
        do {
            let item = try MyProfiles.save(profile, name: name.isEmpty ? "\(game.name) — \(Date().formatted(date: .abbreviated, time: .omitted))" : name)
            model.say("Saved “\(item.name)” to My Profiles.")
            dismiss()
        } catch { model.fail(error) }
    }

    func save() {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(CustomGames.safeFolderName(profile.title)).nokcandu-profile.json"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Data(profile.json().utf8).write(to: u) } catch { model.fail(error) }
    }
}

/// The profile's discussion from GitHub, read in place. Writing needs a GitHub account, so that opens GitHub.
struct ProfileCommentsView: View {
    static let howToVote = "To vote: press Vote on GitHub (a free GitHub account is needed). At the very top of that page is the profile itself, with its settings. Below it, click the smiley-face button (Add reaction) — not the one under a comment — and choose 👍 if the profile works for you or 👎 if it doesn't. Votes show here within the hour."
    let entry: CatalogEntry
    @State private var comments: [ProfileComment] = []
    @State private var votes: (up: Int, down: Int)?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let v = votes {
                    Text("Right now: 👍 \(v.up)  👎 \(v.down)  (the catalog updates hourly)").font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if !loading && error == nil && comments.isEmpty { Text("No comments yet.").font(.caption).foregroundStyle(.secondary) }
                ForEach(comments) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.author).font(.caption.bold())
                            if let d = c.created { Text(d.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text((try? AttributedString(markdown: c.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(c.body))
                            .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if c.id != comments.last?.id { Divider() }
                }
                Text(Self.howToVote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Write a Comment on GitHub…") {
                        NSWorkspace.shared.open(URL(string: entry.url.absoluteString + "#new_comment_field") ?? entry.url)
                    }
                    Button("Refresh") { Task { await load() } }.buttonStyle(.link)
                    Spacer()

                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Comments").font(.headline) }
        .task { await load() }
    }

    func load() async {
        loading = true; error = nil
        do { comments = try await ProfileComments.fetch(issue: entry.number) } catch { self.error = error.localizedDescription }
        votes = await ProfileComments.votes(issue: entry.number)
        loading = false
    }
}
