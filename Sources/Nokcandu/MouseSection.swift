import SwiftUI
import GameController
import NokcanduCore

/// "Raw mouse capture" switch and speed, on any game with a Windows environment.
struct MouseSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var enabled = false
    @State private var scale = 1.0
    @State private var smooth = false
    @State private var frameSync = false
    @State private var mice: [String] = []
    @State private var status: String?
    @State private var loaded = false

    var steam: Bool { game.usesSharedSteam || game.isSteamHost }

    var scope: String {
        game.hosted != nil ? "Applies only to this game, including when EA starts it."
            : steam ? "Applies to all Steam games." : "Applies to this game."
    }

    var body: some View {
        SettingsSection(title: "Mouse") {
            SettingToggle(title: "Raw mouse capture",
                          info: "Whenever the game captures the mouse (aiming, turning the camera, flight or racing, rotating the view in strategy games), this reads the mouse itself: hundreds of updates a second, no macOS acceleration, no stalls when the game re-centers the cursor. While the game shows a normal cursor (menus, point-and-click games) the Mac pointer is used; for those, turning off Pointer acceleration in System Settings → Mouse gives a similar 1:1 feel.\n\n\(scope) You can turn it on or off while playing; changes apply within a second.",
                          isOn: Binding(get: { enabled }, set: { enabled = $0; save() }))
            if enabled {
                SettingRow(title: "Speed", info: "1× matches a Windows PC at the same in-game sensitivity. Raw movement isn't accelerated, so it may feel slower than your Mac pointer at first: adjust it here or with the game's sensitivity.") {
                    Slider(value: $scale, in: 0.25...3, step: 0.05) { editing in if !editing { save() } }
                        .frame(width: 160)
                    Text(String(format: "%.2f×", scale)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    Button("Reset") { scale = 1; save() }.buttonStyle(.link)
                }
                SettingToggle(title: "Smooth movement",
                              info: "Spreads each mouse report evenly over the time until the next one, so every frame turns the same amount. Helps basic 125 Hz mice; adds at most one report interval (about 8 ms) of delay. Gaming mice (500–1000 Hz) don't need it.",
                              isOn: Binding(get: { smooth }, set: { smooth = $0; save() }))
                SettingToggle(title: "Deliver movement once per frame (experimental)",
                              info: "Collects the mouse's movement and hands it to the game once per frame, so every frame turns by exactly one frame's worth. Can add up to one frame of delay. Works with games that draw through Metal (Apple Metal, DXMT, Vulkan).",
                              isOn: Binding(get: { frameSync }, set: { frameSync = $0; save() }))
            }
            if enabled, mice.isEmpty {
                SettingNote("No mouse or trackpad detected yet; until one is, the normal mouse path is used.", warning: true)
            }
            if BF1942DisplayFix.supports(game) {
                SettingNote("Raw mouse capture has a reported compatibility issue in Battlefield 1942. Leave it off.", warning: true)
            }
            if enabled, let s = status {
                SettingNote("Last run: \(s)")
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in readMice() }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidDisconnect)) { _ in readMice() }
    }

    func load() {
        let s = RawMouse.settings(for: game)
        enabled = s.enabled; scale = s.scale; smooth = s.smooth; frameSync = s.frameSync; loaded = true
        status = RawMouse.lastStatus(for: game)
        readMice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { readMice() }   // GameController finds mice shortly after start
    }

    func readMice() { mice = GCMouse.mice().map { $0.vendorName ?? "Mouse" } }

    func save() {
        guard loaded else { return }
        do {
            try RawMouse.apply(RawMouse.Settings(enabled: enabled, scale: scale, smooth: smooth, frameSync: frameSync), for: game)
            model.say(enabled ? "Raw mouse capture on (\(String(format: "%.2f", scale))×) — applies right away, also while playing." : "Raw mouse capture off — applies right away.")
        } catch { model.fail(error) }
    }
}
