import SwiftUI
import AppKit
import NokcanduCore

struct HostedGameSettingsSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var settings = HostedSettings.Settings()
    @State private var busy = false
    @State private var styleEdited = false
    var body: some View {
        SettingsSection(title: "Game Settings", info: game.hosted.map { "These settings apply only when you start this game from Nokcandu or its Mac app. \($0.launcher.title) keeps its own graphics settings. Saved changes apply automatically once all programs in its Windows environment close." }) {
                SettingRow(title: "Graphics") {
                    Picker("Graphics", selection: $settings.graphics) {
                        Text("Same as launcher").tag(GraphicsPreset?.none)
                        ForEach(GraphicsPreset.allCases) { Text($0.title).tag(Optional($0)) }
                    }.labelsHidden().frame(width: settingControlWidth)
                }
                SettingNote((settings.graphics ?? HostedSettings.graphics(game)).detail)
                if game.hosted?.launcher == .ea {
                    SettingRow(title: "Window style") {
                        Picker("Window style", selection: Binding(get: { !styleEdited && CompatibilityFixes.isEnabled(.borderless, for: game) ? (settings.macFullScreen == true ? .fullScreen : .borderless) : GameWindowStyle.current(settings) }, set: { styleEdited = true; GameWindowStyle.set($0, in: &settings) })) {
                            ForEach(GameWindowStyle.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: settingControlWidth)
                    }
                    SettingNote("For either fullscreen style, select Windowed in the game first. Fullscreen also opens the resizable window in Mac full screen.")
                }
                SettingRow(title: "Launch options") { TextField("Launch options", text: $settings.arguments).font(.body.monospaced()) }
                if let link = game.hosted {
                    Text(link.exe ?? "Starts through the launcher").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Save Game Settings") {
                    var value = settings
                    if !styleEdited, CompatibilityFixes.isEnabled(.borderless, for: game) { value.borderless = true }
                    model.changeSetting(for: game, title: "Game Settings", success: "Game settings saved. Start this game from Nokcandu to use them.", change: .hosted(value))
                }
                if BC2DisplaySettings.supports(game) {
                    Button("Use Recommended BC2 Display Settings") {
                        var value = settings; value.graphics = .classic3D; value.borderless = nil
                        model.changeSetting(for: game, title: "BC2 Display Settings", success: "BC2 uses fullscreen at the desktop size with DirectX 9.", change: .bc2(undo: false, resolution: BC2DisplaySettings.desktop, settings: value), completion: { saved in if saved { settings = value } })
                    }
                    SettingNote("Recommended: BC2’s own fullscreen mode at your current desktop size. Avoids the menu-pointer offset caused by resizing its window.")
                    Button("Undo BC2 Display Settings") {
                        model.changeSetting(for: game, title: "BC2 Display Settings", success: "BC2 display changes undone; later edits were kept.", change: .bc2(undo: true, resolution: nil, settings: nil))
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
                    SettingNote("Restart closes all EA games. Use it if EA reports a crashed background service or cannot quit.")
                }
        }
        .onAppear { settings = PendingSettings.hosted(for: game) ?? HostedSettings.load(game) }
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
