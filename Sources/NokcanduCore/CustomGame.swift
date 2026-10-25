import Foundation

// General ("custom") games: any owned Windows game added through Nokcandu, not one of the
// hand-validated shipped recipes. Each app carries its own settings in
// Contents/SharedSupport/nokcandu/game.json; the launcher is generated from those settings.

public enum GameSource: String, Codable, CaseIterable, Identifiable {
    case installer, disc, steamLibrary, steam, folder
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .installer: "Windows installer"
        case .disc: "Disc image"
        case .steamLibrary: "From your Steam library"
        case .steam: "Steam download (SteamCMD)"
        case .folder: "Existing game folder"
        }
    }
    public var detail: String {
        switch self {
        case .installer: "A setup .exe or .msi you downloaded or own."
        case .disc: "An .iso of your game disc. It stays inside the app and mounts read-only when you play."
        case .steamLibrary: "Browse your Steam games. They install into one shared Windows Steam (sign in once); each game still gets its own Mac app. For games that need Steam running, like Counter-Strike: Source."
        case .steam: "Just the game's Windows files, via SteamCMD. Only for games that run without Steam (like Zero Hour)."
        case .folder: "A Windows game folder that's already installed somewhere."
        }
    }
    public var symbol: String {
        switch self { case .installer: "shippingbox"; case .disc: "opticaldisc"; case .steamLibrary: "cloud"; case .steam: "arrow.down.circle"; case .folder: "folder" }
    }
}

/// Graphics modes offered for general games. Plain names first; the technical parts live in `technical`.
public enum GraphicsPreset: String, Codable, CaseIterable, Identifiable {
    case classic3D = "dx9"
    case modern3D = "dx11"
    case appleMetal = "d3dmetal"
    case classic2D = "ddraw"
    case compatible = "wined3d"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .classic3D: "Older 3D games"
        case .modern3D: "Newer 3D games"
        case .appleMetal: "Apple Metal"
        case .classic2D: "Classic 2D games"
        case .compatible: "Compatibility"
        }
    }
    public var detail: String {
        switch self {
        case .classic3D: "DirectX 8–9. The mode tested with Zero Hour."
        case .modern3D: "DirectX 10–11."
        case .appleMetal: "DirectX 11–12, 64-bit games only."
        case .classic2D: "DirectDraw games from the late '90s."
        case .compatible: "Wine's own graphics. Slower, but works with the most games."
        }
    }
    public var technical: String {
        switch self {
        case .classic3D: "DXVK-Sikarugir 3.1.1 (d9vk) + KosmicKrisp Vulkan"
        case .modern3D: "DXVK-Sikarugir 3.1.1 (dxvk3) + KosmicKrisp Vulkan"
        case .appleMetal: "Apple D3DMetal (Game Porting Toolkit)"
        case .classic2D: "cnc-ddraw 7.1"
        case .compatible: "WineD3D (OpenGL)"
        }
    }
    public var validated: Bool { self == .classic3D }

    /// Launcher lines. All renderer DLLs in the Sikarugir runtime are Wine *builtin* DLLs, so they
    /// are selected with WINEDLLPATH_<NAME> and `=b` — never `=n` (see the Zero Hour notes).
    var launcherExports: [String] {
        let vk = #"export VK_DRIVER_FILES="$CONTENTS/Resources/vulkan/icd.d/kosmickrisp_mesa_icd.json""#
        let log = #"export DXVK_LOG_PATH="$SUPPORT/Logs""#
        // Smoothness: compile new shaders in the background instead of freezing (the Sikarugir DXVK build
        // is the -async variant), and keep at most one frame queued so aiming isn't delayed.
        let smooth = [#"export DXVK_ASYNC=1"#, #"export DXVK_CONFIG="d3d9.maxFrameLatency = 1; dxgi.maxFrameLatency = 1""#]
        switch self {
        case .classic3D:
            return [#"export WINEDLLPATH_D9VK="$SUPPORT/renderer/d9vk/wine""#, vk, log] + smooth + [#"export WINEDLLOVERRIDES="d3d8,d3d9=b""#]
        case .modern3D:
            return [#"export WINEDLLPATH_DXVK="$SUPPORT/renderer/dxvk3/wine""#, vk, log] + smooth + [#"export WINEDLLOVERRIDES="d3d9,d3d10core,d3d11,dxgi=b""#]
        case .appleMetal:
            return [#"export WINEDLLPATH_D3DMETAL="$SUPPORT/renderer/d3dmetal/wine""#,
                    #"export CX_D3DMETALPATH="$SUPPORT/renderer/d3dmetal/external""#,
                    #"export DYLD_FALLBACK_FRAMEWORK_PATH="$SUPPORT/renderer/d3dmetal/external""#,
                    #"export WINEDLLOVERRIDES="dxgi,d3d11,d3d12,d3d12core=b""#]
        case .classic2D:
            return [#"export WINEDLLPATH_CNCD="$SUPPORT/renderer/cnc_ddraw/wine""#, #"export WINEDLLOVERRIDES="ddraw=b""#]
        case .compatible:
            return []
        }
    }

    /// Suggest a mode from what the game's .exe imports.
    public static func suggest(for info: PEInfo?) -> GraphicsPreset {
        guard let info else { return .classic3D }
        let i = Set(info.imports.map { $0.lowercased() })
        if i.contains("d3d12.dll") { return info.is64Bit ? .appleMetal : .modern3D }
        if i.contains("d3d11.dll") || i.contains("d3d10.dll") || i.contains("d3d10_1.dll") || i.contains("dxgi.dll") { return .modern3D }
        if i.contains("d3d9.dll") || i.contains("d3d8.dll") { return .classic3D }
        if i.contains("ddraw.dll") { return .classic2D }
        if i.contains("opengl32.dll") { return .compatible }
        return .classic3D
    }
}

public struct CustomGameConfig: Codable, Hashable {
    public var schema = 1
    public var id: String
    public var name: String
    public var source: GameSource
    public var steamAppID: Int?
    /// Windows path of the game's .exe, e.g. C:\Games\Foo\foo.exe
    public var exe: String
    public var arguments: String = ""
    public var graphics: GraphicsPreset
    public var disc: DiscSpec?
    public var is64Bit: Bool?
    public var detectedAPIs: [String] = []
    /// Graphics mode the user confirmed actually played well (nil = not play-tested yet).
    public var confirmedGraphics: GraphicsPreset?
    public var createdAt = Date()
    public var launcherSHA: String?
    /// Extra environment variables for the game (advanced). Applied after the graphics mode, so they can override it.
    public var environment: [String: String]?

    public static let fileName = "game.json"
    public static func url(in contents: URL) -> URL { contents.appendingPathComponent("SharedSupport/nokcandu/\(fileName)") }

    public static func load(contents: URL) -> CustomGameConfig? {
        guard let d = try? Data(contentsOf: url(in: contents)) else { return nil }
        return try? ChangeJournal.decoder.decode(CustomGameConfig.self, from: d)
    }

    public func encoded() throws -> Data { try ChangeJournal.encoder.encode(self) }

    /// Unix path of the exe relative to the app's Contents (C: only).
    public var exeRelativeToContents: String? {
        guard let rest = CustomGames.driveCRelative(windowsPath: exe) else { return nil }
        return "SharedSupport/prefix/drive_c/" + rest
    }

    /// A recipe synthesized from the settings, so the library, launcher and diagnostics treat it uniformly.
    public var recipe: GameRecipe {
        let rel = exeRelativeToContents ?? "SharedSupport/prefix/drive_c"
        var verification = [
            VerificationItem(title: "Gameplay",
                             state: confirmedGraphics != nil ? .confirmed : .notVerified,
                             note: confirmedGraphics.map { "You confirmed it plays well with \($0.title)." } ?? "Not play-tested yet."),
            VerificationItem(title: "Graphics: \(graphics.title)",
                             state: confirmedGraphics == graphics ? .confirmed : .notVerified,
                             note: graphics.technical),
        ]
        if graphics == .appleMetal && is64Bit == false {
            verification.append(VerificationItem(title: "Apple Metal needs a 64-bit game", state: .notVerified, note: "This game's .exe is 32-bit."))
        }
        if disc != nil {
            verification.append(VerificationItem(title: "Disc", state: .notVerified, note: "Mounted read-only at launch; label \(disc?.volumeLabel ?? "?")."))
        }
        return GameRecipe(
            id: "custom-\(id)",
            displayName: name,
            edition: "Added with Nokcandu · \(source.title)",
            ownershipSource: steamAppID.map { "Steam app \($0)" } ?? source.title,
            validationDate: ISO8601DateFormatter().string(from: createdAt).prefix(10).description,
            appBundleName: "\(name).app",
            launcherExecutable: CustomGames.launcherName,
            gameDirectory: (rel as NSString).deletingLastPathComponent,
            primaryExecutable: (rel as NSString).lastPathComponent,
            runtime: RecipeCatalog.sikarugirWine10,
            environment: [:],
            display: nil,
            disc: disc,
            pinnedHashes: ["SharedSupport/wine/bin/wine": RecipeCatalog.wine10SHA],
            knownLauncherHashes: launcherSHA.map { [$0: "Nokcandu-generated launcher"] } ?? [:],
            verification: verification,
            hasInstaller: false,
            notes: ["General game: settings live in SharedSupport/nokcandu/game.json and the launcher is regenerated from them.",
                    "Detected: \(detectedAPIs.isEmpty ? "nothing notable" : detectedAPIs.joined(separator: ", "))\(is64Bit.map { $0 ? " · 64-bit" : " · 32-bit" } ?? "")."])
    }
}

public enum CustomGames {
    public static let launcherName = "game-launcher"
    public static let steamExe = #"C:\Program Files (x86)\Steam\steam.exe"#
    /// Log writer for game and Steam output: drops Wine's repeated msync pool warnings (a long session
    /// once wrote 2.5 GB of them) and stops at 50 MB, but always keeps Nokcandu's own status lines.
    public static let logFilter = #"/usr/bin/awk -v max=52428800 '/node memory pool exhausted/ { next } { n += length($0) + 1 } n < max || /^nokcandu/ { print; fflush() }'"#
    /// Flags commonly needed for Steam's built-in browser under Wine.
    public static let steamWineFlags = "-no-cef-sandbox -cef-disable-gpu-compositing"
    public static let steamSetupPage = URL(string: "https://store.steampowered.com/about/")!

    public static func steamArguments(appID: Int) -> String { "\(steamWineFlags) -applaunch \(appID)" }

    // MARK: Paths

    public static func driveCRelative(windowsPath: String) -> String? {
        let p = windowsPath.replacingOccurrences(of: "/", with: "\\")
        guard p.count > 3, p.prefix(3).uppercased() == "C:\\" else { return nil }
        return p.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
    }

    public static func windowsPath(forUnix url: URL, prefix: URL) -> String? {
        let base = prefix.appendingPathComponent("drive_c").standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(base + "/") else { return nil }
        return "C:\\" + p.dropFirst(base.count + 1).replacingOccurrences(of: "/", with: "\\")
    }

    public static func safeFolderName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: ":*?\"<>|/\\").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "Game" : String(cleaned.prefix(60))
    }

    public static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-").prefix(40).description
    }

    // MARK: Finding the game's .exe

    public struct ExeCandidate: Identifiable, Hashable {
        public var id: String { windowsPath }
        public var url: URL
        public var windowsPath: String
        public var size: Int64
        public var score: Int
    }

    static let skipDirs: Set<String> = ["windows", "programdata", "users", "common files", "internet explorer",
                                        "windows nt", "windows media player", "windowspowershell", "microsoft.net",
                                        "dotnet", "_commonredist", "redist", "redistributables", "directx", "vcredist", "msbuild"]
    static let skipNamePrefixes = ["unins", "setup", "install", "vcredist", "vc_redist", "dxsetup", "dotnet", "ndp",
                                   "crashreport", "crashhandler", "crashpad", "uninstall", "update", "patch", "unitycrashhandler",
                                   "ue4prereq", "ueprereq", "easyanticheat", "be_service", "steamcmd", "steam.exe", "steamerrorreporter",
                                   "iexplore", "wmplayer", "notepad", "winemenubuilder"]

    /// Ranks .exe files under drive_c that look like the game (outside Wine's own folders).
    public static func findExecutables(prefix: URL, nameHint: String, limit: Int = 12) -> [ExeCandidate] {
        let driveC = prefix.appendingPathComponent("drive_c")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: driveC, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let hints = nameHint.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        var out: [ExeCandidate] = []
        for case let url as URL in en {
            let name = url.lastPathComponent.lowercased()
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true {
                if skipDirs.contains(name) || en.level > 6 { en.skipDescendants() }
                continue
            }
            guard name.hasSuffix(".exe"), !skipNamePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let win = windowsPath(forUnix: url, prefix: prefix) else { continue }
            let size = Int64(vals?.fileSize ?? 0)
            var score = Int(min(size / 200_000, 200))              // bigger usually = the game
            score += hints.filter { name.contains($0) }.count * 60
            score += hints.filter { win.lowercased().contains($0) }.count * 15
            score -= en.level * 4
            if name.contains("launcher") { score -= 10 }
            // Battle.net: its launcher starts Battle.net.exe with the settings it needs under Wine
            // (--in-process-gpu --use-gl=swiftshader); starting Battle.net.exe directly crashes its window.
            if name == "battle.net launcher.exe" { score += 400 }
            if name.contains("editor") || name.contains("server") || name.contains("config") || name.contains("tool") { score -= 40 }
            out.append(ExeCandidate(url: url, windowsPath: win, size: size, score: score))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: Launcher

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func splitArguments(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; has = true; continue }
            if ch == " " || ch == "\t" { if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }; continue }
            cur.append(ch)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Generates the game's launcher script. Same conventions as the validated launchers:
    /// private prefix, bundled engine, single instance, bounded log, read-only disc mounting.
    public static func launcherScript(for c: CustomGameConfig) -> String {
        if c.source == .steamLibrary, let id = c.steamAppID {
            return SharedSteam.gameLauncherScript(appID: id, name: c.name, graphics: c.graphics, steamApp: SharedSteam.appURL,
                                                  arguments: splitArguments(c.arguments))
        }
        let exeRel = driveCRelative(windowsPath: c.exe) ?? ""
        let dirRel = (exeRel as NSString).deletingLastPathComponent
        let exeName = (exeRel as NSString).lastPathComponent
        var s = """
        #!/bin/bash
        # Generated by Nokcandu for \(c.name.replacingOccurrences(of: "\n", with: " ")).
        # Settings: Contents/SharedSupport/nokcandu/game.json — change them in Nokcandu, not here.
        set -euo pipefail
        CONTENTS="$(cd "$(dirname "$0")/.." && pwd)"
        SUPPORT="$CONTENTS/SharedSupport"
        export WINEPREFIX="$SUPPORT/prefix"
        export DYLD_FALLBACK_LIBRARY_PATH="$CONTENTS/Frameworks:/usr/lib"
        # Quiet, except errors from Windows video playback (lets Nokcandu recognize cinematic crashes).
        export WINEDEBUG=-all,err+quartz,err+strmbase
        export WINEMSYNC=1
        export PATH="$SUPPORT/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        # Raw mouse for aiming (Nokcandu switch): reads the mouse directly while a game is in mouse-look.
        if [ -f "$SUPPORT/nokcandu/raw-mouse" ] && [ -f "$SUPPORT/nokcandu/nokcandu-rawmouse.dylib" ]; then
         export DYLD_INSERT_LIBRARIES="$SUPPORT/nokcandu/nokcandu-rawmouse.dylib"
         export NOKCANDU_RAW_MOUSE_SCALE="$(head -n 1 "$SUPPORT/nokcandu/raw-mouse")"
         [ -f "$SUPPORT/nokcandu/raw-mouse-debug" ] && export NOKCANDU_RAW_MOUSE_DEBUG=1
        fi
        # Graphics: \(c.graphics.title) (\(c.graphics.technical))

        """
        for line in c.graphics.launcherExports { s += line + "\n" }
        s += "# Performance switches set in Nokcandu (FPS counter, vsync, frame limit).\n"
        s += #"[ -f "$SUPPORT/nokcandu/perf.env" ] && . "$SUPPORT/nokcandu/perf.env""# + "\n"
        let env = (c.environment ?? [:]).filter { CustomGames.isValidEnvName($0.key) }.sorted { $0.key < $1.key }
        if !env.isEmpty {
            s += "# Your extra settings\n"
            for (k, v) in env { s += "export \(k)=\(shellQuote(v))\n" }
        }
        s += """
        GAME_DIR="$WINEPREFIX/drive_c/"\(shellQuote(dirRel))
        GAME_EXE=\(shellQuote(c.exe))
        LOG_DIR="$SUPPORT/Logs"
        mkdir -p "$LOG_DIR"
        CHECK_ONLY=0
        [ "${1:-}" != --check ] || CHECK_ONLY=1
        if [ "$CHECK_ONLY" = 0 ]; then
         LOCK="$LOG_DIR/game.lock"
         if ! mkdir "$LOCK" 2>/dev/null; then
          PREVIOUS_PID=$(cat "$LOCK/pid" 2>/dev/null || true)
          if [[ "$PREVIOUS_PID" =~ ^[0-9]+$ ]] && kill -0 "$PREVIOUS_PID" 2>/dev/null; then exit 0; fi
          rm -f "$LOCK/pid"
          rmdir "$LOCK" 2>/dev/null || exit 0
          mkdir "$LOCK"
         fi
         echo $$ > "$LOCK/pid"
         trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true' EXIT
         exec > >(\(CustomGames.logFilter) >"$LOG_DIR/launch.log") 2>&1
        fi

        """
        if let d = c.disc {
            s += """
            # Disc: mount the game's own image read-only and map D: (volume) and D:: (raw device).
            DISC_IMAGE="$SUPPORT/"\(shellQuote(d.imageName))
            DISC_LABEL=\(shellQuote(d.volumeLabel))
            info() { /usr/sbin/diskutil info -plist "$1" 2>/dev/null | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null || true; }
            MOUNT_DIR="$SUPPORT/MountedDisc"
            if [ -n "$DISC_LABEL" ] && [ "$(info "/Volumes/$DISC_LABEL" VolumeName)" = "$DISC_LABEL" ] && [ "$(info "/Volumes/$DISC_LABEL" MountPoint)" = "/Volumes/$DISC_LABEL" ]; then
             MOUNT_DIR="/Volumes/$DISC_LABEL"
            elif [ "$(info "$MOUNT_DIR" MountPoint)" != "$MOUNT_DIR" ]; then
             [ -f "$DISC_IMAGE" ]
             mkdir -p "$MOUNT_DIR"
             /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DISC_IMAGE" >/dev/null
            fi
            DISC_DEVICE=$(info "$MOUNT_DIR" DeviceNode)
            RAW_DEVICE="/dev/r${DISC_DEVICE#/dev/}"
            [ -r "$RAW_DEVICE" ]
            ln -sfn "$MOUNT_DIR" "$WINEPREFIX/dosdevices/d:"
            ln -sfn "$RAW_DEVICE" "$WINEPREFIX/dosdevices/d::"

            """
        }
        let args = splitArguments(c.arguments).map(shellQuote).joined(separator: " ")
        s += """
        [ -x "$SUPPORT/wine/bin/wine" ]
        [ -f "$GAME_DIR/"\(shellQuote(exeName)) ]
        if [ "$CHECK_ONLY" = 1 ]; then printf 'Launcher check passed: game and engine are ready.\\n'; exit 0; fi
        cd "$GAME_DIR"
        STATUS=0
        "$SUPPORT/wine/bin/wine" "$GAME_EXE"\(args.isEmpty ? "" : " " + args) || STATUS=$?
        echo "nokcandu: game exited with status $STATUS after ${SECONDS}s"
        exit $STATUS

        """
        return s
    }

    // MARK: Changing settings of an installed general game

    /// Writes game.json + regenerated launcher through the game's change journal.
    /// Brings unmodified launchers up to date with this version of Nokcandu (edited ones are left alone).
    public static func upgradeLaunchers(_ games: [InstalledGame]) {
        for g in games {
            guard let c = g.custom, let l = g.launcherURL, let sha = try? Hashing.sha256(file: l), sha == c.launcherSHA else { continue }
            if case .launcherRunning = GameLauncher.runState(of: g) { continue }
            if Hashing.sha256(data: Data(launcherScript(for: c).utf8)) != sha { try? save(c, to: g) }
        }
    }

    public static func isValidEnvName(_ k: String) -> Bool {
        k.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil &&
        !["PATH", "WINEPREFIX", "DYLD_FALLBACK_LIBRARY_PATH", "HOME"].contains(k)
    }

    /// Runs of .exe candidates for the settings screen (same ranking as the installer).
    public static func executables(for game: InstalledGame) -> [ExeCandidate] {
        findExecutables(prefix: game.prefix, nameHint: game.name, limit: 15)
    }

    /// `force` rewrites the launcher even if it was edited outside Nokcandu (the old one is kept in the journal).
    public static func save(_ config: CustomGameConfig, to game: InstalledGame, force: Bool = false) throws {
        if case .launcherRunning = GameLauncher.runState(of: game) { throw NokError("Quit \(game.name) first.") }
        var c = config
        let script = launcherScript(for: c)
        c.launcherSHA = Hashing.sha256(data: Data(script.utf8))
        let journal = ChangeJournal(scope: game.journalScope)
        let launcher = game.contents.appendingPathComponent("MacOS/\(launcherName)")
        // Refuse to overwrite a launcher someone else edited.
        if !force, let current = try? Hashing.sha256(file: launcher), let old = CustomGameConfig.load(contents: game.contents)?.launcherSHA, current != old {
            throw NokError("The launcher was edited outside Nokcandu, so it wasn't changed.")
        }
        try journal.write(Data(script.utf8), to: launcher, reason: "Launcher for \(c.graphics.title)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try journal.write(try c.encoded(), to: CustomGameConfig.url(in: game.contents), reason: "Game settings")
    }
}
