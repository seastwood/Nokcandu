import SwiftUI
import NokcanduCore

/// Game → Change Several Games…: pick games, then give them all the same keys, controller setting or graphics
/// mode, or add them to Favorites. Each change goes through the same path as on the game's own page.
struct SeveralGamesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<String>()
    @State private var layouts: [KeyRemap.Layout] = []
    @State private var working = false

    var games: [InstalledGame] {
        model.games.filter { $0.native == nil && !LibraryOrganizer.isLauncher($0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var picked: [InstalledGame] { games.filter { chosen.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Several Games").font(.title2.bold())
            HStack {
                Button("Select All") { chosen = Set(games.map(\.id)) }.buttonStyle(.link)
                Button("Select None") { chosen = [] }.buttonStyle(.link)
                Spacer()
                Text("\(chosen.count) selected").foregroundStyle(.secondary)
            }
            List(games) { g in
                Toggle(isOn: Binding(get: { chosen.contains(g.id) }, set: { on in if on { chosen.insert(g.id) } else { chosen.remove(g.id) } })) {
                    HStack {
                        Text(g.name)
                        Spacer()
                        Text(model.subtitles[g.id] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 260)
            HStack(spacing: 10) {
                Menu("Keys") {
                    Button("Default layout") { keys(.followDefault) }
                    Button("Normal keys") { keys(.normal) }
                    if !layouts.isEmpty { Divider() }
                    ForEach(layouts) { l in Button(l.name) { keys(.layout(l.id)) } }
                }
                Menu("Controllers") {
                    ForEach(Controllers.Mode.allCases) { m in Button(m.title) { controllers(m) } }
                }
                Menu("Graphics") {
                    ForEach(GraphicsPreset.allCases) { p in Button(p.title) { graphics(p) } }
                }
                Button("Add to Favorites") { for g in picked { model.setFavorite(g, true) }; model.say("Added \(picked.count) game\(picked.count == 1 ? "" : "s") to Favorites.") }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(working || chosen.isEmpty)
            Text("Games inside Steam or Battle.net share their launcher's controller setting; graphics applies to games with their own Windows setup and to Battle.net games. Running games pick changes up the next time they start.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22).frame(width: 620, height: 560)
        .onAppear { layouts = KeyRemap.layouts() }
    }

    func keys(_ c: KeyRemap.Choice) {
        var n = 0
        for g in picked {
            guard let folder = KeyRemap.gameContents(for: g) else { continue }
            if (try? KeyRemap.set(c, contents: folder)) != nil { n += 1; ChangeHistory.note(g, "Keys changed for several games", undo: .setting(GameDetailView.Tab.controls.rawValue)) }
        }
        let games = model.games
        Task.detached(priority: .utility) { KeyRemap.refreshRoutes(games) }
        model.say("Changed the keys for \(n) game\(n == 1 ? "" : "s").")
    }

    func controllers(_ m: Controllers.Mode) {
        let hosts = Set(picked.compactMap { WineTools.hostContents(for: $0) })
        var done = 0, busy = 0
        for h in hosts { do { try Controllers.set(m, contents: h); done += 1 } catch { busy += 1 } }
        model.say("Controllers now reach games \(m.title.lowercased()) in \(done) Windows environment\(done == 1 ? "" : "s")" + (busy > 0 ? "; \(busy) were running and were left as they were." : "."))
    }

    func graphics(_ p: GraphicsPreset) {
        let targets = picked.filter { $0.custom != nil && !$0.usesSharedSteam || $0.battleNet != nil }
        for g in targets {
            if g.battleNet != nil { try? BattleNetGraphics.set(p, for: g, games: model.games); ChangeHistory.note(g, "Graphics: \(p.title)", undo: .setting(GameDetailView.Tab.compatibility.rawValue)) }
            else { model.changeSetting(for: g, title: "Graphics", success: "Graphics set to \(p.title) for \(g.name).", change: .graphics(p)) }
        }
        model.say("Set graphics to \(p.title) for \(targets.count) game\(targets.count == 1 ? "" : "s").")
        model.refresh()
    }
}
