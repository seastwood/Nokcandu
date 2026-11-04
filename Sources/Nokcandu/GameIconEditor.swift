import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NokcanduCore

struct GameIconEditor: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var working = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: game.icon).resizable().frame(width: 96, height: 96)
            if GameIcon.supports(game) {
                Menu {
                    Button("Choose Icon from EXE…", action: choose)
                    if GameIcon.hasChanges(game) {
                        Button("Restore Original Icon") {
                            do { try GameIcon.undo(game); model.refresh(); model.say("Original icon restored.") }
                            catch { model.fail(error) }
                        }
                    }
                } label: { Label("Edit Icon", systemImage: "pencil") }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
                .disabled(working)
                .help("Choose another program's icon without changing what this game launches.")
            }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a program for its icon"
        panel.message = "Only the icon will change. Your game's launch program stays the same."
        panel.prompt = "Use Icon"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.directoryURL = game.custom.flatMap { BattleNet.unixPath($0.exe, prefix: game.prefix) }?.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let file = panel.url else { return }
            working = true
            let selectedGame = game
            Task {
                do {
                    try await Task.detached { try GameIcon.set(from: file, for: selectedGame) }.value
                    model.refresh(); model.say("Icon updated. The launch program is unchanged; a running game's Dock icon updates next time it opens.")
                } catch { model.fail(error) }
                working = false
            }
        }
    }
}
