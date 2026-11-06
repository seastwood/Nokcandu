import SwiftUI

/// "Find a setting" on a game's page: words people use → the tab (and section) where it lives.
enum SettingSearch {
    struct Hit: Identifiable, Hashable { var id: String { label }; var label: String; var tab: GameDetailView.Tab }
    static let index: [(words: [String], label: String, tab: GameDetailView.Tab)] = [
        (["mouse", "raw mouse", "sensitivity", "aim", "cursor", "pointer"], "Mouse — raw mouse capture and speed", .controls),
        (["key", "keys", "keyboard", "remap", "layout", "karabiner", "fn", "control", "option", "command"], "Keyboard — remap keys, layouts", .controls),
        (["controller", "gamepad", "joystick", "wheel", "pedal", "hotas", "xbox", "playstation", "dualsense", "switch", "pro controller", "gyro", "steam controller"], "Controllers — as itself or as an Xbox controller", .controls),
        (["fps", "frame", "frame rate", "limit", "cap", "vsync", "hud", "counter", "latency", "lag", "smooth", "performance", "audio buffer", "crackle"], "Performance — FPS counter, vsync, frame limit, latency", .performance),
        (["resolution", "window", "windowed", "fullscreen", "full screen", "borderless", "resizable", "display", "screen", "retina", "size", "spaces"], "Display — resolution and window mode", .display),
        (["graphics", "dxmt", "dxvk", "d3dmetal", "d9vk", "directx", "metal", "renderer", "vulkan", "opengl"], "Graphics mode", .compatibility),
        (["wine", "engine", "version", "update engine", "roll back"], "Wine version", .compatibility),
        (["fix", "fixes", "dll", "video", "cinematic", "shader", "physx", "visual c", "d3d8", "ipx", "lan", "network"], "Fixes", .compatibility),
        (["program", "exe", "arguments", "launch options", "command line"], "Program and launch options", .compatibility),
        (["registry", "winecfg", "task manager", "command prompt", "c drive", "drive letter", "drives"], "Windows tools and drives", .compatibility),
        (["move", "drive", "storage", "space", "size", "folder", "restore", "restore point", "backup", "remove", "delete", "uninstall"], "Storage — location, restore points, remove", .storage),
        (["repair", "check", "diagnostics", "report", "won't start", "crash", "reset"], "Health — check, repair, diagnostics, reset", .compatibility),
        (["notes", "memory", "last played", "glance", "changes", "history", "undo"], "Overview — at a glance, recent changes, notes", .overview),
        (["microphone", "mic", "voice"], "Microphone", .controls),
        (["profile", "share", "community"], "Shared profiles", .compatibility),
    ]
    static func hits(_ text: String, available: [GameDetailView.Tab]) -> [Hit] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return index.filter { e in available.contains(e.tab) && (e.label.lowercased().contains(q) || e.words.contains { $0.hasPrefix(q) || q.hasPrefix($0) || $0.contains(q) }) }
            .map { Hit(label: $0.label, tab: $0.tab) }
    }
}

struct SettingSearchField: View {
    let available: [GameDetailView.Tab]
    @Binding var tab: GameDetailView.Tab
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let hits = SettingSearch.hits(text, available: available)
        VStack(alignment: .leading, spacing: 4) {
            TextField("Find a setting (mouse, fps, controller…)", text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let h = hits.first { go(h) } }
            if !hits.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hits) { h in
                        Button { go(h) } label: {
                            HStack { Image(systemName: h.tab.symbol).frame(width: 18); Text(h.label); Spacer(); Text(h.tab.title).foregroundStyle(.secondary) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, 3)
                    }
                }
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else if text.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("No setting by that name.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func go(_ h: SettingSearch.Hit) { tab = h.tab; text = ""; focused = false }
}
