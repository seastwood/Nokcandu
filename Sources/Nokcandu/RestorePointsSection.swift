import SwiftUI
import AppKit
import NokcanduCore

/// Restore points for the game's Windows environment: taken automatically before fixes, recommended
/// setups and engine changes, or by hand. Restore puts the whole app back as it was.
struct RestorePointsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var points: [RestorePoint] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var busy = false
    @State private var restoring: RestorePoint?

    var host: URL? { RestorePoints.hostApp(for: game) }
    var hostName: String { host?.deletingPathExtension().lastPathComponent ?? game.name }
    var shared: Bool { host.map { $0.standardizedFileURL != game.appURL.standardizedFileURL } ?? false }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(shared
                     ? "\(game.name) runs inside \(hostName), so its restore points cover \(hostName) and every game in it."
                     : "Nokcandu takes one automatically before fixes, recommended setups and engine changes (the newest \(RestorePoints.keepAutomatic) are kept). They use almost no space until the game changes. Game files on another drive aren't included.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if points.isEmpty {
                    Text("No restore points yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(points) { p in
                    HStack {
                        Image(systemName: p.automatic ? "clock.arrow.circlepath" : "bookmark.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.created.formatted(date: .abbreviated, time: .shortened))
                            Text(p.reason + (sizes[p.id].map { " · \(Storage.format($0)) on its own" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") { restoring = p }.disabled(busy)
                        Button { delete(p) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(busy)
                            .help("Delete this restore point")
                    }
                }
                HStack {
                    Button("Take Restore Point Now") { take() }.disabled(busy || host == nil)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Restore Points").font(.headline) }
        .onAppear(perform: reload)
        .confirmationDialog("Restore \(hostName) to \(restoring?.created.formatted(date: .abbreviated, time: .shortened) ?? "")?",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore") { if let p = restoring { restore(p) }; restoring = nil }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            Text("Settings, fixes, the engine and anything saved inside \(hostName) go back to how they were then — including game saves kept in its Windows folders. The current state is kept as a restore point first, so you can switch back.")
        }
    }

    func reload() {
        points = RestorePoints.list(for: game)
        let ps = points
        Task.detached(priority: .utility) {
            let s = Dictionary(uniqueKeysWithValues: ps.map { ($0.id, RestorePoints.size($0)) })
            await MainActor.run { sizes = s }
        }
    }

    func take() {
        guard let host else { return }
        busy = true
        Task.detached {
            do {
                try RestorePoints.create(app: host, reason: "Taken by you", automatic: false)
                await MainActor.run { model.say("Took a restore point.") }
            } catch { await MainActor.run { model.fail(error) } }
            await MainActor.run { busy = false; reload() }
        }
    }

    func delete(_ p: RestorePoint) {
        do { try RestorePoints.delete(p); reload() } catch { model.fail(error) }
    }

    func restore(_ p: RestorePoint) {
        guard let host else { return }
        busy = true
        Task.detached {
            do {
                try RestorePoints.restore(p, app: host)
                await MainActor.run { model.refresh(); model.say("Restored \(host.deletingPathExtension().lastPathComponent).") }
            } catch { await MainActor.run { model.fail(error) } }
            await MainActor.run { busy = false; reload() }
        }
    }
}
