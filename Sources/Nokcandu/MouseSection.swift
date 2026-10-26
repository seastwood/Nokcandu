import SwiftUI
import GameController
import NokcanduCore

/// "Raw mouse for aiming" switch and aim speed, on any game with a Windows environment.
struct MouseSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var enabled = false
    @State private var scale = 1.0
    @State private var smooth = false
    @State private var mice: [String] = []
    @State private var status: String?
    @State private var loaded = false

    var steam: Bool { game.usesSharedSteam || game.isSteamHost }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { enabled }, set: { enabled = $0; save() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raw mouse for aiming").font(.body.bold())
                        Text("Wine normally turns the Mac's pointer into game input — about one update per screen refresh, with macOS acceleration, and stalls each time a shooter re-centers the cursor. This reads the mouse itself (hundreds of updates a second, no acceleration) while you're aiming. Menus and other apps keep the normal pointer.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                if enabled {
                    HStack {
                        Text("Aim speed").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Slider(value: $scale, in: 0.25...3, step: 0.05) { editing in if !editing { save() } }
                            .frame(maxWidth: 260)
                        Text(String(format: "%.2f×", scale)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        Button("Reset") { scale = 1; save() }.buttonStyle(.link)
                    }
                    Toggle("Smooth movement", isOn: Binding(get: { smooth }, set: { smooth = $0; save() }))
                        .help("Spreads each mouse report evenly over the time until the next one, so every frame turns the same amount. Helps basic 125 Hz mice; adds at most one report interval (8 ms) of delay.")
                    Text("Smooth movement evens out basic (125 Hz) mice, which otherwise move the view unevenly from frame to frame; it adds up to ~8 ms of delay. Gaming mice (500–1000 Hz) don't need it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("1× matches a Windows PC at the same in-game sensitivity. Raw movement isn't accelerated, so it may feel slower than your Mac pointer at first — adjust here or with the game's sensitivity.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: mice.isEmpty ? "exclamationmark.triangle" : "computermouse")
                        .foregroundStyle(mice.isEmpty ? .orange : .secondary)
                    Text(mice.isEmpty ? "No mouse or trackpad detected yet; until one is, the normal path is used."
                                      : "Detected: \(mice.joined(separator: ", ")) — a USB mouse gives the smoothest aim.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let s = status {
                    Text("Last run: \(s)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(steam ? "Applies to all Steam games. Takes effect the next time Steam starts (Quit Steam on the Steam page first)."
                           : "Takes effect the next time the game starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Mouse").font(.headline) }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in readMice() }
        .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidDisconnect)) { _ in readMice() }
    }

    func load() {
        let s = RawMouse.settings(for: game)
        enabled = s.enabled; scale = s.scale; smooth = s.smooth; loaded = true
        status = RawMouse.lastStatus(for: game)
        readMice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { readMice() }   // GameController finds mice shortly after start
    }

    func readMice() { mice = GCMouse.mice().map { $0.vendorName ?? "Mouse" } }

    func save() {
        guard loaded else { return }
        do {
            try RawMouse.apply(RawMouse.Settings(enabled: enabled, scale: scale, smooth: smooth), for: game)
            model.say(enabled ? "Raw mouse on (\(String(format: "%.2f", scale))×). \(steam ? "Restart Steam" : "Restart the game") to use it." : "Raw mouse off.")
        } catch { model.fail(error) }
    }
}
