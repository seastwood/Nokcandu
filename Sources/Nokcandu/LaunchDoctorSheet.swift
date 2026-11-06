import SwiftUI
import NokcanduCore

struct LaunchDoctorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    @State private var progress = "Starting…"
    @State private var finding: LaunchDoctor.Finding?
    @State private var showReport = false
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Why won't \(game.name) start?").font(.title2.bold())
            if let f = finding {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: f.action == .play || f.title == "Nothing wrong found" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(f.action == .play || f.title == "Nothing wrong found" ? .green : .orange).font(.title2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.title).font(.headline)
                        Text(f.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                DisclosureGroup("What was checked") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(f.steps, id: \.self) { s in Label(s, systemImage: "checkmark").font(.callout).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text(progress).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Report a Problem…") { showReport = true }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if let f = finding, let title = f.actionTitle { Button(title) { act(f.action) }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22).frame(width: 560)
        .sheet(isPresented: $showReport) { ReportProblemView(game: game).environmentObject(model) }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(game: game) }
        .task {
            let g = game, running = model.isRunning(game), problem = model.launchProblems[game.id]
            finding = await LaunchDoctor.diagnose(g, running: running, recentLaunchProblem: problem) { line in Task { @MainActor in progress = line } }
            model.refresh()
        }
    }

    func act(_ a: LaunchDoctor.Action) {
        switch a {
        case .play: dismiss(); model.play(game)
        case .quit: dismiss(); model.requestQuit(game)
        case .showCrash, .chooseProgram: UserDefaults.standard.set(a == .showCrash ? GameDetailView.Tab.overview.rawValue : GameDetailView.Tab.compatibility.rawValue, forKey: "gameSettingsTab"); dismiss()
        case .showMods: if let root = ModDependencies.gameRoot(game) { model.reveal(ModDependencies.child(of: root, named: "Mods") ?? root) }
        case .openPrivacy: if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
        case .diagnostics: showDiagnostics = true
        case .openLauncher:
            if let c = WineTools.hostContents(for: game), let h = model.games.first(where: { $0.contents.standardizedFileURL == c.standardizedFileURL }) { model.selection = h.id }
            dismiss()
        case .none: dismiss()
        }
    }
}
