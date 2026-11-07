import AppKit
import NokcanduCore

/// Keys for Mac games: while a Mac game in the library is the front app, Nokcandu applies its keys (the same
/// macOS keyboard remapping Windows games use) and puts the keyboard back when another app comes to the front.
@MainActor
final class MacGameKeys {
    static let shared = MacGameKeys()
    private var observer: NSObjectProtocol?
    private var games: [NativeGame] = []
    private var active = false
    private let queue = DispatchQueue(label: "nokcandu.macgamekeys")

    func start(games: [InstalledGame]) {
        update(games)
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL
            MainActor.assumeIsolated { self?.frontChanged(app) }
        }
        frontChanged(NSWorkspace.shared.frontmostApplication?.bundleURL)
    }
    func update(_ library: [InstalledGame]) { games = library.compactMap(\.native) }

    private func frontChanged(_ app: URL?) {
        let game = app.flatMap { a in games.first { NokPaths.sameApp($0.appPath, a) } }
        let wasActive = active
        queue.async { [weak self] in
            var applied = false
            if let game { applied = KeyRemap.applyForMacGame(game) }
            if !applied && wasActive { KeyRemap.restoreAfterMacGame() }
            DispatchQueue.main.async { self?.active = applied }
        }
    }

    func stop() { if active { KeyRemap.restoreAfterMacGame(); active = false } }
}
