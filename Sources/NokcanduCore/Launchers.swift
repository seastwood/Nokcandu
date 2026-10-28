import Foundation

/// Other PC launchers set up like Battle.net: one shared launcher app (EA app, Ubisoft Connect), and each
/// game in it gets its own Mac app that opens the launcher and starts the game.
public enum PCLauncher: String, Codable, CaseIterable, Identifiable, Sendable {
    case ea, ubisoft, gogGalaxy, epicLauncher, amazonGames
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ea: "EA app"; case .ubisoft: "Ubisoft Connect"; case .gogGalaxy: "GOG Galaxy"
        case .epicLauncher: "Epic Games Launcher"; case .amazonGames: "Amazon Games"
        }
    }
    /// Optional launchers: their games install without them (through Nokcandu's store clients); set one up
    /// only for its store, friends and community features.
    public var isOptional: Bool { [.gogGalaxy, .epicLauncher, .amazonGames].contains(self) }
    /// The official installers, straight from each company.
    public var setupURL: URL {
        switch self {
        case .ea: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!
        case .ubisoft: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
        case .gogGalaxy: URL(string: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe")!
        case .epicLauncher: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!
        case .amazonGames: URL(string: "https://download.amazongames.com/AmazonGamesSetup.exe")!
        }
    }
    var exeSuffixes: [String] {
        switch self {
        case .ea: ["\\eadesktop.exe", "\\eabackgroundservice.exe"]
        case .ubisoft: ["\\upc.exe", "\\ubisoftconnect.exe", "\\uplay.exe"]
        case .gogGalaxy: ["\\galaxyclient.exe"]
        case .epicLauncher: ["\\epicgameslauncher.exe"]
        case .amazonGames: ["\\amazon games.exe", "\\amazongames.exe"]
        }
    }
    /// Process name pattern (as it appears in `ps`) of the running launcher.
    var processPattern: String {
        switch self {
        case .ea: #"EADesktop\.exe"#; case .ubisoft: #"upc\.exe"#; case .gogGalaxy: #"GalaxyClient\.exe"#
        case .epicLauncher: #"EpicGamesLauncher\.exe"#; case .amazonGames: #"Amazon Games\.exe"#
        }
    }
    var defaultExe: String {
        switch self {
        case .ea: #"C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe"#
        case .ubisoft: #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\upc.exe"#
        case .gogGalaxy: #"C:\Program Files (x86)\GOG Galaxy\GalaxyClient.exe"#
        case .epicLauncher: #"C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#
        case .amazonGames: #"C:\users\crossover\AppData\Local\Amazon Games\App\Amazon Games.exe"#
        }
    }
    /// The store's website, for browsing and buying.
    public var storeURL: URL {
        switch self {
        case .ea: URL(string: "https://www.ea.com/games/library")!; case .ubisoft: URL(string: "https://store.ubisoft.com")!
        case .gogGalaxy: URL(string: "https://www.gog.com")!; case .epicLauncher: URL(string: "https://store.epicgames.com")!
        case .amazonGames: URL(string: "https://gaming.amazon.com")!
        }
    }
}

/// Saved in a launcher game's app: which launcher app and game it starts.
public struct HostedGameLink: Codable, Hashable, Sendable {
    public var hostApp: String
    public var launcher: PCLauncher
    public var id: String            // Ubisoft: game id; EA: install folder name
    public var name: String
    public var exe: String?          // Windows path of the game's program (EA starts it directly)
    public static let fileName = "launcher-game.json"
    static func url(_ contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu/\(fileName)") }
    static func load(contents: URL) -> HostedGameLink? {
        (try? Data(contentsOf: url(contents))).flatMap { try? JSONDecoder().decode(HostedGameLink.self, from: $0) }
    }
}

public enum PCLaunchers {
    public struct HostedGame: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var installLocation: String
        public var exe: String?
    }

    /// Which launcher this app is, if it's an EA app / Ubisoft Connect app made with Nokcandu.
    public static func kind(of g: InstalledGame) -> PCLauncher? {
        guard g.hosted == nil, g.battleNet == nil, let exe = g.custom?.exe.lowercased() else { return nil }
        return PCLauncher.allCases.first { k in k.exeSuffixes.contains { exe.hasSuffix($0) } }
    }

    static func registryBlocks(_ prefix: URL) -> [String] {
        guard let reg = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return [] }
        return reg.components(separatedBy: "\n\n")
    }
    static func value(_ block: String, _ k: String) -> String? {
        guard let line = block.components(separatedBy: "\n").first(where: { $0.hasPrefix("\"\(k)\"=\"") }) else { return nil }
        return String(line.dropFirst(k.count + 4).dropLast()).replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Games installed in the launcher, from what it writes to the Windows registry.
    public static func installedGames(_ kind: PCLauncher, host: InstalledGame) -> [HostedGame] {
        var out: [HostedGame] = []
        for block in registryBlocks(host.prefix) {
            guard let header = block.components(separatedBy: "\n").first(where: { $0.hasPrefix("[") }) else { continue }
            switch kind {
            case .ubisoft:
                // [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\635] "InstallDir"="C:/…/games/Far Cry 3/"
                guard let r = header.range(of: #"Ubisoft\\\\Launcher\\\\Installs\\\\([0-9]+)\]"#, options: .regularExpression),
                      let dir = value(block, "InstallDir") else { continue }
                let id = header[r].components(separatedBy: "\\\\").last!.dropLast()
                let clean = dir.replacingOccurrences(of: "/", with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
                let name = clean.components(separatedBy: "\\").last ?? "Ubisoft game \(id)"
                out.append(HostedGame(id: String(id), name: name, installLocation: clean, exe: nil))
            case .gogGalaxy, .epicLauncher, .amazonGames:
                continue     // their games install through Nokcandu's store clients instead
            case .ea:
                guard header.contains("CurrentVersion\\\\Uninstall\\\\"), value(block, "Publisher")?.contains("Electronic Arts") == true,
                      let name = value(block, "DisplayName"), !name.lowercased().hasPrefix("ea app"), name != "EA",
                      let loc = value(block, "InstallLocation"), !loc.lowercased().contains("\\ea desktop") else { continue }
                var exe = value(block, "DisplayIcon")
                if let e = exe, let comma = e.range(of: ",", options: .backwards), e[comma.upperBound...].allSatisfy(\.isNumber) { exe = String(e[..<comma.lowerBound]) }
                exe = exe?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if exe?.lowercased().hasSuffix(".exe") != true { exe = nil }
                let id = loc.trimmingCharacters(in: CharacterSet(charactersIn: "\\")).components(separatedBy: "\\").last ?? name
                out.append(HostedGame(id: id, name: name, installLocation: loc, exe: exe))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }

    public static func addedApp(for game: HostedGame, kind: PCLauncher, in games: [InstalledGame]) -> InstalledGame? {
        games.first { $0.hosted?.launcher == kind && $0.hosted?.id == game.id }
    }

    /// Creates "<Game>.app" that starts the game through the launcher app.
    @discardableResult
    public static func addGame(_ game: HostedGame, kind: PCLauncher, host: InstalledGame) throws -> URL {
        let fm = FileManager.default
        let target = try CustomGames.freeAppURL(CustomGames.safeFolderName(game.name))
        let c = target.appendingPathComponent("Contents")
        for d in ["MacOS", "Resources", "SharedSupport/nokcandu", "SharedSupport/Logs"] {
            try fm.createDirectory(at: c.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let link = HostedGameLink(hostApp: host.appURL.path, launcher: kind, id: game.id, name: game.name, exe: game.exe)
        try JSONEncoder().encode(link).write(to: HostedGameLink.url(c))
        let launcher = c.appendingPathComponent("MacOS/\(CustomGames.launcherName)")
        try Data(launcherScript(link).utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        var iconFile = ""
        var iconSource = game.exe.flatMap { BattleNet.unixPath($0, prefix: host.prefix) }
        if iconSource == nil, let dir = BattleNet.unixPath(game.installLocation, prefix: host.prefix) {
            iconSource = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
                .filter { $0.pathExtension.lowercased() == "exe" }
                .max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        if let exe = iconSource, fm.fileExists(atPath: exe.path) {
            let work = NokPaths.support.appendingPathComponent("Work/\(kind.rawValue)-\(CustomGames.slug(game.id))")
            defer { try? fm.removeItem(at: work) }
            if PEFile.writeIcns(from: exe, to: c.appendingPathComponent("Resources/AppIcon.icns"), workDir: work) { iconFile = "AppIcon.icns" }
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": CustomGames.launcherName, "CFBundleIconFile": iconFile,
            "CFBundleIdentifier": "local.nokcandu.\(kind.rawValue).\(CustomGames.slug(game.id))", "CFBundleName": game.name,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0", "LSMinimumSystemVersion": "14.6", "NSBGOnly": "1",
            "NokcanduRecipe": "\(kind.rawValue)-game",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist.merging(AppPrivacy.keys) { a, _ in a }, format: .xml, options: 0)
            .write(to: c.appendingPathComponent("Info.plist"))
        _ = try? Shell.run("/usr/bin/touch", [target.path])
        return target
    }

    /// Opens the launcher app (signed in) if it isn't running, waits for it, then starts the game.
    public static func launcherScript(_ l: HostedGameLink) -> String {
        launcherScript(l, legacyProcessDetection: false)
    }
    static func launcherScript(_ l: HostedGameLink, legacyProcessDetection: Bool) -> String {
        let q = CustomGames.shellQuote
        let start: String
        switch l.launcher {
        case .ubisoft:
            start = #""$SUPPORT/wine/bin/wine" "$LAUNCHER_EXE" "uplay://launch/"# + l.id + #"/0""#
        case .gogGalaxy, .epicLauncher, .amazonGames:
            start = #""$SUPPORT/wine/bin/wine" "$LAUNCHER_EXE""#
        case .ea:
            start = l.exe.map { #""$SUPPORT/wine/bin/wine" "# + q($0) } ?? #""$SUPPORT/wine/bin/wine" "$LAUNCHER_EXE""#
        }
        return """
        #!/bin/bash
        # Generated by Nokcandu: starts \(l.name.replacingOccurrences(of: "\n", with: " ")) through \(l.launcher.title).
        set -euo pipefail
        HOST=\(q(l.hostApp))
        HC="$HOST/Contents"
        SUPPORT="$HC/SharedSupport"
        if [ ! -x "$SUPPORT/wine/bin/wine" ]; then echo "\(l.launcher.title) app not found at $HOST" >&2; exit 1; fi
        if [ "${1:-}" = --check ]; then echo "Launcher check passed: \(l.launcher.title) is ready."; exit 0; fi
        export WINEPREFIX="$SUPPORT/prefix"
        export DYLD_FALLBACK_LIBRARY_PATH="$HC/Frameworks:/usr/lib"
        export WINEDEBUG=-all
        export WINEMSYNC=1
        export PATH="$SUPPORT/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        LAUNCHER_EXE=\(q(l.launcher.defaultExe))
        \(hostRunningCheck(l, legacy: legacyProcessDetection))
        mkdir -p "$SUPPORT/Logs"
        if ! up; then
         /usr/bin/open -g "$HOST"
         # Give it time to start and sign in (up to 3 minutes, so there's time to type a code).
         for _ in $(seq 1 90); do sleep 2; up && break; done
         sleep 20
        fi
        echo "nokcandu: starting \(l.name.replacingOccurrences(of: "\"", with: "")) via \(l.launcher.title) $(date)" >>"$SUPPORT/Logs/launch.log"
        trap '' HUP
        \(start) >/dev/null 2>&1 </dev/null &
        disown $! 2>/dev/null || true
        exit 0

        """
    }

    static func hostRunningCheck(_ l: HostedGameLink, legacy: Bool = false) -> String {
        if legacy { return "up() { /bin/ps -axo command= 2>/dev/null | /usr/bin/grep -qiE \(CustomGames.shellQuote(l.launcher.processPattern)); }" }
        return """
        up() {
         local launcher_pid
         launcher_pid=$(cat "$SUPPORT/Logs/game.lock/pid" 2>/dev/null || true)
         [[ "$launcher_pid" =~ ^[0-9]+$ ]] && [ "$launcher_pid" -gt 1 ] && kill -0 "$launcher_pid" 2>/dev/null || return 1
         /bin/ps -p "$launcher_pid" -o command= 2>/dev/null | /usr/bin/grep -Fq -- "$HC/MacOS/"
        }
        """
    }

    /// Rewrites launcher-game launchers made by an older Nokcandu.
    public static func refreshLaunchers(_ games: [InstalledGame]) {
        for g in games {
            guard let l = g.hosted else { continue }
            let f = g.appURL.appendingPathComponent("Contents/MacOS/\(CustomGames.launcherName)")
            let want = launcherScript(l)
            guard let current = try? String(contentsOf: f, encoding: .utf8), current != want,
                  current == launcherScript(l, legacyProcessDetection: true) else { continue }
            if (try? Data(want.utf8).write(to: f, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            }
        }
    }

    /// Battle.net's official installer (Blizzard's own download link).
    public static let battleNetSetupURL = URL(string: "https://downloader.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live")!

    public static func downloadBattleNetSetup() async throws -> URL {
        try NokPaths.ensure(NokPaths.downloads)
        let dest = NokPaths.downloads.appendingPathComponent("Battle.net-Setup.exe")
        let (tmp, resp) = try await URLSession.shared.download(from: battleNetSetupURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NokError("Couldn't download the Battle.net installer.") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Downloads the launcher's official installer (for "Set up EA app / Ubisoft Connect").
    public static func downloadSetup(_ kind: PCLauncher) async throws -> URL {
        try NokPaths.ensure(NokPaths.downloads)
        let dest = NokPaths.downloads.appendingPathComponent(kind.setupURL.lastPathComponent)
        let (tmp, resp) = try await URLSession.shared.download(from: kind.setupURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NokError("Couldn't download the \(kind.title) installer.") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
