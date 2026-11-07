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
