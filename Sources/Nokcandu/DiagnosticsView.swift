import SwiftUI
import NokcanduCore

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    @State private var report: DiagReport?
    @State private var savedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diagnostics — \(game.name)").font(.title2.bold())
                Spacer()
                if report == nil { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            if let report {
                List {
                    Section {
                        Text("Grouped by where a problem would come from. A running game process is never treated as proof that gameplay works.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(DiagLayer.allCases) { layer in
                        let checks = report.checks.filter { $0.layer == layer }
                        if !checks.isEmpty {
                            Section(layer.rawValue) {
                                ForEach(checks) { c in
                                    HStack(alignment: .firstTextBaseline) {
                                        Image(systemName: c.status.symbol).foregroundStyle(color(c.status))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.title)
                                            Text(c.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !report.logs.isEmpty {
                        Section("Recent logs") {
                            ForEach(report.logs, id: \.name) { log in
                                DisclosureGroup(log.name) {
                                    ScrollView(.horizontal) {
                                        Text(log.tail).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Spacer()
                Text("Checking files and hashes…").foregroundStyle(.secondary)
                Spacer()
            }
            Divider()
            HStack {
                if let savedURL {
                    Button("Show Report in Finder") { model.reveal(savedURL) }
                }
                Spacer()
                Button("Save Report") {
                    do { savedURL = try report?.save() } catch { model.fail(error) }
                }.disabled(report == nil)
                Button("Run Again") { Task { await load() } }.disabled(report == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 680, height: 600)
        .task { await load() }
    }

    func load() async {
        report = nil
        let g = game
        report = await Task.detached(priority: .userInitiated) { Diagnostics.collect(g) }.value
    }

    func color(_ s: DiagStatus) -> Color {
        switch s { case .ok: .green; case .warning: .orange; case .failure: .red; case .info: .secondary }
    }
}
