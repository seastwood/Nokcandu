import SwiftUI
import AppKit
import WebKit
import NokcanduCore

/// Every game store in one window: Steam, GOG, Epic, Amazon (sign in, see your games, install one as its
/// own Mac app) and the launcher-based ones — Battle.net, EA app, Ubisoft Connect.
enum StoreTab: String, CaseIterable, Identifiable {
    case steam, gog, epic, amazon, battlenet, ea, ubisoft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .steam: "Steam"; case .gog: "GOG"; case .epic: "Epic"; case .amazon: "Amazon"
        case .battlenet: "Battle.net"; case .ea: "EA"; case .ubisoft: "Ubisoft"
        }
    }
    var store: Store? { switch self { case .gog: .gog; case .epic: .epic; case .amazon: .amazon; default: nil } }
}

struct StoreLibraryView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("storeTab") private var tab: StoreTab = .steam
    var store: Store { tab.store ?? .gog }
    @State private var signedIn: [Store: Bool] = [:]
    @State private var games: [Store: [StoreGame]] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var login: LoginRequest?
    @State private var folder: URL = GameFolders.installFolder
    /// The game whose Install was pressed: its row asks where to put it.
    @State private var choosing: String?
    /// Install sizes, looked up when a game's install options open (nil entry = store doesn't report it).
    @State private var sizes: [String: StoreAccounts.InstallSize?] = [:]

    struct LoginRequest: Identifiable { let id = UUID(); let store: Store; let url: URL; let amazon: [String: String] }

    var installedIDs: Set<String> {
        Set(app.games.compactMap { g in g.custom?.store.flatMap { $0.store == store ? $0.id : nil } })
    }
    var installedMacIDs: Set<String> {
        Set(NativeGames.all().compactMap { n in n.store.flatMap { $0.store == store ? $0.id : nil } })
    }
    @State private var wantMac = true
    /// Mac versions downloading right now: game id → latest status line.
    @State private var macProgress: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Game Stores").font(.title2.bold())
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(StoreTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 520)
                Spacer()
                Button("Done") { app.refresh(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            switch tab {
            case .steam: SteamLibraryView(embedded: true)
            case .battlenet: LauncherStoreTab(kind: nil)
            case .ea: LauncherStoreTab(kind: .ea)
            case .ubisoft: LauncherStoreTab(kind: .ubisoft)
            default:
                content
                Divider()
                HStack(alignment: .top) {
                    Button("Browse \(store.title) Store") { NSWorkspace.shared.open(storeLauncher.storeURL) }
                    OptionalLauncherButton(kind: storeLauncher)
                    Spacer()
                    Text("Uses the open-source \(toolName) client (downloaded on first use). Your password goes only to \(store.title)'s own sign-in page.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 300, alignment: .trailing)
                }
                .padding(12)
            }
        }
        .frame(width: 900, height: 680)
        .onAppear(perform: refreshState)
        .onChange(of: tab) { error = nil; search = ""; choosing = nil; refreshState() }
        .sheet(item: $login) { req in
            StoreLoginSheet(request: req) { code in
                login = nil
                guard let code else { return }
                Task { await finishLogin(req, code: code) }
            }
        }
    }

    var storeLauncher: PCLauncher { switch store { case .gog: .gogGalaxy; case .epic: .epicLauncher; case .amazon: .amazonGames } }

    var toolName: String { switch store { case .gog: "gogdl"; case .epic: "Legendary"; case .amazon: "nile" } }

    @ViewBuilder var content: some View {
        if signedIn[store] != true {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: store.symbol).font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Sign in to \(store.title)").font(.title3.bold())
                Text(blurb).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
                if let error { Text(error).foregroundStyle(.red).font(.caption).frame(maxWidth: 480) }
                Button(loading ? "Starting…" : "Sign In…") { Task { await startLogin() } }
                    .controlSize(.large).disabled(loading)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search your \(store.title) games", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Refresh") { Task { await loadLibrary() } }.disabled(loading)
                    Button("Sign Out") { Task { await StoreAccounts.signOut(store); ListCache.remove("store-\(store.rawValue)"); games[store] = nil; refreshState() } }
                }
                .padding(10)
                if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
                if !loading && (games[store] ?? []).isEmpty {
                    ContentUnavailableView("No games yet", systemImage: "bag", description: Text("Press Refresh to load your \(store.title) library."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { g in
                                row(g).padding(.horizontal, 14).padding(.vertical, 5)
                                Divider().padding(.leading, 58)
                            }
                        }
                    }
                }
            }
        }
    }

    var blurb: String {
        switch store {
        case .gog: "GOG games have no copy protection, so they run well here. Nokcandu downloads each game's Windows files straight into its own Mac app."
        case .epic: "Epic games download without the Epic Games Launcher (which runs poorly in Wine). Games that need Epic's sign-in get it automatically when they start. Games with strong anti-cheat (like Fortnite) won't run."
        case .amazon: "Amazon Games (Prime Gaming) titles download and start without the Amazon Games app."
        }
    }

    var filtered: [StoreGame] {
        let all = games[store] ?? []
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    func row(_ g: StoreGame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
            AsyncImage(url: g.image) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: 34, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(g.title)
                if !g.windows { Text("No Windows version").font(.caption).foregroundStyle(.secondary) }
                if let w = AntiCheat.warning(epicNamespace: g.namespace, name: g.title) {
                    Label(w.short, systemImage: w.verdict == .blocked ? "xmark.shield" : "exclamationmark.shield")
                        .font(.caption).foregroundStyle(w.verdict == .blocked ? .red : .orange).help(w.detail)
                }
                if let p = macProgress[g.id] {
                    Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if installedMacIDs.contains(g.id) {
                    Text("Mac version installed").font(.caption).foregroundStyle(.green)
                } else if g.mac {
                    Label("Mac version available", systemImage: "apple.logo").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if macProgress[g.id] != nil {
                ProgressView().controlSize(.small)
            } else if installedIDs.contains(g.id) || installedMacIDs.contains(g.id) {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
            } else if choosing != g.id {
                Button("Install…") { choosing = g.id; wantMac = g.mac; lookUpSize(g) }.disabled(!g.windows && !g.mac)
            }
        }
        if choosing == g.id {
            VStack(alignment: .leading, spacing: 6) {
                if g.mac && g.windows {
                    Picker("Version", selection: $wantMac) {
                        Text("Mac (runs natively — usually best)").tag(true)
                        Text("Windows (through Wine)").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                }
                HStack(alignment: .top) {
                    let mac = g.mac && (wantMac || !g.windows)
                    let key = sizeKey(g, mac: mac)
                    let tooBig: Bool = {
                        guard let sz = sizes[key] ?? nil, let free = GameFolders.freeSpace(folder) else { return false }
                        return free < sz.disk + (1 << 30)
                    }()
                    VStack(alignment: .leading, spacing: 4) {
                        InstallFolderPicker(folder: $folder, macApp: mac).frame(maxWidth: 440)
                        Group {
                            if let entry = sizes[key] {
                                if let sz = entry {
                                    Text("Needs \(Storage.format(sz.disk)) (\(Storage.format(sz.download)) download)")
                                    if tooBig {
                                        Text("Not enough space on \(GameFolders.volumeName(folder)) — \(Storage.format(GameFolders.freeSpace(folder) ?? 0)) free. Pick another drive or free up space.")
                                            .foregroundStyle(.red)
                                    }
                                } else { Text("\(g.store.title) doesn't report this game's size — make sure there's enough room.") }
                            } else { HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Checking size…") } }
                        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Cancel") { choosing = nil }
                    Button("Install") { mac ? installMac(g) : install(g) }.buttonStyle(.borderedProminent)
                        .disabled((mac && !GameFolders.holdsApps(folder)) || tooBig)
                }
            }
            .padding(.leading, 44)
        }
        }
    }

    func refreshState() {
        for s in Store.allCases { signedIn[s] = StoreAccounts.isSignedIn(s) }
        guard tab.store != nil, signedIn[store] == true, games[store] == nil else { return }
        // Show the saved library right away; fetch a fresh one in the background when it's over an hour old.
        if let c = ListCache.load("store-\(store.rawValue)", as: [StoreGame].self) {
            games[store] = c.value
            if Date().timeIntervalSince(c.saved) > 3600 { Task { await loadLibrary() } }
        } else { Task { await loadLibrary() } }
    }

    func startLogin() async {
        error = nil; loading = true
        defer { loading = false }
        do {
            try await StoreTools.ensure(store)
            switch store {
            case .gog: login = LoginRequest(store: .gog, url: StoreAccounts.gogLoginURL(), amazon: [:])
            case .epic: login = LoginRequest(store: .epic, url: StoreAccounts.epicLoginURL, amazon: [:])
            case .amazon:
                let (u, finish) = try await StoreAccounts.amazonLogin()
                login = LoginRequest(store: .amazon, url: u, amazon: finish)
            }
        } catch { self.error = error.localizedDescription }
    }

    func finishLogin(_ req: LoginRequest, code: String) async {
        loading = true
        defer { loading = false }
        do {
            try await StoreAccounts.finishSignIn(req.store, code: code, amazon: req.amazon)
            refreshState()
            app.say("Signed in to \(req.store.title).")
        } catch { self.error = error.localizedDescription }
    }

    func loadLibrary() async {
        let s = store
        loading = true; error = nil
        defer { loading = false }
        do {
            let list = try await StoreAccounts.library(s).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            games[s] = list
            ListCache.save(list, "store-\(s.rawValue)")
        }
        catch { self.error = error.localizedDescription }
    }

    /// Mac versions download straight into a folder (no Wine); then they appear in the library.
    func sizeKey(_ g: StoreGame, mac: Bool) -> String { "\(g.store.rawValue)-\(g.id)-\(mac)" }

    func lookUpSize(_ g: StoreGame) {
        for mac in Set([g.mac, false].filter { $0 == false ? g.windows : true }) where sizes[sizeKey(g, mac: mac)] == nil {
            Task {
                let s = await StoreAccounts.installSize(g.store, id: g.id, mac: mac)
                sizes[sizeKey(g, mac: mac)] = .some(s)
            }
        }
    }

    func installMac(_ g: StoreGame) {
        choosing = nil
        // Mac apps need a Mac-formatted drive (ExFAT can't hold app bundles). Never switch drives silently.
        guard GameFolders.holdsApps(folder) else {
            error = "\(GameFolders.volumeName(folder)) can't hold Mac apps. Pick this Mac or a Mac-formatted drive, or install the Windows version there."
            return
        }
        let target = folder
        macProgress[g.id] = "Starting download…"
        Task {
            do {
                let n = try await NativeGames.installFromStore(g, into: target) { line in
                    Task { @MainActor in macProgress[g.id] = line.trimmingCharacters(in: .whitespaces) }
                }
                macProgress[g.id] = nil
                app.refresh()
                app.say("\(n.name) (Mac version) is ready to play.")
            } catch {
                macProgress[g.id] = nil
                self.error = error.localizedDescription
            }
        }
    }

    func install(_ g: StoreGame) {
        app.pendingStoreInstall = (g.title, ["store.kind": g.store.rawValue, "store.id": g.id], folder)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showInstaller = true }
    }
}

/// The store's own sign-in page, in a small browser window. Watches for the page it ends on and hands back the code.
struct StoreLoginSheet: View {
    let request: StoreLibraryView.LoginRequest
    let done: (String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text(request.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
            }
            .padding(8)
            Divider()
            LoginWebView(request: request, done: done)
        }
        .frame(width: 520, height: 700)
    }
}

struct LoginWebView: NSViewRepresentable {
    let request: StoreLibraryView.LoginRequest
    let done: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()      // nothing from this sign-in stays in a browser profile
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator
        w.uiDelegate = context.coordinator
        // Sign in with Google/Apple/etc. refuses unknown embedded browsers; present as Safari.
        w.customUserAgent = LoginWebView.safariUA
        w.load(URLRequest(url: request.url))
        return w
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: LoginWebView
        var finished = false
        var popups: [NSWindow] = []
        init(_ p: LoginWebView) { parent = p }

        /// "Sign in with Google / Steam / Discord / Xbox" opens a pop-up window; show it as a real window
        /// (sharing the sign-in session) and close it when the provider is done.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
            popup.customUserAgent = LoginWebView.safariUA
            popup.navigationDelegate = self
            popup.uiDelegate = self
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            win.title = action.request.url?.host ?? "Sign in"
            win.contentView = popup
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.center()
            win.makeKeyAndOrderFront(nil)
            popups.append(win)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            for w in popups where w.contentView === webView { w.close() }
            popups.removeAll { $0.contentView === webView }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let u = action.request.url, let code = StoreAccounts.code(from: u, store: parent.request.store) {
                finish(code); decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let u = webView.url, let code = StoreAccounts.code(from: u, store: parent.request.store) { finish(code); return }
            guard parent.request.store == .epic, webView.url?.path.contains("/id/api/redirect") == true else { return }
            webView.evaluateJavaScript("document.body.innerText") { r, _ in
                if let t = r as? String, let code = StoreAccounts.epicCode(fromPageText: t) { self.finish(code) }
            }
        }

        func finish(_ code: String) {
            guard !finished else { return }
            finished = true
            for w in popups { w.close() }
            popups.removeAll()
            DispatchQueue.main.async { self.parent.done(code) }
        }
    }
}

/// "Set up the official launcher (optional)" for GOG Galaxy / Epic Games Launcher / Amazon Games.
struct OptionalLauncherButton: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    let kind: PCLauncher
    var body: some View {
        if let host = app.games.first(where: { PCLaunchers.kind(of: $0) == kind }) {
            Button("Open \(kind.title)") { app.play(host) }
        } else {
            Button("Set Up \(kind.title) (optional)…") { app.setUpLauncher(kind: kind); dismiss() }
                .help("Not needed to install or play — only for \(kind.title)'s own store, friends and community features. Store launchers run in Wine with mixed results.")
        }
    }
}

/// Battle.net (kind nil), EA app and Ubisoft Connect: their games need the launcher, so this tab sets it
/// up, opens it (to browse, buy and install), and turns installed games into Mac apps.
struct LauncherStoreTab: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    let kind: PCLauncher?

    var title: String { kind?.title ?? "Battle.net" }
    var host: InstalledGame? { app.games.first { kind == nil ? BattleNet.isHost($0) : PCLaunchers.kind(of: $0) == kind } }
    var storeURL: URL { kind?.storeURL ?? URL(string: "https://shop.battle.net")! }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let host {
                    HStack {
                        Image(nsImage: host.icon).resizable().frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(title).font(.title3.bold())
                            Text("Browse, buy and install games in \(title); then add them here so each gets its own Mac app.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open \(title)") { app.play(host) }.buttonStyle(.borderedProminent)
                        Button("Browse Store") { NSWorkspace.shared.open(storeURL) }
                    }
                    if let kind { LauncherGamesSection(host: host, kind: kind) } else { BlizzardGamesSection(host: host) }
                    LauncherDriveBox(host: host, name: title)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.app").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("\(title) isn't set up yet").font(.title3.bold())
                        Text(kind == nil
                             ? "Blizzard games install and run through Battle.net. Nokcandu downloads Blizzard's installer and sets it up; each game you install in it then gets its own Mac app."
                             : "\(title) games need \(title) running. Nokcandu downloads the official installer and sets it up; each game you install in it then gets its own Mac app. \(kind == .ea ? "The EA app runs in Wine with mixed results." : "Games with anti-cheat may not run.")")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 520)
                        HStack {
                            Button("Set Up \(title)…") { app.setUpLauncher(kind: kind); dismiss() }.buttonStyle(.borderedProminent)
                            Button("Browse Store") { NSWorkspace.shared.open(storeURL) }
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(20)
        }
    }
}
