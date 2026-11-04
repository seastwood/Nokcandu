import SwiftUI
import NokcanduCore

struct PendingSettingsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var discarding = false
    var body: some View {
        let pending = PendingSettings.entries(for: game)
        if PendingSettings.hasPending(for: game) {
            SettingsSection(title: "Pending Changes") {
                Text(pending.isEmpty ? "Saved changes need attention. You can discard them to keep your current settings." : Array(Set(pending.map(\.title))).sorted().joined(separator: ", "))
                Text(model.pendingActivities[game.id] == .unknown
                     ? "Changes are saved. Nokcandu will apply them automatically once it can confirm this Windows environment is idle."
                     : "Changes are saved and apply automatically when all programs in this Windows environment close. Running games keep their current settings.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = PendingSettings.lastError(for: game) { Text(error).font(.caption).foregroundStyle(.orange) }
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
}
