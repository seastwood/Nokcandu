import SwiftUI
import AppKit
import NokcanduCore

@MainActor
final class SteamLibraryModel: ObservableObject {
    @Published var games: [SharedSteam.LibraryGame] = []
    @Published var account: SharedSteam.Account?
    @Published var loadingOwned = false
    @Published var ownedLoaded = false
    @Published var message: String?
    /// Installs requested in Steam (with when), until Steam's install record shows them — or is gone (cancelled).
    @Published var waiting: [Int: Date] = [:]
    @Published var collections: [SharedSteam.Collection] = []
    private var owned: [SharedSteam.LibraryGame] = []
    private var names: [Int: String] = [:]
    private var poll: Task<Void, Never>?

    var hasKey: Bool { SharedSteam.apiKey != nil }

    /// Local Steam state read off the main thread. Collections and recently-seen apps come from large files
    /// (localconfig.vdf can be megabytes), so the 5-second poll only re-reads what's installed.
    private var collectionIDs: [Int] = []
    private var recent: [Int] = []
    private var loadedCache = false

    func refresh(full: Bool = true) {
        if !loadedCache {
            loadedCache = true
            if let c = ListCache.load("steam-owned", as: [SharedSteam.LibraryGame].self) { owned = c.value; ownedLoaded = !owned.isEmpty }
            if let n = ListCache.load("steam-names", as: [Int: String].self) { names.merge(n.value) { a, _ in a } }
        }
        Task {
            let (acct, installed, cols, rec) = await Task.detached(priority: .userInitiated) { () -> (SharedSteam.Account?, [SharedSteam.LibraryGame], [SharedSteam.Collection]?, [Int]?) in
                (SharedSteam.accounts().first, SharedSteam.installedGames(), full ? SharedSteam.collections() : nil, full ? SharedSteam.recentGames() : nil)
            }.value
            account = acct
            if let cols { collections = cols; collectionIDs = cols.filter { $0.id != "hidden" }.flatMap(\.appIDs) }
            if let rec { recent = rec }
            merge(installed)
        }
    }

    private func merge(_ installed: [SharedSteam.LibraryGame]) {
        var byID: [Int: SharedSteam.LibraryGame] = [:]
        for g in owned { byID[g.appID] = g }
        for g in installed {
            var merged = g
            if let o = byID[g.appID] { merged.playtimeMinutes = o.playtimeMinutes; merged.iconURL = o.iconURL }
            byID[g.appID] = merged
        }
        for id in recent + collectionIDs where byID[id] == nil && id != 228980 && id != 7 {
            byID[id] = SharedSteam.LibraryGame(appID: id, name: names[id] ?? "Steam app \(id)", installed: false, installDir: nil,
                                               sizeOnDisk: nil, playtimeMinutes: nil, iconURL: nil, owned: true)
        }
        let manifests = Set(installed.map(\.appID))
        for (id, since) in waiting {
            // Done, or Steam has its own record now (its flags tell the rest), or no record after a minute: cancelled.
            if byID[id]?.installed == true || manifests.contains(id) || Date().timeIntervalSince(since) > 60 { waiting[id] = nil }
        }
        let sorted = byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sorted != games { games = sorted }
        fillMissingNames()
    }

    /// Recently-seen apps have no names locally; look them up in the public store (a few at a time).
    private func fillMissingNames() {
        let missing = games.filter { $0.name.hasPrefix("Steam app ") && names[$0.appID] == nil }.prefix(20)
        for g in missing {
            names[g.appID] = g.name
            Task {
                if let info = await SharedSteam.storeInfo(g.appID), let n = info.name {
                    names[g.appID] = n
                    ListCache.save(names.filter { !$0.value.hasPrefix("Steam app ") }, "steam-names")
                    if let i = games.firstIndex(where: { $0.appID == g.appID }) { games[i].name = n }
                }
            }
        }
    }

    func loadOwned() {
        guard let key = SharedSteam.apiKey, let acct = account ?? SharedSteam.accounts().first else {
            message = "Sign in to Steam and add your Web API key to see every game you own."
            return
        }
        loadingOwned = true
        Task {
            defer { loadingOwned = false }
            do {
                owned = try await SharedSteam.ownedGames(apiKey: key, steamID64: acct.steamID64)
                ListCache.save(owned, "steam-owned")
                ownedLoaded = true
                message = nil
                refresh()
            } catch { message = error.localizedDescription }
        }
    }

    func startPolling() {
        poll?.cancel()
        poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                refresh(full: false)
            }
        }
    }
    func stopPolling() { poll?.cancel() }
}

struct SteamLibraryView: View {
    @EnvironmentObject var app: AppModel
    /// Shown as a tab in Game Stores (no title or Done button).
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = SteamLibraryModel()
    @State private var search = ""
    @State private var filter = "all"                  // all, installed, added, or a collection id
    @State private var keyInput = ""
    @State private var showKey = false
    @State private var macWarning: SharedSteam.LibraryGame?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if !embedded { Text("Steam Library").font(.title2.bold()) }
                    if let a = m.account { Text("Signed in as \(a.personaName.isEmpty ? a.accountName : a.personaName)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if SharedSteam.isSetUp {
                    Button { try? SharedSteam.openSteam() } label: { Label("Open Steam", systemImage: "arrow.up.forward.app") }
                    Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .padding()
            Divider()
            if !SharedSteam.isSetUp { setup } else { library }
            Divider()
            HStack {
                Text("Windows Steam games install into one shared Steam; each game you add gets its own Mac app.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Browse Steam Store") { NSWorkspace.shared.open(URL(string: "https://store.steampowered.com")!) }
                if !embedded { Button("Done") { app.refresh(); dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .padding()
        }
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 600)
        .onAppear { m.refresh(); m.startPolling(); if m.hasKey { m.loadOwned() } }
        .onDisappear { m.stopPolling() }
        .alert("\(macWarning?.name ?? "This game") has a Mac version",
               isPresented: Binding(get: { macWarning != nil }, set: { if !$0 { macWarning = nil } })) {
            Button("Use Windows Version Anyway") { if let g = macWarning { proceed(g, checkedMac: true) }; macWarning = nil }
            Button("Cancel", role: .cancel) { macWarning = nil }
        } message: {
            Text("The regular Mac Steam app may run it natively, which is usually faster and simpler. Older Mac versions can be 32-bit and no longer run, though — in that case the Windows version is the way to go.")
        }
    }

    // MARK: Not set up

    var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Steam isn't set up yet", systemImage: "cloud").font(.headline)
            Text("Nokcandu installs one Windows Steam in its own app (Steam.app). You sign in once — Steam Guard happens in Steam's own window — and every Steam game you add uses it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("You'll need SteamSetup.exe from Steam's website and about 1.5 GB of free space, plus room for your games.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Get SteamSetup.exe") { NSWorkspace.shared.open(CustomGames.steamSetupPage) }
                Button("Set Up Steam…") {
                    app.installerStartsSteamHost = true
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showInstaller = true }
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Library

    var selectedCollection: SharedSteam.Collection? { m.collections.first { $0.id == filter } }

    var filtered: [SharedSteam.LibraryGame] {
        let hidden = Set(m.collections.first { $0.id == "hidden" }?.appIDs ?? [])
        let members = selectedCollection.map { Set($0.appIDs) }
        return m.games.filter { g in
            guard search.isEmpty || g.name.localizedCaseInsensitiveContains(search) else { return false }
            if let members { return members.contains(g.appID) }
            if hidden.contains(g.appID) { return false }
            switch filter {
            case "installed": return g.installed
            case "added": return SharedSteam.addedApp(appID: g.appID, in: app.games) != nil
            default: return true
            }
        }
    }

    var library: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Picker("Show", selection: $filter) {
                    Text("All Games").tag("all")
                    Text("Installed").tag("installed")
                    Text("In Nokcandu").tag("added")
                    if !m.collections.isEmpty {
                        Divider()
                        ForEach(m.collections) { c in
                            Text(c.name + (c.dynamic ? " (dynamic)" : "")).tag(c.id)
                        }
                    }
                }
                .frame(width: 220)
                Spacer()
                if m.loadingOwned { ProgressView().controlSize(.small) }
                Button(m.ownedLoaded ? "All Owned Games ✓" : "Show All Owned Games…") { showKey.toggle() }
                    .popover(isPresented: $showKey) { keyPopover }
            }
            .padding(.horizontal).padding(.vertical, 8)
            if let c = selectedCollection, c.dynamic {
                Text("“\(c.name)” is a dynamic collection. Steam decides its games from filters, which Nokcandu can't read yet.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
            } else if let c = selectedCollection, c.appIDs.isEmpty {
                Text("“\(c.name)” is empty in this Steam's copy. Collections sync from your Steam account; if you just changed it elsewhere, give Steam a minute and press refresh.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let msg = m.message {
                Text(msg).font(.caption).foregroundStyle(.orange).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
            }
            List(filtered) { g in row(g) }
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView(m.games.isEmpty ? "No games yet" : "No matches", systemImage: "gamecontroller",
                                               description: Text(m.games.isEmpty
                                                    ? "Install games in Steam, or tap Show All Owned Games to browse everything on your account."
                                                    : "Try a different search or filter."))
                    }
                }
        }
    }

    var keyPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See every game you own").font(.headline)
            Text("Steam only shares your full list with your own Web API key. Get one from Steam (sign in, any domain name such as \"localhost\"), then paste it here. It's stored in your Mac's Keychain and only sent to Steam.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Get a Web API Key") { NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/dev/apikey")!) }
                .buttonStyle(.link)
            SecureField(m.hasKey ? "Key saved — paste to replace" : "Web API key", text: $keyInput)
            HStack {
                if m.hasKey { Button("Forget Key", role: .destructive) { SharedSteam.apiKey = nil; m.ownedLoaded = false; keyInput = "" } }
                Spacer()
                Button("Load My Games") {
                    if !keyInput.isEmpty { SharedSteam.apiKey = keyInput; keyInput = "" }
                    showKey = false
                    m.loadOwned()
                }
                .disabled(keyInput.isEmpty && !m.hasKey)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }

    @ViewBuilder
    func row(_ g: SharedSteam.LibraryGame) -> some View {
        let added = SharedSteam.addedApp(appID: g.appID, in: app.games)
        HStack(spacing: 12) {
            AsyncImage(url: SharedSteam.headerImage(g.appID)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary))
            }
            .frame(width: 120, height: 45).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if added != nil { badge("In Nokcandu", .green) }
                    switch g.download {
                    case .downloading: badge(g.installed ? "Updating in Steam…" : "Downloading in Steam…", .orange)
                    case .paused: badge("Paused in Steam", .gray)
                    case .queued: badge("Queued in Steam", .gray)
                    case nil:
                        if g.installed { badge("Installed", .blue) }
                        else if m.waiting[g.appID] != nil { badge("Starting in Steam…", .orange) }
                    }
                    if let min = g.playtimeMinutes, min > 0 { Text("\(min / 60) h played").font(.caption).foregroundStyle(.secondary) }
                    if let s = g.sizeOnDisk, s > 0 { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    if let w = AntiCheat.warning(steamAppID: g.appID, name: g.name) {
                        Label(w.short, systemImage: w.verdict == .blocked ? "xmark.shield" : "exclamationmark.shield")
                            .font(.caption).foregroundStyle(w.verdict == .blocked ? .red : .orange).help(w.detail).lineLimit(1)
                    }
                }
            }
            Spacer()
            if let added {
                Button("Play") { app.play(added) }
                Button("Show") { app.selection = added.id; dismiss() }.buttonStyle(.link)
            } else if g.installed {
                Button("Add to Nokcandu") { proceed(g, checkedMac: false) }.buttonStyle(.borderedProminent)
            } else {
                Button(m.waiting[g.appID] != nil || g.download != nil ? "Open in Steam" : "Install in Steam") { proceed(g, checkedMac: false) }
            }
        }
        .padding(.vertical, 2)
    }

    func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.18), in: Capsule()).foregroundStyle(c)
    }

    /// Add an installed game, or ask Steam to install it. Checks for a native Mac version first.
    func proceed(_ g: SharedSteam.LibraryGame, checkedMac: Bool) {
        Task {
            if !checkedMac, let info = await SharedSteam.storeInfo(g.appID), info.mac {
                macWarning = g
                return
            }
            do {
                if g.installed {
                    let url = try SharedSteam.addGame(g)
                    app.refresh()
                    app.say("\(g.name) added. Open it from Nokcandu or \(url.deletingLastPathComponent().lastPathComponent).")
                } else {
                    try SharedSteam.install(appID: g.appID)
                    m.waiting[g.appID] = Date()
                    app.say("Steam is opening the install for \(g.name). When it finishes, press Add to Nokcandu here.")
                }
                m.refresh()
            } catch { app.fail(error) }
        }
    }
}
