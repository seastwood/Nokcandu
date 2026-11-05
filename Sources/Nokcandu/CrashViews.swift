import SwiftUI
import AppKit
import NokcanduCore

/// The last crash of this game, explained, with the full report a click away.
struct CrashBanner: View {
    let game: InstalledGame
    let running: Bool
    @State private var crash: CrashReports.Explanation?
    @State private var showReport = false

    var dismissedKey: String { "crashDismissed." + game.id }

    var body: some View {
        // A VStack, not a Group: an empty Group never runs its .task.
        VStack(alignment: .leading, spacing: 0) {
            if let c = crash {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.missingMod != nil ? "puzzlepiece.extension" : "exclamationmark.octagon").foregroundStyle(.red).font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.title).font(.body.bold())
                        Text(c.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(c.evidence + " · " + c.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Button("Show Report") { showReport = true }
                        Button("Dismiss") {
                            UserDefaults.standard.set(c.date.timeIntervalSince1970, forKey: dismissedKey)
                            crash = nil
                        }
                    }
                }
                .padding(12)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .sheet(isPresented: $showReport) { CrashReportSheet(game: game, crash: c) }
            }
        }
        .task(id: "\(game.id)-\(running)") { await load() }
    }

    func load() async {
        guard !running else { return }
        let g = game
        let dismissed = UserDefaults.standard.double(forKey: dismissedKey)
        let since = dismissed > 0 ? Date(timeIntervalSince1970: dismissed + 1) : nil
        crash = await Task.detached(priority: .utility) { CrashReports.lastCrash(g, since: since) }.value
    }
}

struct CrashReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    let crash: CrashReports.Explanation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(game.name) crash report").font(.title2.bold())
            Text(crash.title + ". " + crash.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(crash.report).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 420)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(crash.report, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 640)
    }
}

/// Mods in the game's folder that need another mod which isn't installed.
struct ModDependencyBanner: View {
    let game: InstalledGame
    let running: Bool
    @State private var missing: [ModDependencies.Missing] = []

    var body: some View {
        // A VStack, not a Group: an empty Group never runs its .task.
        VStack(alignment: .leading, spacing: 0) {
            if !missing.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.orange).font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(missing.count == 1 ? "A mod is missing a mod it needs" : "Some mods are missing mods they need").font(.body.bold())
                        ForEach(missing, id: \.self) { m in
                            Text(m.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if let root = ModDependencies.gameRoot(game) {
                        Button("Show Mods Folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([ModDependencies.child(of: root, named: "Mods") ?? root])
                        }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task(id: "\(game.id)-\(running)") {
            let g = game
            missing = await Task.detached(priority: .utility) { ModDependencies.missing(g) }.value
        }
    }
}
