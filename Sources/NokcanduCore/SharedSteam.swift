import Foundation
#if canImport(Security)
import Security
#endif

/// One shared Windows Steam for every Steam game that needs Steam running.
///
/// `Steam.app` (in the Sikarugir folder) owns the only Wine prefix with Steam installed and signed in.
/// Each Steam game gets a small Mac app of its own (icon + Play) whose launcher asks the shared Steam
/// to start the game. The graphics mode is chosen when Steam starts, so if Steam is already running in
/// another mode the helper offers to restart Steam instead of silently launching in the wrong mode.
public enum SharedSteam {
    public static let appName = "Steam.app"
    public static let hostLauncher = "steam-launcher"
    public static let helperName = "nokcandu-steam"
    public static let hostMarker = "steam-host.json"
    public static let recipeID = "steam-host"
    static let steamRel = "SharedSupport/prefix/drive_c/Program Files (x86)/Steam"

    public static var appURL: URL { NokPaths.gameAppsFolder.appendingPathComponent(appName) }
    public static var contents: URL { appURL.appendingPathComponent("Contents") }
    public static var steamDir: URL { contents.appendingPathComponent(steamRel) }
    public static var helper: URL { contents.appendingPathComponent("Resources/\(helperName)") }

    public static var isSetUp: Bool {
        FileManager.default.isExecutableFile(atPath: helper.path) &&
        FileManager.default.fileExists(atPath: steamDir.appendingPathComponent("steam.exe").path)
    }

    public static func isHost(contents: URL) -> Bool {
        FileManager.default.fileExists(atPath: contents.appendingPathComponent("SharedSupport/nokcandu/\(hostMarker)").path)
    }

    /// Steam started through the helper is alive (its lock pid is running).
    public static var isRunning: Bool {
        let pidFile = contents.appendingPathComponent("SharedSupport/Logs/steam.lock/pid")
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    public static var runningMode: GraphicsPreset? {
        guard isRunning else { return nil }
        return (try? String(contentsOf: contents.appendingPathComponent("SharedSupport/nokcandu/running-mode"), encoding: .utf8))
            .flatMap { GraphicsPreset(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: Scripts

    /// The helper inside Steam.app. All Steam starts go through it.
    public static func helperScript() -> String {
        var modes = ""
        for p in GraphicsPreset.allCases {
            modes += " \(p.rawValue))\n"
            for line in p.launcherExports { modes += "  \(line)\n" }
            modes += "  ;;\n"
        }
        return HelperPatch.scopeWineLibrary("""
        #!/bin/bash
        # Nokcandu shared Steam helper. Usage:
        #   nokcandu-steam [--mode <graphics>] [--applaunch <AppID>] [--url steam://…] [--restart-steam] [--no-restart] [--status] [--check] [--shutdown]
        set -euo pipefail
        CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
        SUPPORT="$CONTENTS/SharedSupport"
        export WINEPREFIX="$SUPPORT/prefix"
        export DYLD_FALLBACK_LIBRARY_PATH="$CONTENTS/Frameworks:/usr/lib"
        export WINEDEBUG=-all
        export WINEMSYNC=1
        export PATH="$SUPPORT/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        # Nokcandu's helper library: real app names in the Dock, and raw mouse for aiming when it's switched on.
        if [ -f "$SUPPORT/nokcandu/nokcandu-rawmouse.dylib" ]; then
         export DYLD_INSERT_LIBRARIES="$SUPPORT/nokcandu/nokcandu-rawmouse.dylib"
         export NOKCANDU_APP_NAMES="$SUPPORT/nokcandu/app-names.tsv"
        fi
        if [ -f "$SUPPORT/nokcandu/raw-mouse" ] && [ -f "$SUPPORT/nokcandu/nokcandu-rawmouse.dylib" ]; then
         export NOKCANDU_RAW_MOUSE_SCALE="$(head -n 1 "$SUPPORT/nokcandu/raw-mouse")"
         [ -f "$SUPPORT/nokcandu/raw-mouse-debug" ] && export NOKCANDU_RAW_MOUSE_DEBUG=1
         [ "$(/usr/bin/sed -n 2p "$SUPPORT/nokcandu/raw-mouse")" = smooth ] && export NOKCANDU_RAW_MOUSE_SMOOTH=1
        fi
        WINE="$SUPPORT/wine/bin/wine"
        STEAM_EXE='C:\\Program Files (x86)\\Steam\\steam.exe'
        STEAM_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
        STATE="$SUPPORT/nokcandu"
        LOG_DIR="$SUPPORT/Logs"
        MODE="$(cat "$STATE/default-mode" 2>/dev/null || echo dx9)"
        APP=""; URL=""; CHECK=0; RESTART=0; SHUTDOWN=0; STATUS=0; NORESTART=0; EXTRA=()
        while [ $# -gt 0 ]; do
         case "$1" in
          --mode) MODE="${2:-dx9}"; shift 2 ;;
          --applaunch) APP="${2:-}"; shift 2 ;;
          --url) URL="${2:-}"; shift 2 ;;
          --check) CHECK=1; shift ;;
          --restart-steam) RESTART=1; shift ;;
          --no-restart) NORESTART=1; shift ;;
          --status) STATUS=1; shift ;;
          --shutdown) SHUTDOWN=1; shift ;;
          --) shift; EXTRA=("$@"); break ;;
          *) shift ;;
         esac
        done
        [[ -z "$APP" || "$APP" =~ ^[0-9]+$ ]]
        case "$MODE" in
        \(modes) *) echo "Unknown graphics mode: $MODE" >&2; exit 2 ;;
        esac
        # Performance switches set in Nokcandu (FPS counter, vsync, frame limit).
        [ -f "$SUPPORT/nokcandu/perf.env" ] && . "$SUPPORT/nokcandu/perf.env"
        [ -x "$WINE" ]
        [ -f "$STEAM_DIR/steam.exe" ]
        installed() {
         local m="$STEAM_DIR/steamapps/appmanifest_$1.acf" f
         [ -f "$m" ] || return 1
         f=$(grep -m1 '"StateFlags"' "$m" | grep -o '[0-9][0-9]*' | tail -1)
         [ -n "$f" ] && (( f & 4 ))
        }
        if [ "$CHECK" = 1 ]; then
         if [ -n "$APP" ] && ! installed "$APP"; then echo "Steam is ready, but app $APP isn't installed in Steam yet." >&2; exit 3; fi
         printf 'Launcher check passed: shared Steam%s is ready.\\n' "${APP:+ and app $APP}"
         exit 0
        fi
        mkdir -p "$STATE" "$LOG_DIR"
        running() {
         local pid; pid=$(cat "$LOG_DIR/steam.lock/pid" 2>/dev/null || true)
         [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
         # A stale lock (Steam quit, or the number now belongs to another program) doesn't count.
         /bin/ps -p "$pid" -o command= 2>/dev/null | /usr/bin/grep -qiE 'wine|steam' || return 1
         ! /usr/bin/tail -n 3 "$LOG_DIR/steam.log" 2>/dev/null | /usr/bin/grep -q '] Shutdown'
        }
        stop_steam() {
         "$WINE" "$STEAM_EXE" -shutdown >/dev/null 2>&1 || true
         for _ in $(seq 1 90); do running || break; sleep 1; done
         "$SUPPORT/wine/bin/wineserver" -w >/dev/null 2>&1 || true
        }
        # Steam started for a game closes with that game (once no Steam game is running for ~30 s), so the
        # next game can start Steam with its own graphics settings. Steam opened by itself stays open.
        watch_game() {
         local pid seen=0 gone=0 cmds
         sleep 5
         pid=$(cat "$LOG_DIR/steam.lock/pid" 2>/dev/null || true)
         while running && [ "$(cat "$LOG_DIR/steam.lock/pid" 2>/dev/null || true)" = "$pid" ]; do
          if [ ! -f "$STATE/started-for-game" ] || [ -f "$STATE/keep-steam-open" ]; then return 0; fi
          cmds=$(/bin/ps -axo command= 2>/dev/null || true)
          if /usr/bin/grep -qiE 'steamapps[\\/]common' <<<"$cmds"; then seen=1; gone=0
          elif [ "$seen" = 1 ]; then gone=$((gone + 1)); [ "$gone" -ge 6 ] && break
          fi
          sleep 5
         done
         if [ "$seen" != 1 ] || [ "$gone" -lt 6 ] || [ ! -f "$STATE/started-for-game" ] || [ -f "$STATE/keep-steam-open" ]; then return 0; fi
         echo "== $(date) the game closed; closing Steam (it was started for the game)" >>"$LOG_DIR/steam.log"
         rm -f "$STATE/started-for-game"
         stop_steam
        }
        if [ "$SHUTDOWN" = 1 ]; then running && stop_steam; rm -f "$STATE/started-for-game"; exit 0; fi
        PASS=()
        [ -n "$APP" ] && PASS+=(-applaunch "$APP" ${EXTRA[@]+"${EXTRA[@]}"})
        [ -n "$URL" ] && PASS+=("$URL")
        # What Steam's Wine was started with: graphics mode, Performance and Mouse settings, helper library.
        # A game started later restarts Steam (after asking) when any of it changed since.
        config_id() {
         # (Files that don't exist are simply left out — a missing one must never stop Steam from starting.)
         { echo "$MODE"; cat "$STATE/perf.env" "$STATE/raw-mouse-debug" 2>/dev/null || true; if [ -f "$STATE/steam-gpu" ]; then echo gpu; fi
           /sbin/md5 -q "$STATE/nokcandu-rawmouse.dylib" 2>/dev/null || true; } | /sbin/md5 -q
        }
        # --status: what starting this game would do (Nokcandu asks about restarting in its own window).
        if [ "$STATUS" = 1 ]; then
         if ! running; then echo stopped
         else
          CURRENT="$(cat "$STATE/running-mode" 2>/dev/null || true)"
          if [ "$CURRENT" != "$MODE" ]; then echo "mode $CURRENT"
          elif [ "$(cat "$STATE/running-config" 2>/dev/null || true)" != "$(config_id)" ]; then echo changed
          else echo same; fi
         fi
         exit 0
        fi
        if running; then
         CURRENT="$(cat "$STATE/running-mode" 2>/dev/null || true)"
         if [ -n "$APP" ] && [ "$CURRENT" = "$MODE" ] && [ "$(cat "$STATE/running-config" 2>/dev/null || true)" != "$(config_id)" ]; then
          CURRENT="changed"
         fi
         # Nokcandu already asked and the answer was to keep Steam as it is.
         if [ "$NORESTART" = 1 ]; then
          "$WINE" "$STEAM_EXE" ${PASS[@]+"${PASS[@]}"} >/dev/null 2>&1 &
          exit 0
         fi
         # Opening Steam itself while it runs for a game: you're using Steam now, so it stays open.
         [ -z "$APP" ] && [ -z "$URL" ] && rm -f "$STATE/started-for-game"
         if [ "$CURRENT" = "$MODE" ] || [ -z "$APP" ]; then
          # Hand the request to the Steam that's already running.
          # (with no request this just brings the running Steam's window forward)
          "$WINE" "$STEAM_EXE" ${PASS[@]+"${PASS[@]}"} >/dev/null 2>&1 &
          exit 0
         fi
         if [ "$RESTART" != 1 ]; then
          GAMES=""
          /usr/bin/grep -qiE 'steamapps[\\/]common' <<<"$(/bin/ps -axo command= 2>/dev/null || true)" && GAMES=" The Steam game that's running now will close."
          if [ "$CURRENT" = changed ]; then
           MSG="Steam is running with settings from before your last change in Nokcandu (graphics, performance or mouse). Restart Steam so this game uses the current ones?$GAMES"
          else
           MSG="Steam is running with different graphics settings than this game uses. Restart Steam to play it?$GAMES"
          fi
          ANSWER=$(/usr/bin/osascript -e "button returned of (display dialog \"$MSG\" buttons {\"Cancel\", \"Play Without Restarting\", \"Restart Steam\"} default button 3 with title \"Nokcandu\" with icon caution)" 2>/dev/null || echo Cancel)
          if [ "$ANSWER" = "Play Without Restarting" ]; then
           "$WINE" "$STEAM_EXE" ${PASS[@]+"${PASS[@]}"} >/dev/null 2>&1 &
           exit 0
          fi
          [ "$ANSWER" = "Restart Steam" ] || exit 0
         fi
         stop_steam
        fi
        # Start Steam (single instance) with this mode, detached: the calling app returns right away and
        # the lock records Steam's own process, so any game app can be opened again while Steam keeps running.
        LOCK="$LOG_DIR/steam.lock"
        if ! mkdir "$LOCK" 2>/dev/null; then
         running && exit 0
         rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || exit 0; mkdir "$LOCK"
        fi
        echo "$MODE" > "$STATE/running-mode"
        config_id > "$STATE/running-config"
        if [ -n "$APP" ]; then touch "$STATE/started-for-game"; else rm -f "$STATE/started-for-game"; fi
        [ -f "$LOG_DIR/steam.log" ] && [ "$(stat -f %z "$LOG_DIR/steam.log")" -gt 5000000 ] && mv -f "$LOG_DIR/steam.log" "$LOG_DIR/steam.previous.log"
        echo "== $(date) mode=$MODE app=${APP:-none}" >>"$LOG_DIR/steam.log"
        cd "$STEAM_DIR"
        # (Not via /usr/bin/nohup: macOS strips DYLD_* variables when running system binaries, and Wine needs them.)
        trap '' HUP
        # Steam's browser draws in software unless GPU drawing was switched on in Nokcandu (Steam's page).
        STEAM_FLAGS=(\(CustomGames.steamWineFlags))
        if [ -f "$STATE/steam-gpu" ]; then STEAM_FLAGS=(-no-cef-sandbox); fi
        echo "nokcandu: Steam window drawing: $([ -f "$STATE/steam-gpu" ] && echo GPU || echo software)" >>"$LOG_DIR/steam.log"
        "$WINE" "$STEAM_EXE" "${STEAM_FLAGS[@]}" ${PASS[@]+"${PASS[@]}"} > >(\(CustomGames.logFilter) >>"$LOG_DIR/steam.log") 2>&1 </dev/null &
        echo $! > "$LOCK/pid"
        disown $! 2>/dev/null || true
        if [ -n "$APP" ] && [ ! -f "$STATE/keep-steam-open" ]; then
         ( trap '' HUP; watch_game ) </dev/null >/dev/null 2>&1 &
         disown $! 2>/dev/null || true
        fi

        """)
    }

    /// What starting this Steam game would do to the running Steam: nil = nothing to ask; otherwise why
    /// Steam would need a restart (asked in Nokcandu's own window, not a dialog from a background script).
    public static func restartReason(for g: InstalledGame) -> String? {
        let helper = contents.appendingPathComponent("Resources/\(helperName)")
        // An older helper (Steam was running when Nokcandu updated) doesn't know --status and would start the game.
        guard g.usesSharedSteam, let mode = g.custom?.graphics.rawValue,
              (try? String(contentsOf: helper, encoding: .utf8))?.contains("--status)") == true,
              let r = try? Shell.run("/bin/bash", [helper.path, "--status", "--mode", mode], timeout: 20),
              r.ok else { return nil }
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "changed" { return "Steam is running with settings from before your last change in Nokcandu (graphics, performance or mouse, or a Nokcandu update)." }
        if out.hasPrefix("mode ") { return "Steam is running with a different graphics mode than \(g.name) uses." }
        return nil
    }

    /// Steam.app's own launcher: opens Steam (its default graphics mode).
    public static func hostLauncherScript() -> String {
        """
        #!/bin/bash
        # Generated by Nokcandu: opens the shared Windows Steam.
        exec "$(cd "$(dirname "$0")/.." && pwd)/Resources/\(helperName)" ${1+"$@"}

        """
    }

    /// A Steam game's own app launcher: hands off to the shared Steam.
    public static func gameLauncherScript(appID: Int, name: String, graphics: GraphicsPreset, steamApp: URL, arguments: [String] = [],
                                          displayPixels: [Int]? = nil) -> String {
        let extra = arguments.isEmpty ? "" : " -- " + arguments.map(CustomGames.shellQuote).joined(separator: " ")
        return """
        #!/bin/bash
        # Generated by Nokcandu: \(name.replacingOccurrences(of: "\n", with: " ")) (Steam app \(appID)) through the shared Steam app.
        # Settings: Contents/SharedSupport/nokcandu/game.json — change them in Nokcandu, not here.
        set -euo pipefail
        STEAM_APP=\(CustomGames.shellQuote(steamApp.path))
        [ -d "$STEAM_APP" ] || STEAM_APP="$(cd "$(dirname "$0")/../../.." && pwd)/\(appName)"   # moved together with the game apps
        HELPER="$STEAM_APP/Contents/Resources/\(helperName)"
        if [ ! -x "$HELPER" ]; then
         /usr/bin/osascript -e 'display dialog "This game needs the shared Steam app, which is missing. Set it up again in Nokcandu." buttons {"OK"} with title "Nokcandu" with icon stop' >/dev/null 2>&1 || true
         exit 1
        fi
        if [ "${1:-}" = --check ]; then exec "$HELPER" --check --applaunch \(appID); fi
        \(appID == 730 && arguments.contains("+engine_low_latency_sleep_after_client_tick") ? """
        # Low-latency aiming: CS2 resets its video settings after a crash, so keep its vsync off every start.
        for f in "$STEAM_APP/Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Steam/userdata/"*/730/local/cfg/cs2_video.txt; do
         [ -f "$f" ] && /usr/bin/sed -i '' -E 's/("setting\\.mat_vsync"[[:space:]]+")1"/\\10"/' "$f" || true
        done

        """ : "")\(GameDisplay.launcherLines(displayPixels, tool: #""$STEAM_APP/Contents/SharedSupport/nokcandu/screen-size""#,
                                     log: #""$STEAM_APP/Contents/SharedSupport/Logs/display.log""#, pattern: GameDisplay.steamGamePattern))exec "$HELPER" --mode \(graphics.rawValue) --applaunch \(appID) ${1+"$@"}\(extra)

        """
    }

    // MARK: Steam data (read-only)

    public struct Account: Equatable { public var steamID64: String; public var accountName: String; public var personaName: String }

    public static func accounts() -> [Account] {
        guard let t = try? String(contentsOf: steamDir.appendingPathComponent("config/loginusers.vdf"), encoding: .utf8),
              let n = try? VDF.parse(t), let users = n["users"] else { return [] }
        let list = users.items.map { (id, u) -> (Account, Bool) in
            (Account(steamID64: id, accountName: u["AccountName"]?.string ?? "", personaName: u["PersonaName"]?.string ?? ""),
             u["MostRecent"]?.string == "1")
        }
        return list.sorted { $0.1 && !$1.1 }.map(\.0)
    }

    public struct LibraryGame: Identifiable, Hashable, Codable {
        public var id: Int { appID }
        public var appID: Int
        public var name: String
        public var installed: Bool
        public var installDir: String?
        public var sizeOnDisk: Int64?
        public var playtimeMinutes: Int?
        public var iconURL: URL?
        public var owned: Bool
        /// The Steam library folder it's installed in (Mac path).
        public var library: URL?
        /// Steam's state flags from its install record (appmanifest): downloading, paused, installed…
        public var stateFlags: Int?
        /// Steam's download counters from the install record (for a percentage while downloading).
        public var bytesDownloaded: Int64?
        public var bytesToDownload: Int64?
        public var downloadFraction: Double? {
            guard download != nil, let d = bytesDownloaded, let t = bytesToDownload, t > 0 else { return nil }
            return min(1, Double(d) / Double(t))
        }

        public enum Download: Equatable { case downloading, paused, queued }
        /// What Steam is doing with a game that has an install record but isn't fully installed.
        public var download: Download? {
            guard let f = stateFlags, !installed || f & 0x100 != 0 else { return nil }
            // UpdateRunning 0x100, AddingFiles 0x40000, Preallocating 0x80000, Downloading 0x100000, Staging 0x200000, Committing 0x400000
            if f & (0x100 | 0x40000 | 0x80000 | 0x100000 | 0x200000 | 0x400000) != 0 { return .downloading }
            if f & 0x200 != 0 { return .paused }                 // UpdatePaused
            return installed ? nil : .queued
        }
        /// The game's own folder (steamapps/common/<installdir>) in its library.
        public var folder: URL? {
            guard let dir = installDir, !dir.isEmpty, dir != ".", dir != "..", !dir.contains("/"), !dir.contains("\\"), !dir.contains("\0") else { return nil }
            return (library ?? SharedSteam.steamDir).appendingPathComponent("steamapps/common/\(dir)")
        }

        public init(appID: Int, name: String, installed: Bool, installDir: String?, sizeOnDisk: Int64?,
                    playtimeMinutes: Int?, iconURL: URL?, owned: Bool) {
            self.appID = appID; self.name = name; self.installed = installed; self.installDir = installDir
            self.sizeOnDisk = sizeOnDisk; self.playtimeMinutes = playtimeMinutes; self.iconURL = iconURL; self.owned = owned
        }
    }

    /// Steam library folders (Mac paths): the default one plus any added in Steam (Settings → Storage),
    /// e.g. D:\SteamLibrary on an external drive. Missing drives are skipped.
    public static func libraryFolders() -> [URL] {
        var out = [steamDir]
        let vdf = steamDir.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let t = try? String(contentsOf: vdf, encoding: .utf8), let root = (try? VDF.parse(t))?["libraryfolders"] {
            for (_, lib) in root.items {
                guard let win = lib["path"]?.string, let u = BattleNet.unixPath(win, prefix: contents.appendingPathComponent("SharedSupport/prefix")),
                      u.standardizedFileURL.path != steamDir.standardizedFileURL.path,
                      FileManager.default.fileExists(atPath: u.appendingPathComponent("steamapps").path) else { continue }
                out.append(u)
            }
        }
        return out
    }

    /// The drive holding this game's Steam library, when that drive isn't connected. Steam's library list
    /// (libraryfolders.vdf) records which games each library holds, so this works while the library is unplugged.
    public static func offlineDrive(appID: Int) -> String? {
        let vdf = steamDir.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let t = try? String(contentsOf: vdf, encoding: .utf8), let root = (try? VDF.parse(t))?["libraryfolders"] else { return nil }
        for (_, lib) in root.items where lib["apps"]?.items.contains(where: { $0.0 == String(appID) }) == true {
            guard let win = lib["path"]?.string, let u = BattleNet.unixPath(win, prefix: contents.appendingPathComponent("SharedSupport/prefix")),
                  LauncherInstallation.presence(at: u) == .offline else { continue }
            return Storage.driveName(u)
        }
        return nil
    }

    /// Games installed in the shared Steam (appmanifest_*.acf in every library folder).
    public static func installedGames() -> [LibraryGame] { installedGames(in: libraryFolders()) }
    static func installedGames(in libraries: [URL]) -> [LibraryGame] {
        registeredGames(in: libraries).compactMap { value in
            var game = value
            let presence = LauncherInstallation.presence(at: game.folder)
            if presence == .missing && game.installed { return nil }
            game.installed = game.installed && presence == .present
            return game
        }
    }
    static func registeredGames(in libraries: [URL]) -> [LibraryGame] {
        var seen = Set<Int>()
        return libraries.flatMap { lib -> [LibraryGame] in
            let apps = lib.appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []
            return files.compactMap { f -> LibraryGame? in
                guard f.hasPrefix("appmanifest_"), f.hasSuffix(".acf"),
                      let t = try? String(contentsOf: apps.appendingPathComponent(f), encoding: .utf8),
                      let s = (try? VDF.parse(t))?["AppState"], let id = s["appid"]?.string.flatMap(Int.init) else { return nil }
                if f != "appmanifest_\(id).acf" || id == 228980 || seen.contains(id) { return nil }   // Steamworks Common Redistributables
                seen.insert(id)
                let flags = s["StateFlags"]?.string.flatMap(Int.init) ?? 0
                var g = LibraryGame(appID: id, name: s["name"]?.string ?? "App \(id)", installed: flags & 4 != 0,
                                    installDir: s["installdir"]?.string, sizeOnDisk: s["SizeOnDisk"]?.string.flatMap(Int64.init),
                                    playtimeMinutes: nil, iconURL: nil, owned: true)
                g.library = lib
                g.stateFlags = flags
                g.bytesDownloaded = s["BytesDownloaded"]?.string.flatMap(Int64.init)
                g.bytesToDownload = s["BytesToDownload"]?.string.flatMap(Int64.init)
                return g
            }
        }
    }

    /// Games this Steam has seen for the signed-in account (localconfig "apps"), no network needed.
    public static func recentGames() -> [Int] {
        guard let acct = accounts().first, let id64 = UInt64(acct.steamID64) else { return [] }
        let accountID = id64 &- 76561197960265728
        let url = steamDir.appendingPathComponent("userdata/\(accountID)/config/localconfig.vdf")
        guard let t = try? String(contentsOf: url, encoding: .utf8), let n = try? VDF.parse(t),
              let apps = n["UserLocalConfigStore"]?["Software"]?["Valve"]?["Steam"]?["apps"] else { return [] }
        return apps.items.compactMap { Int($0.0) }
    }

    public struct Collection: Identifiable, Hashable, Codable {
        public var id: String
        public var name: String
        public var appIDs: [Int]
        /// Dynamic collections are defined by filters Steam evaluates itself; Nokcandu can't list their games yet.
        public var dynamic: Bool
    }

    /// The signed-in account's Steam library collections (Favorites, Hidden, and your own), as synced into
    /// this Steam's cloud-storage cache. Read-only.
    public static func collections() -> [Collection] {
        guard let acct = accounts().first, let id64 = UInt64(acct.steamID64) else { return [] }
        let dir = steamDir.appendingPathComponent("userdata/\(id64 &- 76561197960265728)/config/cloudstorage")
        var entries: [String: [String: Any]] = [:]
        // Base file first, then pending local edits (.modified) on top.
        for name in ["cloud-storage-namespace-1.json", "cloud-storage-namespace-1.modified.json"] {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let arr = try? JSONSerialization.jsonObject(with: d) as? [Any] else { continue }
            for item in arr {
                guard let pair = item as? [Any], pair.count == 2, let key = pair[0] as? String,
                      key.hasPrefix("user-collections."), let v = pair[1] as? [String: Any] else { continue }
                entries[key] = v
            }
        }
        var out: [Collection] = []
        for (key, v) in entries {
            if v["is_deleted"] as? Bool == true { continue }
            guard let raw = v["value"] as? String, let d = raw.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let id = (j["id"] as? String) ?? String(key.dropFirst("user-collections.".count))
            let added = (j["added"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }
            let removed = Set((j["removed"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue })
            out.append(Collection(id: id, name: (j["name"] as? String) ?? id, appIDs: added.filter { !removed.contains($0) },
                                  dynamic: j["filterSpec"] != nil))
        }
        return out.sorted { a, b in
            func rank(_ c: Collection) -> Int { c.id == "favorite" ? 0 : (c.id == "hidden" ? 2 : 1) }
            return (rank(a), a.name.lowercased()) < (rank(b), b.name.lowercased())
        }
    }

    /// Full owned-games list from Valve's Steam Web API (needs the user's own Web API key).
    public static func ownedGames(apiKey: String, steamID64: String) async throws -> [LibraryGame] {
        var c = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        c.queryItems = [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "steamid", value: steamID64),
                        URLQueryItem(name: "include_appinfo", value: "1"), URLQueryItem(name: "include_played_free_games", value: "1"),
                        URLQueryItem(name: "format", value: "json")]
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        guard let http = resp as? HTTPURLResponse else { throw NokError("No response from Steam.") }
        guard http.statusCode == 200 else {
            throw NokError(http.statusCode == 401 || http.statusCode == 403 ? "Steam rejected the Web API key." : "Steam answered \(http.statusCode).")
        }
        struct Resp: Decodable { struct R: Decodable { var games: [G]? }; struct G: Decodable { var appid: Int; var name: String?; var playtime_forever: Int?; var img_icon_url: String? }; var response: R }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        guard let games = r.response.games else {
            throw NokError("Steam returned no games. If your profile's game details are private, make them visible to the API (Steam → Profile → Privacy).")
        }
        return games.map { g in
            LibraryGame(appID: g.appid, name: g.name ?? "App \(g.appid)", installed: false, installDir: nil, sizeOnDisk: nil,
                        playtimeMinutes: g.playtime_forever,
                        iconURL: g.img_icon_url.flatMap { $0.isEmpty ? nil : URL(string: "https://media.steampowered.com/steamcommunity/public/images/apps/\(g.appid)/\($0).jpg") },
                        owned: true)
        }
    }

    public static func headerImage(_ appID: Int) -> URL {
        URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(appID)/header.jpg")!
    }

    public struct StoreInfo: Equatable { public var name: String?; public var mac: Bool; public var windows: Bool }

    /// Public store details (no account needed): mainly "does this game have a Mac version?".
    public static func storeInfo(_ appID: Int) async -> StoreInfo? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic,platforms"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj["\(appID)"] as? [String: Any], entry["success"] as? Bool == true,
              let d = entry["data"] as? [String: Any] else { return nil }
        let p = d["platforms"] as? [String: Any]
        return StoreInfo(name: d["name"] as? String, mac: p?["mac"] as? Bool ?? false, windows: p?["windows"] as? Bool ?? true)
    }

    // MARK: Web API key (Keychain)

    static let keychainService = "io.github.seastwood.nokcandu.steam-webapi"
    /// Where early development builds kept the key ("local.<user>.nokcandu…"); moved on first read.
    static var legacyKeychainService: String { "local.\(NSUserName()).nokcandu.steam-webapi" }

    static func keychainRead(_ service: String) -> String? {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public static var apiKey: String? {
        get {
            #if canImport(Security)
            if let k = keychainRead(keychainService) { return k }
            if let old = keychainRead(legacyKeychainService) {
                apiKey = old
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyKeychainService] as CFDictionary)
                return old
            }
            return nil
            #else
            return nil
            #endif
        }
        set {
            #if canImport(Security)
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
            SecItemDelete(base as CFDictionary)
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                var add = base; add[kSecValueData as String] = Data(v.utf8)
                SecItemAdd(add as CFDictionary, nil)
            }
            #endif
        }
    }

    // MARK: Actions

    /// Runs the helper detached (Steam keeps running after Nokcandu returns).
    public static func runHelper(_ args: [String]) throws {
        guard isSetUp else { throw NokError("Set up Steam first.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [helper.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
    }

    /// Opens Steam through Steam.app (not as a child of Nokcandu), so macOS permission prompts such as
    /// the microphone are shown for and remembered by "Steam".
    public static func openViaApp(_ args: [String]) throws {
        guard isSetUp else { throw NokError("Set up Steam first.") }
        let r = try Shell.run("/usr/bin/open", [appURL.path] + (args.isEmpty ? [] : ["--args"] + args), timeout: 30)
        if !r.ok { try runHelper(args) }
    }
    public static func openSteam() throws { try openViaApp([]) }
    public static func install(appID: Int) throws { try openViaApp(["--url", "steam://install/\(appID)"]) }
    /// Steam's in-game overlay setting for the signed-in account(s): true = off everywhere, nil = unknown.
    public static var overlayDisabled: Bool? {
        let users = steamDir.appendingPathComponent("userdata")
        let files = ((try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("config/localconfig.vdf") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        guard !files.isEmpty else { return nil }
        return files.allSatisfy { $0.contains(#/"EnableGameOverlay"\s+"0"/#) }
    }

    /// "Close Steam when its game quits" (on unless the keep-open file exists).
    public static var closesWithGame: Bool {
        get { !FileManager.default.fileExists(atPath: contents.appendingPathComponent("SharedSupport/nokcandu/keep-steam-open").path) }
        set {
            let f = contents.appendingPathComponent("SharedSupport/nokcandu/keep-steam-open")
            if newValue { try? FileManager.default.removeItem(at: f) } else { FileManager.default.createFile(atPath: f.path, contents: Data()) }
        }
    }

    /// "Smoother Steam windows": Steam's built-in browser draws with the GPU instead of in software.
    /// Smoother window moves and scrolling, but Steam then shares the GPU with the game. Off by default.
    public static var gpuDrawing: Bool {
        get { FileManager.default.fileExists(atPath: contents.appendingPathComponent("SharedSupport/nokcandu/steam-gpu").path) }
        set {
            let f = contents.appendingPathComponent("SharedSupport/nokcandu/steam-gpu")
            if newValue { FileManager.default.createFile(atPath: f.path, contents: Data()) } else { try? FileManager.default.removeItem(at: f) }
        }
    }

    public static func shutdown() async { _ = try? await Shell.runAsync("/bin/bash", [helper.path, "--shutdown"], timeout: 180) }

    /// Steam games running right now (app id → process id), found from Windows processes started from a
    /// steamapps\common\<folder> (the game's launcher app exits as soon as it hands off to Steam).
    public static func runningGames() -> [Int: Int32] {
        guard let r = try? Shell.run("/bin/ps", ["-axo", "pid=,command="], timeout: 5), r.ok else { return [:] }
        return matchRunning(r.stdout, folders: installFolders())
    }

    static func matchRunning(_ ps: String, folders: [String: Int]) -> [Int: Int32] {
        var out: [Int: Int32] = [:]
        for line in ps.split(separator: "\n") {
            guard let r = line.range(of: #"steamapps[\\/]common[\\/]"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            let rest = line[r.upperBound...]
            let folder = rest.prefix { $0 != "\\" && $0 != "/" }.lowercased()
            guard let id = folders[folder], out[id] == nil,
                  let pid = Int32(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") else { continue }
            out[id] = pid
        }
        return out
    }

    private static let folderCache = Locked<(Date, [String: Int])>((.distantPast, [:]))
    static func installFolders() -> [String: Int] {
        if Date().timeIntervalSince(folderCache.value.0) < 60 { return folderCache.value.1 }
        var m: [String: Int] = [:]
        for g in installedGames() { if let d = g.installDir, !d.isEmpty { m[d.lowercased()] = g.appID } }
        folderCache.value = (Date(), m)
        return m
    }

    /// A Steam game added before Steam finished downloading it got a guessed graphics mode. Once its
    /// program exists, look at it and pick the right mode (unless the player confirmed one).
    @discardableResult
    public static func refreshDetection(_ g: InstalledGame) -> Bool {
        guard g.usesSharedSteam, var c = g.custom, c.is64Bit == nil, c.detectedAPIs.isEmpty, let id = c.steamAppID,
              let lib = installedGames().first(where: { $0.appID == id && $0.installed }), let folder = lib.folder,
              let exe = mainExecutable(in: folder, gameName: lib.name), let pe = PEFile.inspect(exe) else { return false }
        c.is64Bit = pe.is64Bit
        c.detectedAPIs = pe.imports.map { $0.lowercased() }.filter { $0.hasPrefix("d3d") || $0 == "dxgi.dll" || $0 == "ddraw.dll" || $0 == "opengl32.dll" }
        if c.confirmedGraphics == nil { c.graphics = GraphicsPreset.suggest(for: pe) }
        return (try? CustomGames.saveAll(c, to: g)) != nil
    }

    /// Existing Nokcandu app for a Steam game, if any.
    public static func addedApp(appID: Int, in games: [InstalledGame]) -> InstalledGame? {
        games.first { $0.custom?.source == .steamLibrary && $0.custom?.steamAppID == appID }
    }

    /// Creates the small Mac app for an installed Steam game. Graphics are suggested from the game's .exe,
    /// the icon comes from the game's .exe (or Steam's own icon for it).
    @discardableResult
    public static func addGame(_ game: LibraryGame) throws -> URL {
        guard isSetUp else { throw NokError("Set up Steam first.") }
        let fm = FileManager.default
        let probe = game.folder.flatMap { mainExecutable(in: $0, gameName: game.name) }
        let pe = probe.flatMap(PEFile.inspect)
        let name = CustomGames.safeFolderName(game.name)
        let target = try CustomGames.freeAppURL(name)
        let c = target.appendingPathComponent("Contents")
        for d in ["MacOS", "Resources", "SharedSupport/nokcandu", "SharedSupport/Logs"] {
            try fm.createDirectory(at: c.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        var config = CustomGameConfig(id: "steam-\(game.appID)", name: game.name, source: .steamLibrary, steamAppID: game.appID,
                                      exe: CustomGames.steamExe, graphics: GraphicsPreset.suggest(for: pe), is64Bit: pe?.is64Bit,
                                      detectedAPIs: (pe?.imports ?? []).map { $0.lowercased() }.filter { $0.hasPrefix("d3d") || $0 == "dxgi.dll" || $0 == "ddraw.dll" || $0 == "opengl32.dll" })
        // Valve shooters start with Low-latency aiming on (Performance on the game's page).
        if LowLatency.supported(config) { config = LowLatency.set(true, config) }
        let script = CustomGames.launcherScript(for: config)
        config.launcherSHA = Hashing.sha256(data: Data(script.utf8))
        let launcher = c.appendingPathComponent("MacOS/\(CustomGames.launcherName)")
        try Data(script.utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try config.encoded().write(to: CustomGameConfig.url(in: c))

        let iconFile = writeIcon(appID: game.appID, exe: probe, contents: c) ? "AppIcon.icns" : ""
        let plist: [String: Any] = [
            "CFBundleExecutable": CustomGames.launcherName, "CFBundleIconFile": iconFile,
            "CFBundleIdentifier": "local.nokcandu.steam.\(game.appID)", "CFBundleName": game.name,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0", "LSMinimumSystemVersion": "14.6", "NSBGOnly": "1",
            "NokcanduRecipe": "steam-library",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist.merging(AppPrivacy.keys) { a, _ in a }, format: .xml, options: 0).write(to: c.appendingPathComponent("Info.plist"))
        _ = try? Shell.run("/usr/bin/touch", [target.path])
        return target
    }


    /// The game's own program inside its Steam folder: top-level .exe files first (Source games keep
    /// tools like Hammer in bin/), names that match the game, and never servers, tools or redistributables.
    public static func mainExecutable(in folder: URL, gameName: String) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        let tokens = gameName.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        let toolWords = ["server", "srcds", "dedicated", "editor", "hammer", "tool", "compile", "viewer", "convert", "crash",
                         "report", "setup", "unins", "redist", "launcher_helper", "benchmark", "sdk", "qc_", "vtf", "bsp", "mdl"]
        var best: (URL, Int)?
        for case let u as URL in en {
            if en.level > 3 { en.skipDescendants(); continue }
            let n = u.lastPathComponent.lowercased()
            guard n.hasSuffix(".exe"), !CustomGames.skipNamePrefixes.contains(where: { n.hasPrefix($0) }) else { continue }
            var score = -en.level * 100                                 // top level wins
            let dir = u.deletingLastPathComponent().lastPathComponent.lowercased()
            if ["bin", "x64", "tools", "redist", "_commonredist", "support"].contains(dir) { score -= 150 }
            if toolWords.contains(where: { n.contains($0) }) { score -= 200 }
            score += tokens.filter { n.contains($0) || $0.contains(n.replacingOccurrences(of: ".exe", with: "")) }.count * 60
            if n.contains("win64") || n.contains("x64") { score += 5 }  // prefer the 64-bit build when both exist
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            score += min(size / 2_000_000, 40)
            if best == nil || score > best!.1 { best = (u, score) }
        }
        return best?.0
    }

    /// Icon for a Steam game app: the game's own .exe icon, else Steam's cached icon/art for it.
    @discardableResult
    public static func writeIcon(appID: Int, exe: URL?, contents c: URL) -> Bool {
        let icns = c.appendingPathComponent("Resources/AppIcon.icns")
        let work = NokPaths.support.appendingPathComponent("Work/\(appID)")
        defer { try? FileManager.default.removeItem(at: work) }
        try? FileManager.default.removeItem(at: icns)
        if let exe, PEFile.writeIcns(from: exe, to: icns, workDir: work) { return true }
        if let img = libraryCacheIcon(appID) {
            try? NokPaths.ensure(work)
            let png = work.appendingPathComponent("icon.png")
            _ = try? Shell.run("/usr/bin/sips", ["-s", "format", "png", "-Z", "512", img.path, "--out", png.path])
            let r = try? Shell.run("/usr/bin/sips", ["-s", "format", "icns", png.path, "--out", icns.path])
            return r?.ok == true && FileManager.default.fileExists(atPath: icns.path)
        }
        return false
    }

    /// Re-picks the program and icon for an already-added Steam game (e.g. after a better match is available).
    public static func refreshIcon(for g: InstalledGame) -> Bool {
        guard let id = g.custom?.steamAppID,
              let lg = installedGames().first(where: { $0.appID == id }) else { return false }
        let exe = lg.folder.flatMap { mainExecutable(in: $0, gameName: lg.name) }
        guard writeIcon(appID: id, exe: exe, contents: g.contents) else { return false }
        let plistURL = g.contents.appendingPathComponent("Info.plist")
        if var plist = NSDictionary(contentsOf: plistURL) as? [String: Any] {
            plist["CFBundleIconFile"] = "AppIcon.icns"
            if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) { try? d.write(to: plistURL) }
        }
        _ = try? Shell.run("/usr/bin/touch", [g.appURL.path])
        return true
    }

    /// Steam's own cached icon/logo for an app, if the client has downloaded one.
    static func libraryCacheIcon(_ appID: Int) -> URL? {
        let cache = steamDir.appendingPathComponent("appcache/librarycache")
        let fm = FileManager.default
        for name in ["\(appID)_icon.jpg", "\(appID)_library_600x900.jpg", "\(appID)_header.jpg"] {
            let u = cache.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        // Newer layout: librarycache/<appid>/<hash>.jpg
        let dir = cache.appendingPathComponent("\(appID)")
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // The 40-hex-character .jpg is the game's small Steam icon; fall back to the logo or header art.
        if let icon = files.first(where: { $0.pathExtension.lowercased() == "jpg" && $0.deletingPathExtension().lastPathComponent.count == 40 }) { return icon }
        for name in ["logo.png", "header.jpg", "library_600x900.jpg"] { if let f = files.first(where: { $0.lastPathComponent == name }) { return f } }
        return nil
    }

    /// Recipe shown for Steam.app itself in the library.
    static func hostRecipe(wineVersion: String?) -> GameRecipe {
        GameRecipe(id: recipeID, displayName: "Steam", edition: "Shared Windows Steam for your Steam games",
                   ownershipSource: "Your Steam account", validationDate: "",
                   appBundleName: appName, launcherExecutable: hostLauncher,
                   gameDirectory: steamRel, primaryExecutable: "steam.exe",
                   runtime: RecipeCatalog.sikarugirWine10, environment: [:], display: nil, disc: nil,
                   pinnedHashes: ["SharedSupport/wine/bin/wine": RecipeCatalog.wine10SHA],
                   knownLauncherHashes: [Hashing.sha256(data: Data(hostLauncherScript().utf8)): "Nokcandu Steam launcher"],
                   verification: [VerificationItem(title: "Steam inside Wine", state: .notVerified,
                                                   note: "Uses Steam's usual Windows flags for Wine (\(CustomGames.steamWineFlags)).")],
                   hasInstaller: false,
                   notes: ["Every Steam game added from the Steam library starts through this Steam.",
                           "Graphics are set when Steam starts; switching to a game with a different mode restarts Steam (Nokcandu asks first)."])
    }
}

// MARK: - Install stages for Steam.app

public enum SteamHostInstall {
    public static var stages: [InstallStage] {
        [CustomInstall.Preflight(), ZeroHourInstall.Runtime(), ZeroHourInstall.CreateApp(), ZeroHourInstall.Prefix(),
         ZeroHourInstall.EngineTest(), InstallSteam(), BuildHost(), SignIn()]
    }

    struct InstallSteam: InstallStage {
        let info = StageInfo(id: "install-steam", title: "Install Steam",
                             detail: "Download SteamSetup.exe from Steam's website, then choose it here. Nokcandu runs it silently into the shared Steam app.",
                             kind: .handoff, needs: ["steamSetup"])
        func isDone(_ ctx: InstallContext) -> Bool {
            FileManager.default.fileExists(atPath: ctx.contents.appendingPathComponent("\(SharedSteam.steamRel)/steam.exe").path)
        }
        func run(_ ctx: InstallContext) async throws {
            guard let setup = ctx.input("steamSetup"), setup.lowercased().hasSuffix(".exe"), FileManager.default.fileExists(atPath: setup) else {
                throw NokError("Choose SteamSetup.exe downloaded from Steam's website.")
            }
            // Stop anything left over from an earlier attempt (e.g. an installer window that never showed).
            let ws = ctx.support.appendingPathComponent("wine/bin/wineserver")
            _ = try? await Shell.runAsync(ws.path, ["-k"], env: ctx.wineEnvironment, timeout: 60)
            // Steam's installer is NSIS: /S installs silently to the default folder, so there's no
            // window that can get lost behind other apps. Progress shows up as files appearing.
            ctx.log("Installing Steam silently (about a minute)…")
            let steamDir = ctx.contents.appendingPathComponent(SharedSteam.steamRel)
            let watcher = Task {
                var last = -1
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let n = (FileManager.default.enumerator(atPath: steamDir.path)?.allObjects.count) ?? 0
                    if n != last && n > 0 { ctx.log("… \(n) files so far"); last = n }
                }
            }
            defer { watcher.cancel() }
            let r = try await ctx.runWine([setup, "/S"], cwd: URL(fileURLWithPath: setup).deletingLastPathComponent(), timeout: 1800)
            ctx.log("Installer finished (exit \(r.status)).")
            try await ZeroHourInstall.flushRegistry(ctx)
        }
    }

    struct BuildHost: InstallStage {
        let info = StageInfo(id: "build-host", title: "Finish the Steam app", detail: "Adds the shared Steam launcher and helper.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            let h = ctx.contents.appendingPathComponent("Resources/\(SharedSteam.helperName)")
            return (try? Hashing.sha256(file: h)) == Hashing.sha256(data: Data(SharedSteam.helperScript().utf8))
                && FileManager.default.fileExists(atPath: ctx.contents.appendingPathComponent("Info.plist").path)
        }
        func run(_ ctx: InstallContext) async throws {
            try SharedSteam.writeHostFiles(contents: ctx.contents, workDir: ctx.workDir)
        }
    }

    struct SignIn: InstallStage {
        let info = StageInfo(id: "sign-in", title: "Sign in to Steam",
                             detail: "Press Continue to open Steam, sign in (Steam Guard happens in Steam's own window), and leave it open. Nokcandu notices when you're signed in.",
                             kind: .handoff)
        func isDone(_ ctx: InstallContext) -> Bool { !SharedSteam.accounts().isEmpty }
        func run(_ ctx: InstallContext) async throws {
            if !ZeroHourInstall.opened(ctx, info.id) {
                try ZeroHourInstall.markOpened(ctx, info.id)
                try SharedSteam.openSteam()
                ctx.log("Steam is starting. Sign in there.")
            }
            for _ in 0..<600 {           // wait up to ~10 minutes for the sign-in
                if !SharedSteam.accounts().isEmpty { ctx.log("Signed in."); return }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

extension SharedSteam {
    /// Keeps Steam.app's helper and launcher in step with this version of Nokcandu (called at startup).
    public static func refreshHostScriptsIfNeeded() {
        let fm = FileManager.default
        let launcher = contents.appendingPathComponent("MacOS/\(hostLauncher)")
        guard fm.fileExists(atPath: helper.path), fm.fileExists(atPath: launcher.path), !isRunning else { return }
        for (url, text) in [(helper, helperScript()), (launcher, hostLauncherScript())] {
            if (try? Hashing.sha256(file: url)) != Hashing.sha256(data: Data(text.utf8)) {
                try? Data(text.utf8).write(to: url, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
    }

    /// Writes (or refreshes) Steam.app's launcher, helper, marker, icon and Info.plist.
    public static func writeHostFiles(contents: URL, workDir: URL) throws {
        let fm = FileManager.default
        let helperURL = contents.appendingPathComponent("Resources/\(helperName)")
        let launcher = contents.appendingPathComponent("MacOS/\(hostLauncher)")
        try fm.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(helperScript().utf8).write(to: helperURL, options: .atomic)
        try Data(hostLauncherScript().utf8).write(to: launcher, options: .atomic)
        for u in [helperURL, launcher] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path) }
        let marker = contents.appendingPathComponent("SharedSupport/nokcandu/\(hostMarker)")
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schema":1,"role":"steam-host"}"#.utf8).write(to: marker)
        var iconFile = ""
        let icns = contents.appendingPathComponent("Resources/AppIcon.icns")
        if PEFile.writeIcns(from: contents.appendingPathComponent("\(steamRel)/steam.exe"), to: icns, workDir: workDir) {
            iconFile = icns.lastPathComponent
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": hostLauncher, "CFBundleIconFile": iconFile,
            "CFBundleIdentifier": "local.nokcandu.steam-host", "CFBundleName": "Steam",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0", "LSMinimumSystemVersion": "14.6", "NSBGOnly": "1",
            "NokcanduRecipe": recipeID,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist.merging(AppPrivacy.keys) { a, _ in a }, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    }
}
