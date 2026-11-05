import SwiftUI
import NokcanduCore

struct PendingSettingsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var discarding = false
    /// (titles waiting, last error); nil when nothing is waiting. Read off the main thread.
    @State private var state: (pending: [PendingSettings.Entry], error: String?)?
    var body: some View {
        Group {
            if let state { section(state.pending, error: state.error) }
        }
        .task(id: "\(game.id)|\(model.libraryRevision)|\(model.pendingActivities[game.id].map { "\($0)" } ?? "")") {
            let g = game
            state = await Task.detached(priority: .userInitiated) { () -> ([PendingSettings.Entry], String?)? in
                guard PendingSettings.anyQueued(), PendingSettings.hasPending(for: g) else { return nil }
                return (PendingSettings.entries(for: g), PendingSettings.lastError(for: g))
            }.value
        }
    }
    @ViewBuilder func section(_ pending: [PendingSettings.Entry], error: String?) -> some View {
            SettingsSection(title: "Pending Changes") {
                Text(pending.isEmpty ? "Saved changes need attention. You can discard them to keep your current settings." : Array(Set(pending.map(\.title))).sorted().joined(separator: ", "))
                Text(model.pendingActivities[game.id] == .unknown
                     ? "Changes are saved. Nokcandu will apply them automatically once it can confirm this Windows environment is idle."
                     : "Changes are saved and apply automatically when all programs in this Windows environment close. Running games keep their current settings.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Try Applying Now") { model.applyIdleSettings(retry: true) }
                Button("Discard Pending Changes") {
                    discarding = true
                    Task {
                        do {
                            let selected = game
                            try await Task.detached { try PendingSettings.discard(for: selected) }.value
                            model.refresh()
                        } catch { model.fail(error) }
                        discarding = false
                    }
                }.disabled(discarding)
            }
    }
}
