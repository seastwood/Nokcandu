import SwiftUI
import NokcanduCore

/// The menu bar menu: what's running (with Quit), recent games (with Play), and the way back to the library.
struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var running: [InstalledGame] { model.games.filter { model.isRunning($0) }.sorted { $0.name < $1.name } }
    var recent: [InstalledGame] {
        model.games.filter { !LibraryOrganizer.isLauncher($0) && !model.isRunning($0) }
            .compactMap { g in LibraryOrganizer.lastPlayed(g).map { (g, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
    }

    var body: some View {
        if !running.isEmpty {
            Section("Running") {
                ForEach(running) { g in
                    Button("Quit \(g.name)") { model.requestQuit(g); show() }
                }
            }
        }
        if !recent.isEmpty {
            Section("Recent") {
                ForEach(recent) { g in Button("Play \(g.name)") { model.play(g) } }
            }
        }
        Divider()
        DesktopPadMenu()
        Divider()
        Button("Open Nokcandu") { show() }.keyboardShortcut("o")
        Button("Add a Game…") { model.showInstaller = true; show() }
        Button("Add a Folder of Games…") { show(); model.chooseFolderOfGames() }
        Divider()
        Button("Quit Nokcandu") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Nokcandu" }) { openWindow(id: "library") }
    }
}

enum MenuBarSetting {
    static let key = "menuBarMenu"
    static var on: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}


/// Menu bar: the controller on the Mac, on or off, and which profile.
struct DesktopPadMenu: View {
    @ObservedObject var pad = DesktopPad.shared
    var body: some View {
        Toggle("Controller Profiles", isOn: $pad.enabled)
        Menu(pad.everywhereID.flatMap { id in PadProfiles.profiles().first { $0.id == id }?.name }.map { "Everywhere: \($0)" } ?? "Use a Profile Everywhere") {
            ForEach(PadProfiles.profiles()) { p in
                Toggle(p.name, isOn: Binding(get: { pad.everywhereID == p.id }, set: { pad.everywhereID = $0 ? p.id : nil; if $0 { pad.enabled = true } }))
            }
            if pad.everywhereID != nil { Divider(); Button("Stop") { pad.everywhereID = nil } }
        }
        Toggle("Controller on the Mac", isOn: $pad.on).disabled(!pad.enabled)
        if pad.on && pad.enabled {
            Text(pad.status)
            Menu("Mac Profile") {
                ForEach(PadProfiles.profiles()) { p in
                    Toggle(p.name, isOn: Binding(get: { pad.profileID == p.id }, set: { if $0 { pad.profileID = p.id } }))
                }
            }
        }
    }
}
