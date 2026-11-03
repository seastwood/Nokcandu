import SwiftUI
import AppKit
import NokcanduCore

struct AppRollbackSection: View {
    @EnvironmentObject var model: AppModel
    @State private var saved: [AppRollback.Saved] = []
    @State private var releases: [AppUpdate.Release] = []
    @State private var selected = ""
    @State private var loading = false
    @State private var busy = false
    @State private var confirm = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Return to Another Nokcandu Version").font(.body.bold())
            Text("Only Nokcandu is replaced. Games, saves, installed Wine versions and saved settings stay in place. Nokcandu restarts; running games can stay open. Older app versions may not understand newer settings.")
                .font(.caption).foregroundStyle(.secondary)
            if !saved.isEmpty || !releases.isEmpty {
                Picker("App version", selection: $selected) {
                    Text("Choose a version…").tag("")
                    ForEach(saved) { entry in
                        Text("Saved \(entry.version) · build \(entry.build) · \(entry.savedAt.formatted(date: .abbreviated, time: .shortened))").tag(entry.id.uuidString)
                    }
                    ForEach(releases, id: \.tag) { release in Text("GitHub release \(release.version)").tag(release.tag) }
                }
                HStack {
                    Button("Use Version & Restart…") { confirm = true }.disabled(selected.isEmpty || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            } else { Text("A recovery copy is saved before each app update or rollback.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Find Published Versions") {
                    loading = true
                    Task {
                        do { releases = try await AppUpdate.availableVersions().filter { AppUpdate.isNewer(AppUpdate.currentVersion, than: $0.version) }; message = releases.isEmpty ? "No older releases with published checksums were found." : nil }
                        catch { message = error.localizedDescription }
                        loading = false
                    }
                }.disabled(loading || busy)
                if loading { ProgressView().controlSize(.small) }
                Button("Open Recovery Copies") {
                    do { try NokPaths.ensure(AppRollback.root); NSWorkspace.shared.open(AppRollback.root) }
                    catch { model.fail(error) }
                }
            }
            Text("If Nokcandu won't open, quit it and open Restore Nokcandu.command inside a saved version's folder. Keep these recovery copies until you no longer need them; they use space on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .task { await reload() }
        .confirmationDialog("Replace Nokcandu and restart it?", isPresented: $confirm) {
            Button("Use Selected Version & Restart") { restore() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("The current app is saved first so you can return to it. Games and saves are preserved.") }
    }

    func reload() async {
        saved = await Task.detached { AppRollback.saved() }.value
        if message == nil { message = try? String(contentsOf: AppRollback.root.appendingPathComponent("last-result.txt"), encoding: .utf8) }
    }
    func restore() {
        busy = true; message = "Preparing the selected version…"
        let choice = selected, local = saved.first { $0.id.uuidString == choice }, release = releases.first { $0.tag == choice }
        Task {
            do {
                let quit: @Sendable () -> Void = { Task { @MainActor in NSApp.terminate(nil) } }
                if let local {
                    let current = Bundle.main.bundleURL
                    let plan = try await Task.detached { try AppRollback.prepare(source: local.app(), current: current) }.value
                    guard plan.expectedNewSHA == local.appSHA else { throw NokError("The saved app has changed. Choose another recovery copy.") }
                    try AppRollback.launch(plan, quit: quit)
                } else if let release {
                    try await AppUpdate.install(release, log: { text in Task { @MainActor in message = text } }, quit: quit)
                }
            } catch { message = error.localizedDescription; busy = false; await reload() }
        }
    }
}
