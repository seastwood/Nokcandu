import Foundation

/// Installer-added RUNASADMIN flags send games through EA's elevation broker unnecessarily in
/// Wine. Repair live registry values, scoped to registered EA game roots, including after repair.
enum EACompatibility {
    static func stage(_ game: InstalledGame) throws {
        let host = game.hosted.flatMap { GameLibrary.inspect(URL(fileURLWithPath: $0.hostApp)) } ?? game
        guard PCLaunchers.kind(of: host) == .ea,
              let source = NokPaths.bundledResource("nokcandu-ea-compat.exe") else { return }
        let folder = host.prefix.appendingPathComponent("drive_c/nokcandu")
        try NokPaths.ensure(folder)
        let target = folder.appendingPathComponent("nokcandu-ea-compat.exe"), stamp = folder.appendingPathComponent("ea-compat.sha256")
        let want = try Hashing.sha256(file: source)
        if FileManager.default.fileExists(atPath: target.path) {
            let current = try Hashing.sha256(file: target)
            if current == want { return }
            guard (try? String(contentsOf: stamp, encoding: .utf8)) == current else {
                throw NokError("EA's compatibility helper was changed outside Nokcandu. Your copy was kept.")
            }
        }
        try Data(contentsOf: source).write(to: target, options: .atomic)
        try want.write(to: stamp, atomically: true, encoding: .utf8)
    }
    static func block(watch: Bool) -> String {
        let command = #""$SUPPORT/wine/bin/wine" 'C:\nokcandu\nokcandu-ea-compat.exe'"#
        return """
        # Repair only elevation flags on registered EA game programs; originals stay in the registry backup.
        if [ -f "$WINEPREFIX/drive_c/nokcandu/nokcandu-ea-compat.exe" ]; then
         \(command)
         \(watch ? command + " --watch >/dev/null 2>&1 &" : ":")
        fi

        """
    }
}
