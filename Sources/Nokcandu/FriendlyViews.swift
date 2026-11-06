import SwiftUI
import AppKit
import NokcanduCore

// MARK: - Recent activity

/// Toolbar bell: the last messages Nokcandu showed, so ones that faded can still be read.
struct ActivityButton: View {
    @EnvironmentObject var model: AppModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle(); model.unseenErrors = 0 } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if model.unseenErrors > 0 { Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                }
        }
        .accessibilityLabel(model.unseenErrors > 0 ? "Recent activity, \(model.unseenErrors) problem\(model.unseenErrors == 1 ? "" : "s")" : "Recent activity")
        .help(model.unseenErrors > 0 ? "Recent activity — \(model.unseenErrors) problem\(model.unseenErrors == 1 ? "" : "s")" : "Recent activity")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Activity").font(.headline)
                    Spacer()
                    if !model.activity.isEmpty { Button("Clear") { model.activity.removeAll() }.buttonStyle(.link) }
                }
                .padding(12)
                Divider()
                if model.activity.isEmpty {
                    Text("Nothing yet. Messages about starting, quitting, moving and fixing games appear here.")
                        .font(.callout).foregroundStyle(.secondary).padding(12).frame(width: 360, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.activity) { a in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: a.isError ? "exclamationmark.triangle.fill" : "info.circle")
                                        .foregroundStyle(a.isError ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                        Text(a.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if let id = a.game, model.games.contains(where: { $0.id == id }) {
                                        Button("Show") { model.selection = id; shown = false }.buttonStyle(.link).font(.callout)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 380, height: min(420, CGFloat(model.activity.count) * 64 + 24))
                }
            }
        }
    }
}

// MARK: - Keyboard commands

/// Game menu: Play/Quit the selected game and jump between its tabs.
struct GameCommands: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let game = model.selectedGame
        let running = game.map(model.isRunning) ?? false
        Button(running && game?.isSteamHost != true ? "Quit \(game?.name ?? "Game")" : "Play \(game?.name ?? "")") {
            guard let g = game else { return }
            if running && !g.isSteamHost { model.requestQuit(g) } else { model.play(g) }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(game == nil)
        Divider()
        ForEach(Array(GameDetailView.Tab.allCases.enumerated()), id: \.element) { i, tab in
            Button(tab.title) { UserDefaults.standard.set(tab.rawValue, forKey: "gameSettingsTab") }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .disabled(game == nil || game?.native != nil)
        }
        Divider()
        Button("Search Games") { model.focusSearch = true }
            .keyboardShortcut("f", modifiers: .command)
    }
}

/// Puts the cursor in the sidebar's search field when asked (⌘F). macOS 15 and later.
struct SearchFocusModifier: ViewModifier {
    @Binding var request: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { Focused(content: content, request: $request) } else { content }
    }
    @available(macOS 15.0, *)
    struct Focused<C: View>: View {
        let content: C
        @Binding var request: Bool
        @FocusState private var focused: Bool
        var body: some View {
            content.searchFocused($focused)
                .onChange(of: request) { if request { focused = true; request = false } }
        }
    }
}

// MARK: - What Play is doing

struct LaunchProgressLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}

// MARK: - Needs attention

/// One thing on a game's page that needs attention (a crash, a missing mod, a graphics problem…).
struct AttentionItem: Identifiable {
    let id: String
    let view: AnyView
}

/// The page's notices in one place: the most important one shown, the others one click away.
struct AttentionArea: View {
    let items: [AttentionItem]
    @State private var expanded = false

    var body: some View {
        if let first = items.first {
            VStack(alignment: .leading, spacing: 8) {
                first.view
                if items.count > 1 {
                    if expanded {
                        ForEach(items.dropFirst()) { $0.view }
                    }
                    Button(expanded ? "Show Less" : "\(items.count - 1) more notice\(items.count == 2 ? "" : "s")…") {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .buttonStyle(.link).font(.callout)
                }
            }
        }
    }
}

/// A notice card in the attention area.
struct NoticeCard<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var evidence: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.bold()).accessibilityAddTraits(.isHeader)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let evidence {
                    Text(evidence).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer()
            VStack(alignment: .trailing) { actions() }
        }
        .padding(12)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Overview summary

/// The game's setup at a glance, at the top of Overview.
struct GameSummarySection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    let lastCrash: CrashReports.Explanation?
    let showDiagnostics: () -> Void

    struct Facts: Equatable {
        var graphics: String?
        var engine: String?
        var storage: String = ""
        var lastPlayed: Date?
        var rawMouse: Bool?
        var memoryPeak: UInt64?
    }
    @State private var facts = Facts()

    var body: some View {
        SettingsSection(title: "At a Glance", info: "How this game is set up right now. Change any of it in the tabs below.") {
            if let g = facts.graphics { fact("Graphics", g, tab: .display) }
            if let e = facts.engine { fact("Engine", e, tab: .compatibility) }
            fact("Stored on", facts.storage, tab: .storage)
            if let m = facts.rawMouse { fact("Raw mouse", m ? "On" : "Off", tab: .controls) }
            SettingRow(title: "Last played") {
                Text(facts.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet").foregroundStyle(.secondary)
            }
            if let peak = facts.memoryPeak {
                SettingRow(title: "Memory") {
                    Text("Up to \(MemoryWatch.gigabytes(peak)) last time").foregroundStyle(.secondary)
                        .help("The most memory the game's program used in its last session, of this Mac's \(MemoryWatch.gigabytes(MemoryWatch.physicalMemory)).")
                }
            }
            SettingRow(title: "Last run") {
                if let c = lastCrash {
                    Label("Crashed \(c.date.formatted(.relative(presentation: .named)))", systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                } else {
                    Text("No crash recorded").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Diagnostics…", action: showDiagnostics)
                Button("Show in Finder") { model.reveal(game.appURL.resolvingSymlinksInPath()) }
                if game.native == nil, !model.isRunning(game) { Button("Move…") { model.movingGame = game } }
            }
            .padding(.top, 2)
        }
        .task(id: "\(game.id)-\(model.libraryRevision)") {
            let g = game
            facts = await Task.detached(priority: .utility) { Self.load(g) }.value
        }
    }

    func fact(_ title: String, _ value: String, tab: GameDetailView.Tab) -> some View {
        SettingRow(title: title) {
            Button { UserDefaults.standard.set(tab.rawValue, forKey: "gameSettingsTab") } label: {
                HStack(spacing: 4) {
                    Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Change in \(tab.title)")
            .accessibilityLabel("\(title): \(value)")
            .accessibilityHint("Opens \(tab.title)")
        }
    }

    nonisolated static func load(_ g: InstalledGame) -> Facts {
        var f = Facts()
        if g.battleNet != nil { f.graphics = BattleNetGraphics.choice(g)?.title ?? "Same as Battle.net" }
        else if g.hosted != nil { f.graphics = HostedSettings.graphics(g).title }
        else if let c = g.custom { f.graphics = c.graphics.title }
        else if g.recipe != nil { f.graphics = "Tested setup" }
        if g.native == nil, let v = g.wineVersion { f.engine = EngineVersion(versionString: v)?.description ?? v }
        let app = g.appURL.resolvingSymlinksInPath()
        f.storage = Storage.driveName(app)
        if let files = GameMover.externalFiles(g) {
            let real = files.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: g.support.appendingPathComponent("referenced-game-folder.txt").path) {
                f.storage += " · uses “\(real.lastPathComponent)” where it is, on \(Storage.driveName(real))"
            } else {
                f.storage += " · game files on \(Storage.driveName(real))"
            }
        }
        f.lastPlayed = LibraryOrganizer.lastPlayed(g)
        f.memoryPeak = MemoryWatch.last(g)?.peak
        if g.native == nil, WineTools.hostContents(for: g) != nil { f.rawMouse = RawMouse.settings(for: g).enabled }
        return f
    }
}
