import SwiftUI
import NokcanduCore

enum ChangeHistoryTabs {
    /// The tab where a change is made again (nil for fixes, which record themselves).
    static func tab(for c: PendingSettings.Change) -> String? {
        switch c {
        case .compatibility: return nil
        case .performance, .lowLatency, .frameCap, .audioBuffer: return GameDetailView.Tab.performance.rawValue
        case .display, .windowStyle, .nativeAdapter, .nativeFrame, .bc2: return GameDetailView.Tab.display.rawValue
        case .wine, .graphics, .custom, .cinematic: return GameDetailView.Tab.compatibility.rawValue
        case .recipe, .hosted: return GameDetailView.Tab.overview.rawValue
        }
    }
}

/// Overview → Recent Changes: what Nokcandu changed for this game, newest first, with a way back for each.
struct ChangeHistorySection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    /// Inside History & Restore: rows only.
    var embedded = false
    @State private var entries: [ChangeHistory.Entry] = []
    @State private var showAll = false
    @State private var working: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        if embedded {
            if entries.isEmpty { Text("No changes yet.").font(.callout).foregroundStyle(.secondary) } else { rows }
        } else if !entries.isEmpty {
            SettingsSection(title: "Recent Changes", info: "What Nokcandu changed for this game, newest first.") { rows }
        }
        }
        .task(id: "\(game.id)-\(model.libraryRevision)") {
                let g = game
                entries = await Task.detached(priority: .utility) { ChangeHistory.entries(g) }.value
            }
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
                ForEach(showAll ? entries : Array(entries.prefix(5))) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title)
                            Text(e.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch e.undo {
                        case .fix(let raw):
                            if let fix = CompatibilityFix(rawValue: raw), CompatibilityFixes.isInstalled(fix, for: game) {
                                Button("Undo") { undo(fix, e) }.disabled(working != nil || model.isRunning(game))
                            }
                        case .setting(let tab):
                            if let t = GameDetailView.Tab(rawValue: tab) {
                                Button { UserDefaults.standard.set(t.rawValue, forKey: "gameSettingsTab") } label: {
                                    HStack(spacing: 3) { Text(t.title); Image(systemName: "chevron.right").font(.caption2) }
                                }.buttonStyle(.link).accessibilityLabel("Open \(t.title)")
                            }
                        case .none: EmptyView()
                        }
                    }
                }
                if entries.count > 5 {
                    Button(showAll ? "Show Fewer" : "Show All \(entries.count)") { showAll.toggle() }.buttonStyle(.link)
                }
        }
    }

    func undo(_ fix: CompatibilityFix, _ e: ChangeHistory.Entry) {
        working = e.id
        let g = game
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try CompatibilityFixes.undo(fix, for: g) { _ in } }.value
                model.say("Removed \(fix.title) from \(g.name).")
            } catch { model.fail(error) }
            working = nil; model.refresh()
        }
    }
}


/// What Nokcandu changed, the restore points that can bring back an earlier state, and saved copies of the game's
/// own settings files: everything for going back, in one place.
struct HistoryRestoreSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var showBackups = false
    @State private var hasBackups = false

    var body: some View {
        SettingsSection(title: "History & Restore", info: "Recent Changes lists what Nokcandu changed for this game, newest first: a fix can be undone here, other changes are changed back where they were made (the arrow takes you there). Restore points bring back the whole game app as it was. Settings backups are earlier copies of the game's own settings files.") {
            Text("Recent Changes").font(.subheadline.bold())
            ChangeHistorySection(game: game, embedded: true)
            if RestorePoints.hostApp(for: game) != nil {
                Divider().padding(.vertical, 2)
                Text("Restore Points").font(.subheadline.bold())
                RestorePointsSection(game: game, embedded: true).id("restore-\(game.id)-\(model.games.count)")
            }
            if hasBackups {
                Divider().padding(.vertical, 2)
                Button("Settings Backups…") { showBackups = true }
            }
        }
        .task(id: game.id) {
            let g = game
            hasBackups = await Task.detached(priority: .utility) { !SettingsBackups.list(for: g).isEmpty }.value
        }
        .sheet(isPresented: $showBackups) { SettingsBackupsView(game: game).environmentObject(model) }
    }
}
