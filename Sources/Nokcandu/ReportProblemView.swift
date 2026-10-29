import SwiftUI
import AppKit
import NokcanduCore

/// Write what happened, read exactly what would be shared, then open a GitHub issue with it.
struct ReportProblemView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let game: InstalledGame?
    @State private var what = ""
    @State private var report = ""
    @State private var loading = true

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(game.map { "Report a Problem with \($0.name)" } ?? "Report a Problem").font(.title2.bold())
            Text("What happened, and what did you expect?").font(.callout)
            TextEditor(text: $what).font(.body).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            HStack {
                Text("What will be shared").font(.callout.bold())
                Text("— your name, user name, computer name, email addresses and Steam IDs are taken out. You can edit it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Collecting details…").frame(maxWidth: .infinity, minHeight: 200) }
            else {
                TextEditor(text: $report).font(.caption.monospaced()).frame(minHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
            Text("Opens a new issue on GitHub (you'll need a free GitHub account). Nothing is sent until you press Submit there. The full report is also saved and copied, so you can paste or attach it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open GitHub Issue") { open() }.buttonStyle(.borderedProminent)
                    .disabled(loading || what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680)
        .task {
            let g = game, v = version
            report = await Task.detached { ProblemReport.build(game: g, description: "", nokcanduVersion: v) }.value
            loading = false
        }
    }

    func open() {
        let text = report.replacingOccurrences(of: "(describe the problem)", with: ProblemReport.redact(what))
        let title = (game.map { "\($0.name): " } ?? "") + (what.split(separator: "\n").first.map { String($0.prefix(80)) } ?? "Problem")
        do {
            let file = try ProblemReport.save(text, name: game?.name ?? "Nokcandu")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            NSWorkspace.shared.open(ProblemReport.issueLink(title: title, body: text))
            NSWorkspace.shared.activateFileViewerSelecting([file])
            model.say("Report copied and saved. Finish it on GitHub — drag the saved file in if it was cut short.")
            dismiss()
        } catch { model.fail(error) }
    }
}
