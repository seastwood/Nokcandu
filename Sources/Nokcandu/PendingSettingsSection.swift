import SwiftUI
import NokcanduCore

struct PendingSettingsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var discarding = false
    var body: some View {
        let pending = PendingSettings.entries(for: game)
        if PendingSettings.hasPending(for: game) {
            SettingsSection(title: "Saved for Next Start") {
                Text(pending.isEmpty ? "Saved changes need attention. You can discard them to keep your current settings." : Array(Set(pending.map(\.title))).sorted().joined(separator: ", "))
                Text("These changes are saved. They apply when this game's Windows environment next starts with all its programs closed. Your current session keeps its existing settings.")
                    .font(.caption).foregroundStyle(.secondary)
                if !FileManager.default.isExecutableFile(atPath: game.nokcanduState.appendingPathComponent(PendingSettings.helperName).path) {
                    Text("For older or manually edited launchers, start the game from Nokcandu to apply pending changes.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = PendingSettings.lastError(for: game) { Text(error).font(.caption).foregroundStyle(.orange) }
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
