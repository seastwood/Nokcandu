import SwiftUI
import AppKit
import NokcanduCore

/// Storage → Free Up Space: what Nokcandu can safely remove, and how much each frees.
struct SpaceSaverList: View {
    @EnvironmentObject var model: AppModel
    let suggestions: [SpaceSaver.Suggestion]
    let busy: Bool
    let run: (@escaping @Sendable () -> String) -> Void

    var body: some View {
        if suggestions.isEmpty {
            Text("Nothing to clean up. Nokcandu also removes old logs, automatic restore points older than a month, and leftovers from moved games by itself.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(suggestions) { s in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(s.kind)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                    Text(s.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text((s.kind == .orphanRestorePoints ? "≥ " : "") + Storage.format(s.bytes)).monospacedDigit().foregroundStyle(.secondary)
                if let title = s.actionTitle {
                    Button(title) { act(s) }.disabled(busy)
                }
            }.padding(.vertical, 4)
        }
    }

    func icon(_ k: SpaceSaver.Kind) -> String {
        switch k {
        case .orphanRestorePoints: "clock.arrow.circlepath"
        case .ghostApp: "questionmark.app.dashed"
        case .rollbackCopy: "arrow.uturn.backward.circle"
        case .downloads: "arrow.down.circle"
        case .logs: "doc.text"
        case .exfatOverhead: "externaldrive.badge.exclamationmark"
        }
    }

    func act(_ s: SpaceSaver.Suggestion) {
        let library = model.games
        switch s.kind {
        case .exfatOverhead:
            if let g = library.first(where: { $0.id == s.gameID }) { model.moveSuggestsFilesWithApp = g.id; model.movingGame = g }
        case .orphanRestorePoints:
            let alert = NSAlert()
            alert.messageText = "Delete the " + s.title.prefix(1).lowercased() + s.title.dropFirst() + "?"
            alert.informativeText = "This permanently deletes them (they can't be restored anyway: their app isn't in that folder any more). Games, saves and settings aren't touched."
            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            run {
                guard let o = RestorePoints.orphans(library: library).first(where: { $0.folder == s.url }) else { return "Already gone." }
                do { try RestorePoints.remove(o); return "Deleted \(o.points) restore point(s) for \(o.name)." }
                catch { return error.localizedDescription }
            }
        case .ghostApp:
            run {
                guard GhostApps.find(library: library).contains(s.url) else { return "Already gone." }
                return (try? FileManager.default.trashItem(at: s.url, resultingItemURL: nil)) != nil ? "Moved \(s.url.lastPathComponent) to the Trash." : "Couldn't move it to the Trash."
            }
        case .rollbackCopy:
            run {
                guard let g = library.first(where: { $0.id == s.gameID }) else { return "That app isn't in the library." }
                do { try EngineUpdate.keep(g); return "\(g.name) keeps its new engine; the old copy is gone." }
                catch { return error.localizedDescription }
            }
        case .downloads:
            run { Storage.format(Storage.empty(s.url)) + " freed." }
        case .logs:
            run { "Cleared " + Storage.format(LogRetention.prune(library)) + " of logs." }
        }
    }
}

/// Storage → Drives: each external drive, its format, and the APFS games volumes on it.
struct GamesVolumesBox: View {
    @EnvironmentObject var model: AppModel
    let drives: [GamesVolume.Drive]
    let busy: Bool
    let run: (@escaping @Sendable () -> String) -> Void
    @State private var creatingOn: GamesVolume.Drive?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if drives.isEmpty {
                    Text("No external drive is connected.").foregroundStyle(.secondary)
                }
                ForEach(drives) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "externaldrive")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).bold()
                                Text("\(d.format) · \(Storage.format(d.free)) free · " + (d.holdsApps ? "holds whole games" : "game files only"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !d.holdsApps {
                                Button("Create APFS Games Volume…") { creatingOn = d }.disabled(busy)
                            }
                            Button("Eject") { run { do { try GamesVolume.eject(d.url); return "Ejected \(d.name)." } catch { return error.localizedDescription } } }
                                .disabled(busy)
                                .help("Closes the games volumes stored on this drive first, then ejects it. Quit games and launchers stored on it before ejecting.")
                        }
                        ForEach(d.images) { img in
                            HStack {
                                Image(systemName: "shippingbox").foregroundStyle(.secondary).padding(.leading, 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(img.name)
                                    Text((img.mountPoint != nil ? "Open" : "Not open") + " · " + (img.automatic ? "opens automatically when \(d.name) is connected" : "not opened automatically"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove…") {
                                    let alert = NSAlert()
                                    alert.messageText = "Remove the games volume “\(img.name)”?"
                                    alert.informativeText = "It must not hold any games. It's closed and its image on \(d.name) moves to the Trash; empty the Trash to get the space back."
                                    alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
                                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                                    let library = model.games
                                    run { do { try GamesVolume.remove(img.url, library: library); return "Removed \(img.name) (moved to the Trash)." } catch { return error.localizedDescription } }
                                }.disabled(busy)
                                if !img.automatic || img.mountPoint == nil {
                                    Button(img.automatic ? "Open" : "Use for Games") {
                                        run { do { let f = try GamesVolume.adopt(img.url); return "\(img.name) is ready: games can go in \(f.path)." } catch { return error.localizedDescription } }
                                    }.disabled(busy)
                                }
                            }
                        }
                        if !d.holdsApps && d.images.isEmpty {
                            Text("\(d.name) is \(d.format): it can hold game files, but not whole games, and it stores small files in large blocks. A games volume on it holds whole games (and launchers like Steam or Battle.net) without wasted space, and leaves everything else on the drive as it is.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if d.id != drives.last?.id { Divider() }
                }
            }.padding(6)
        } label: { Label("External Drives", systemImage: "externaldrive.connected.to.line.below").font(.headline) }
        .sheet(item: $creatingOn) { d in CreateGamesVolumeSheet(drive: d) { name, bytes, installHere in
            run {
                do {
                    let folder = try GamesVolume.create(on: d.url, name: name, maxBytes: bytes)
                    if installHere { GameFolders.setInstallFolder(folder) }
                    return "Created \(name) on \(d.name). It opens automatically whenever \(d.name) is connected. Move games there with Move…" + (installHere ? " New games install there." : "")
                } catch { return error.localizedDescription }
            }
        } }
    }
}

struct CreateGamesVolumeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let drive: GamesVolume.Drive
    let create: (String, Int64, Bool) -> Void
    @State private var name = "Nokcandu Games"
    @State private var gigabytes: Double = 0
    @State private var installHere = true

    var maxGB: Double { max(20, Double(drive.free) / 1_000_000_000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create an APFS Games Volume on \(drive.name)").font(.title2.bold())
            Text("Nokcandu makes a growable disk image on \(drive.name). It shows up as its own Mac-formatted drive, only uses the space its games take (up to the limit below), and opens automatically whenever \(drive.name) is connected. Nothing already on \(drive.name) changes.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name)
                VStack(alignment: .leading) {
                    Slider(value: $gigabytes, in: 20...maxGB, step: 10) { Text("Up to") }
                    Text("Up to \(Int(gigabytes)) GB (\(Storage.format(drive.free)) is free on \(drive.name) now). It takes no space until you put games in it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Install new games there", isOn: $installHere)
            }
            Text("Before ejecting \(drive.name), eject the games volume first (or use Eject in Nokcandu, which does both).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create(name, Int64(gigabytes) * 1_000_000_000, installHere); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(GamesVolume.validName(name) == nil)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear { gigabytes = min(maxGB, max(20, (maxGB * 0.5 / 10).rounded() * 10)) }
    }
}
