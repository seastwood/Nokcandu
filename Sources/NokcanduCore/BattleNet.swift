import Foundation

/// Shared Battle.net: one Battle.net app (its own Wine environment, signed in once) and a small app per
/// Blizzard game that starts it through Battle.net (`Battle.net.exe --exec="launch <code>"`). Games
/// started this way inherit Battle.net's graphics, performance, raw-mouse and extra settings.
public struct BattleNetLink: Codable, Hashable {
    public var hostApp: String      // path of Battle.net.app
    public var uid: String          // Blizzard product uid, e.g. "osi"
    public var code: String         // launch code, e.g. "OSI"
    public var name: String
    public static let fileName = "battlenet-game.json"
    static func url(_ contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu/\(fileName)") }
    static func load(contents: URL) -> BattleNetLink? {
        (try? Data(contentsOf: url(contents))).flatMap { try? JSONDecoder().decode(BattleNetLink.self, from: $0) }
    }
}

public enum BattleNet {
    public struct BlizzardGame: Identifiable, Hashable {
        public var id: String { uid }
        public var uid: String
        public var code: String
        public var name: String
        public var installLocation: String      // Windows path
        public var exe: String?                 // Windows path of the game's .exe (from its uninstall icon)
    }

    /// Battle.net product uids → `--exec="launch …"` codes (unknown ones fall back to the uid in capitals).
    static let codes: [String: String] = [
        "osi": "OSI", "s1": "S1", "s2": "S2", "w3": "W3", "d3": "D3", "fenris": "Fen", "pro": "Pro",
        "hs_beta": "WTCG", "wow": "WoW", "wow_classic": "WoWC", "hero": "Hero", "odin": "ODIN", "viper": "VIPR",
        "lazarus": "LAZR", "zeus": "ZEUS", "fore": "FORE", "auks": "AUKS", "spot": "SPOT", "rtro": "RTRO",
        "w1r": "W1R", "w2r": "W2R", "anbs": "ANBS", "gryphon": "GRY", "aqua": "AQUA",
    ]
    public static func code(for uid: String) -> String { codes[uid.lowercased()] ?? uid.uppercased() }

    /// The Battle.net app: a Nokcandu app whose program is Battle.net (Launcher).exe.
    public static func isHost(_ g: InstalledGame) -> Bool {
        guard let exe = g.custom?.exe.lowercased(), g.battleNet == nil else { return false }
        return exe.hasSuffix("\\battle.net launcher.exe") || exe.hasSuffix("\\battle.net.exe")
    }
    public static func host(in games: [InstalledGame]) -> InstalledGame? { games.first(where: isHost) }

    /// Blizzard games installed in the Battle.net app, from their Windows uninstall entries.
    public static func registeredGames(host: InstalledGame) -> [BlizzardGame] {
        guard let reg = try? String(contentsOf: host.prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return [] }
        var out: [BlizzardGame] = []
        for block in reg.components(separatedBy: "\n\n") where block.contains("CurrentVersion\\\\Uninstall\\\\") {
            func value(_ k: String) -> String? {
                guard let line = block.components(separatedBy: "\n").first(where: { $0.hasPrefix("\"\(k)\"=\"") }) else { return nil }
                return WineRegistry.decode(String(line.dropFirst(k.count + 4).dropLast()))
            }
            guard let un = value("UninstallString"), un.contains("Blizzard Uninstaller"),
                  let m = un.range(of: #"--uid=([A-Za-z0-9_.\-]+)"#, options: .regularExpression) else { continue }
            let uid = String(un[m].dropFirst("--uid=".count))
            guard uid.lowercased() != "battle.net", let name = value("DisplayName") else { continue }
            out.append(BlizzardGame(uid: uid, code: code(for: uid), name: name,
                                    installLocation: value("InstallLocation") ?? "", exe: value("DisplayIcon")))
        }
        return out.sorted { $0.name < $1.name }
    }

    public static func installedGames(host: InstalledGame) -> [BlizzardGame] {
        registeredGames(host: host).filter {
            LauncherInstallation.presence(at: LauncherInstallation.windowsFolder($0.installLocation, prefix: host.prefix)) != .missing
        }
    }

    /// Mac path for a Windows path in the host's environment (any drive letter, via dosdevices).
    public static func unixPath(_ windows: String, prefix: URL) -> URL? {
        guard windows.count >= 3, windows.dropFirst().hasPrefix(":\\") else { return nil }
        let letter = windows.prefix(1).lowercased()
        let link = prefix.appendingPathComponent("dosdevices/\(letter):")
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let base = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : prefix.appendingPathComponent("dosdevices").appendingPathComponent(dest).standardizedFileURL
        let rest = windows.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        return rest.isEmpty ? base : base.appendingPathComponent(rest)
    }

    public static func addedApp(for game: BlizzardGame, host: InstalledGame? = nil, in games: [InstalledGame]) -> InstalledGame? {
        games.first { app in
            guard let link = app.battleNet, link.uid == game.uid, FileManager.default.fileExists(atPath: app.appURL.path) else { return false }
            return host == nil || URL(fileURLWithPath: link.hostApp).resolvingSymlinksInPath() == host!.appURL.resolvingSymlinksInPath()
        }
    }

    /// Creates "<Game>.app" next to the other game apps.
    @discardableResult
    public static func addGame(_ game: BlizzardGame, host: InstalledGame) throws -> URL {
        let fm = FileManager.default
        let name = CustomGames.safeFolderName(game.name)
        let target = try CustomGames.freeAppURL(name)
        let c = target.appendingPathComponent("Contents")
        for d in ["MacOS", "Resources", "SharedSupport/nokcandu", "SharedSupport/Logs"] {
            try fm.createDirectory(at: c.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let link = BattleNetLink(hostApp: host.appURL.path, uid: game.uid, code: game.code, name: game.name)
        try JSONEncoder().encode(link).write(to: BattleNetLink.url(c))
        let launcher = c.appendingPathComponent("MacOS/\(CustomGames.launcherName)")
        try Data(launcherScript(link).utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        var iconFile = ""
        if let exe = game.exe.flatMap({ unixPath($0, prefix: host.prefix) }), fm.fileExists(atPath: exe.path) {
            let work = NokPaths.support.appendingPathComponent("Work/bnet-\(game.uid)")
            defer { try? fm.removeItem(at: work) }
            if PEFile.writeIcns(from: exe, to: c.appendingPathComponent("Resources/AppIcon.icns"), workDir: work) { iconFile = "AppIcon.icns" }
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": CustomGames.launcherName, "CFBundleIconFile": iconFile,
            "CFBundleIdentifier": "local.nokcandu.battlenet.\(game.uid.lowercased())", "CFBundleName": game.name,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0", "LSMinimumSystemVersion": "14.6", "NSBGOnly": "1",
            "NokcanduRecipe": "battlenet-game",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist.merging(AppPrivacy.keys) { a, _ in a }, format: .xml, options: 0)
            .write(to: c.appendingPathComponent("Info.plist"))
        _ = try? Shell.run("/usr/bin/touch", [target.path])
        return target
    }

    /// Rewrites Battle.net game launchers made by an older Nokcandu (they're generated, never hand-edited).
    public static func refreshLaunchers(_ games: [InstalledGame]) {
        for g in games {
            guard let l = g.battleNet else { continue }
            let f = g.appURL.appendingPathComponent("Contents/MacOS/\(CustomGames.launcherName)")
            let want = launcherScript(l)
            guard let current=try? String(contentsOf:f,encoding:.utf8), current != want else { continue }
            // This exact generated-script migration must not replace hand-edited launchers.
            guard WineEnvironment.upgradeExports(current) == want else { continue }
            if (try? Data(want.utf8).write(to: f, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            }
        }
    }

    /// Rewrites game launchers made by an older Nokcandu (skips any launcher edited by hand — saveAll
    /// refuses those), so launcher fixes reach existing games.
    public static func refreshSteamLaunchers(_ games: [InstalledGame]) {
        for g in games {
            guard let c = g.custom, g.battleNet == nil, !isHost(g) || true else { continue }
            if case .launcherRunning = GameLauncher.runState(of: g) { continue }
            let f = g.appURL.appendingPathComponent("Contents/MacOS/\(CustomGames.launcherName)")
            if (try? String(contentsOf: f, encoding: .utf8)) == CustomGames.launcherScript(for: c) { continue }
            try? CustomGames.saveAll(c, to: g, force: false)
        }
    }

    /// "Close Battle.net when its game quits" (on unless the keep-open file exists in the Battle.net app).
    public static func closesWithGame(host: InstalledGame) -> Bool {
        !FileManager.default.fileExists(atPath: keepOpenFile(host).path)
    }
    public static func setClosesWithGame(_ on: Bool, host: InstalledGame) {
        let f = keepOpenFile(host)
        if on { try? FileManager.default.removeItem(at: f) }
        else { try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
               FileManager.default.createFile(atPath: f.path, contents: Data()) }
    }
    static func keepOpenFile(_ host: InstalledGame) -> URL {
        host.appURL.appendingPathComponent("Contents/SharedSupport/nokcandu/keep-open")
    }

    /// Starts Battle.net (with its own settings) if needed, waits until it has signed in, then asks it
    /// to launch the game.
    public static func launcherScript(_ l: BattleNetLink) -> String {
        let q = CustomGames.shellQuote
        return """
        #!/bin/bash
        # Generated by Nokcandu: starts \(l.name.replacingOccurrences(of: "\n", with: " ")) through Battle.net.
        set -euo pipefail
        HOST=\(q(l.hostApp))
        HC="$HOST/Contents"
        SUPPORT="$HC/SharedSupport"
        CODE=\(q(l.code))
        if [ ! -x "$SUPPORT/wine/bin/wine" ]; then echo "Battle.net app not found at $HOST" >&2; exit 1; fi
        if [ "${1:-}" = --check ]; then echo "Launcher check passed: Battle.net is ready to start $CODE."; exit 0; fi
        export WINEPREFIX="$SUPPORT/prefix"
        \(WineEnvironment.exportLine("HC"))
        export WINEDEBUG=-all
        export WINEMSYNC=1
        export PATH="$SUPPORT/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        BNET='C:\\Program Files (x86)\\Battle.net\\Battle.net.exe'
        running() {
         local p; p=$(cat "$SUPPORT/Logs/game.lock/pid" 2>/dev/null || true)
         [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null
        }
        STATE="$SUPPORT/nokcandu"
        GAME=\(q(l.name))
        bnet_up() { local c; c=$(/bin/ps -axo command= 2>/dev/null || true); /usr/bin/grep -qi 'Battle\\.net\\.exe' <<<"$c"; }
        # Is this game (any of its programs, as listed for Dock names) still running?
        game_up() {
         local c exes e
         c=$(/bin/ps -axo command= 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' || true)
         exes=$(/usr/bin/awk -F '\\t' -v n="$GAME" '$2 == n { print $1 }' "$STATE/app-names.tsv" 2>/dev/null || true)
         if [ -n "$exes" ]; then
          while IFS= read -r e; do [ -n "$e" ] && /usr/bin/grep -qF "\\\\$e" <<<"$c" && return 0; done <<<"$exes"
          return 1
         fi
         # Not listed yet: any Windows program that isn't Battle.net's own or Windows'.
         /usr/bin/grep -E '^[a-z]:\\\\' <<<"$c" | /usr/bin/grep -viE '\\\\battle\\.net\\\\|blizzard entertainment|\\\\windows\\\\|\\\\steam\\\\|steamapps' | /usr/bin/grep -q .
        }
        # Battle.net started for this game closes once the game has quit (~30 s with none of its programs).
        watch_game() {
         local seen=0 gone=0
         while bnet_up; do
          if [ ! -f "$STATE/started-for-game" ] || [ -f "$STATE/keep-open" ]; then return 0; fi
          if game_up; then seen=1; gone=0
          elif [ "$seen" = 1 ]; then gone=$((gone + 1)); [ "$gone" -ge 6 ] && break
          fi
          sleep 5
         done
         if [ "$seen" != 1 ] || [ "$gone" -lt 6 ] || [ ! -f "$STATE/started-for-game" ] || [ -f "$STATE/keep-open" ]; then return 0; fi
         echo "nokcandu: $GAME closed; closing Battle.net (it was started for the game) $(date)" >>"$SUPPORT/Logs/launch.log"
         rm -f "$STATE/started-for-game"
         # Like signing out of Windows: programs get to save and exit; anything left is stopped after 30 s.
         "$SUPPORT/wine/bin/wine" wineboot --end-session --force >/dev/null 2>&1 || true
         for _ in $(seq 1 30); do bnet_up || break; sleep 1; done
         bnet_up && "$SUPPORT/wine/bin/wineserver" -k >/dev/null 2>&1 || true
        }
        STARTED=0
        if ! bnet_up; then STARTED=1; mkdir -p "$STATE"; touch "$STATE/started-for-game"; fi
        newest_log() { ls -t "$WINEPREFIX"/drive_c/users/*/AppData/Local/Battle.net/Logs/battle.net-*.log 2>/dev/null | head -n 1 || true; }
        if ! running; then
         STAMP="$(/usr/bin/mktemp -t nokcandu-bnet)"
         /usr/bin/open -g "$HOST"
         # Wait until Battle.net has signed in (up to 5 minutes, so there's time to type a code).
         for _ in $(seq 1 150); do
          sleep 2
          L="$(newest_log)"
          if [ -n "$L" ] && [ "$L" -nt "$STAMP" ] && grep -q "Logged into Battle.net successfully" "$L"; then break; fi
         done
         rm -f "$STAMP"
         sleep 3
        fi
        # (Not via /usr/bin/nohup: macOS strips DYLD_* variables when running system binaries.)
        trap '' HUP
        "$SUPPORT/wine/bin/wine" "$BNET" --in-process-gpu --use-gl=swiftshader --exec="launch $CODE" >/dev/null 2>&1 </dev/null &
        disown $! 2>/dev/null || true
        if [ "$STARTED" = 1 ] && [ ! -f "$STATE/keep-open" ]; then
         ( trap '' HUP; sleep 10; watch_game ) </dev/null >/dev/null 2>&1 &
         disown $! 2>/dev/null || true
        fi
        """
    }
}
