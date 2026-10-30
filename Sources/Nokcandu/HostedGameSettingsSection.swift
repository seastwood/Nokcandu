import SwiftUI
import AppKit
import NokcanduCore

struct HostedGameSettingsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var settings = HostedSettings.Settings()
    @State private var busy = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Graphics", selection: $settings.graphics) {
                    Text("Same as launcher").tag(GraphicsPreset?.none)
                    ForEach(GraphicsPreset.allCases) { Text($0.title).tag(Optional($0)) }
                }.frame(maxWidth: 380)
                Text((settings.graphics ?? HostedSettings.graphics(game)).detail).font(.caption).foregroundStyle(.secondary)
                if game.hosted?.launcher == .ea {
                    Picker("Window style", selection: Binding(get: { settings.borderless == true }, set: { settings.borderless = $0 ? true : nil })) {
                        Text("Game default").tag(false)
                        Text("Fullscreen (Borderless)").tag(true)
                    }.frame(maxWidth: 380)
                    Text("For borderless, select Windowed in the game first.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Launch options", text: $settings.arguments).font(.body.monospaced())
                if let link = game.hosted {
                    Text("These settings apply only when you start this game from Nokcandu or its Mac app. \(link.launcher.title) keeps its own graphics settings. Nokcandu offers to restart its Windows programs when needed.").font(.caption).foregroundStyle(.secondary)
                    Text(link.exe ?? "Starts through the launcher").font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Save Game Settings") {
                    let value = settings
                    model.changeSetting(for: game, title: "Game Settings", success: "Game settings saved. Start this game from Nokcandu to use them.", edit: { current in
                        try HostedSettings.save(value, for: current)
                    })
                }
                if BC2DisplaySettings.supports(game) {
                    Button("Use Recommended BC2 Display Settings") {
                        var value = settings; value.graphics = .classic3D; value.borderless = nil
                        model.changeSetting(for: game, title: "BC2 Display Settings", success: "BC2 uses fullscreen at the desktop size with DirectX 9.", edit: { current in
                            try BC2DisplaySettings.apply(current, resolution: BC2DisplaySettings.desktop)
                            try HostedSettings.save(value, for: current)
                        }, completion: { saved in if saved { settings = value } })
                    }
                    Text("Recommended: BC2’s own fullscreen mode at your current desktop size. Avoids the menu-pointer offset caused by resizing its window.").font(.caption).foregroundStyle(.secondary)
                    Button("Undo BC2 Display Settings") {
                        model.changeSetting(for: game, title: "BC2 Display Settings", success: "BC2 display changes undone; later edits were kept.", edit: { current in
                            try BC2DisplaySettings.undo(current)
                        })
                    }.disabled(BC2DisplaySettings.resolution(game) == nil)
                }
                if game.hosted?.launcher == .ea {
                    Button("Restart EA and Windows Programs") {
                        busy = true
                        Task {
                            do {
                                try await WineTools.restartHost(for: game)
                                model.say("EA restarted. All games in its Windows environment were closed.")
                            } catch { model.fail(error) }
                            busy = false
                        }
                    }.disabled(busy)
                    Text("Restart closes all EA games. Use it if EA reports a crashed background service or cannot quit.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        } label: { Text("Game Settings").font(.headline) }
        .onAppear { settings = HostedSettings.load(game) }
    }
}

/// NVIDIA PhysX runtime: a row in the game's Fixes.
struct PhysXRuntimeRow: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var installed = false
    @State private var busy = false
    var body: some View {
        SettingRow(title: "NVIDIA PhysX runtime",
                   info: "For games reporting missing PhysXLoader or NxCharacter libraries. Installed in this game's Windows environment; games sharing that environment share it.") {
            if installed { InstalledBadge() }
            else if busy { ProgressView().controlSize(.small) }
            else { Button("Install") { install() } }
        }
        .onAppear { reload() }
    }
    func reload() { installed = WineTools.hostContents(for: game).map { PhysXRuntime.installed(contents: $0) } ?? false }
    func install() {
        busy = true
        Task {
            do { try await PhysXRuntime.install(for: game); model.say("PhysX installed. Restart the game to try it.") }
            catch { model.fail(error) }
            reload(); busy = false
        }
    }
}
