import Foundation

/// Hands Battle.net web links (battlenet:// and blizzard://) from macOS back to Battle.net running in Wine.
///
/// Battle.net's browser sign-in (passkeys, Google/Apple accounts) finishes in your Mac browser, which then
/// opens a battlenet:// link to return to the app. Inside Wine that link is registered, but macOS doesn't know
/// it, so the browser says "return to your app" and nothing happens. Nokcandu registers those two link types
/// with macOS and passes them to Battle.net exactly as Windows would (`Battle.net.exe --uri="<link>"`).
public enum BattleNetBridge {
    public static let schemes = ["battlenet", "blizzard"]
    static let exeRel = "SharedSupport/prefix/drive_c/Program Files (x86)/Battle.net/Battle.net.exe"
    static let exeWin = #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#

    /// Game apps whose Windows environment has Battle.net installed.
    public static func hosts(in games: [InstalledGame]) -> [InstalledGame] {
        games.filter { FileManager.default.fileExists(atPath: $0.contents.appendingPathComponent(exeRel).path) }
    }

    public static func canHandle(_ url: URL) -> Bool { schemes.contains(url.scheme?.lowercased() ?? "") }

    /// Forwards the link. Returns the app it went to.
    @discardableResult
    public static func forward(_ url: URL, games: [InstalledGame]) throws -> InstalledGame {
        guard canHandle(url) else { throw NokError("Not a Battle.net link.") }
        let candidates = hosts(in: games)
        guard let host = candidates.first(where: { if case .launcherRunning = GameLauncher.runState(of: $0) { return true }; return false })
                ?? candidates.first else {
            throw NokError("A Battle.net link arrived, but no game app has Battle.net installed.")
        }
        // Passed as one argument, same form as Battle.net's own Windows registration: --uri="%1"
        try WineTools.run([exeWin, "--uri=\(url.absoluteString)"], for: host)
        return host
    }
}
