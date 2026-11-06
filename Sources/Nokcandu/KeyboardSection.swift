import SwiftUI
import NokcanduCore

/// Controls → Keyboard: keys that act as other keys in this game only (no system-wide remapper needed).
struct KeyboardSection: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @State private var mappings: [KeyRemap.Mapping] = []
    @State private var profiles: [KeyRemap.KarabinerProfile] = []

    var contents: URL? { KeyRemap.contents(for: game) }
    var scope: String {
        if game.usesSharedSteam || game.isSteamHost { return "Applies to all Steam games." }
        if game.battleNet != nil || BattleNet.isHost(game) { return "Applies to all Battle.net games." }
        if game.hosted != nil || PCLaunchers.kind(of: game) != nil { return "Applies to all games in this launcher." }
        return "Applies to this game only."
    }

    var body: some View {
        SettingsSection(title: "Keyboard", info: "Make a key act as another key while the game is in front — for example fn as Control, or Right Option as Right Control. Switching to another app, or quitting the game, puts your keyboard back. Remapped keys are real keys to macOS too: fn as Control holds like Control and doesn't open fn's shortcuts.\n\n\(scope) Changes apply while playing.") {
            if mappings.isEmpty {
                Text("No keys remapped.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach($mappings) { $m in
                HStack {
                    Picker("Key", selection: Binding(get: { m.from }, set: { new in
                        guard !mappings.contains(where: { $0.from == new }) else { return }
                        m.from = new; save()
                    })) { ForEach(KeyRemap.keys) { Text($0.title).tag($0.code) } }
                        .labelsHidden().frame(width: 170)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityLabel("acts as")
                    Picker("Acts as", selection: Binding(get: { m.to ?? -1 }, set: { m.to = $0 < 0 ? nil : $0; save() })) {
                        Text("Nothing").tag(-1)
                        ForEach(KeyRemap.keys) { Text($0.title).tag($0.code) }
                    }
                        .labelsHidden().frame(width: 170)
                    Spacer()
                    Button { mappings.removeAll { $0.from == m.from }; save() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove this remap").help("Remove")
                }
            }
            HStack {
                Button("Add Key") { add() }
                if !profiles.isEmpty {
                    Menu("Copy from Karabiner-Elements") {
                        ForEach(profiles) { p in
                            Button("\(p.name)\(p.selected ? " (current)" : "") — \(p.mappings.count) key\(p.mappings.count == 1 ? "" : "s")") { copy(p) }
                                .disabled(p.mappings.isEmpty)
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .onAppear(perform: load)
    }

    func load() {
        if let c = contents { mappings = KeyRemap.load(contents: c) }
        profiles = KeyRemap.karabinerProfiles()
    }
    func save() {
        guard let c = contents else { return }
        do { try KeyRemap.save(mappings, contents: c) } catch { model.fail(error) }
    }
    func add() {
        let used = Set(mappings.map(\.from))
        guard let free = KeyRemap.keys.first(where: { !used.contains($0.code) }) else { return }
        mappings.append(KeyRemap.Mapping(from: free.code, to: free.code == 59 ? 62 : 59))
        save()
    }
    func copy(_ p: KarabinerProfile) {
        for m in p.mappings {
            mappings.removeAll { $0.from == m.from }
            mappings.append(m)
        }
        save()
        model.say("Copied \(p.mappings.count) key remap\(p.mappings.count == 1 ? "" : "s") from Karabiner's \(p.name) profile" + (p.skipped > 0 ? " (\(p.skipped) rule\(p.skipped == 1 ? "" : "s") it can't copy were left out)." : ".") + " Turn that profile off while playing so keys aren't remapped twice.")
    }
    typealias KarabinerProfile = KeyRemap.KarabinerProfile
}
