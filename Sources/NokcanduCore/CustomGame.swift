import Foundation

// General ("custom") games: any owned Windows game added through Nokcandu, not one of the
// hand-validated shipped recipes. Each app carries its own settings in
// Contents/SharedSupport/nokcandu/game.json; the launcher is generated from those settings.

public enum GameSource: String, Codable, CaseIterable, Identifiable {
    case installer, disc, steamLibrary, steam, folder, store
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .installer: "Windows installer"
        case .disc: "Disc image"
        case .steamLibrary: "From your Steam library"
        case .steam: "Steam download (SteamCMD)"
        case .folder: "Existing game folder"
        case .store: "From GOG, Epic or Amazon"
        }
    }
    public var detail: String {
        switch self {
        case .installer: "A setup .exe or .msi you downloaded or own."
        case .disc: "An .iso of your game disc. It stays inside the app and mounts read-only when you play."
        case .steamLibrary: "Browse your Steam games. They install into one shared Windows Steam (sign in once); each game still gets its own Mac app. For games that need Steam running, like Counter-Strike: Source."
        case .steam: "Just the game's Windows files, via SteamCMD. Only for games that run without Steam (like Zero Hour)."
        case .folder: "A Windows game folder that's already installed somewhere."
        case .store: "Sign in to your GOG, Epic Games or Amazon account and install games you own; each gets its own Mac app."
        }
    }
    public var symbol: String {
        switch self { case .installer: "shippingbox"; case .disc: "opticaldisc"; case .steamLibrary: "cloud"; case .steam: "arrow.down.circle"; case .folder: "folder"; case .store: "bag" }
    }
}

/// Graphics modes offered for general games. Plain names first; the technical parts live in `technical`.
public enum GraphicsPreset: String, Codable, CaseIterable, Identifiable {
    case classic3D = "dx9"
    case modern3D = "dx11"
    case appleMetal = "d3dmetal"
    case dxmt = "dxmt"
    case classic2D = "ddraw"
    case compatible = "wined3d"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .classic3D: "Older 3D games"
        case .modern3D: "Newer 3D games"
        case .appleMetal: "Apple Metal"
        case .dxmt: "Metal for DirectX 10–11 (DXMT)"
        case .classic2D: "Classic 2D games"
        case .compatible: "Compatibility"
        }
    }
    public var detail: String {
        switch self {
        case .classic3D: "DirectX 8–9. The mode tested with Zero Hour."
        case .modern3D: "DirectX 10–11."
        case .appleMetal: "DirectX 11–12, 64-bit games only."
        case .dxmt: "DirectX 10–11 straight to Metal, 32- and 64-bit games. Newer; try it when Apple Metal can't run a game (32-bit) or Newer 3D games is slow."
        case .classic2D: "DirectDraw games from the late '90s."
        case .compatible: "Wine's own graphics. Slower, but works with the most games."
        }
    }
    public var technical: String {
        switch self {
        case .classic3D: "DXVK-Sikarugir 3.1.1 (d9vk) + KosmicKrisp Vulkan"
        case .modern3D: "DXVK-Sikarugir 3.1.1 (dxvk3) + KosmicKrisp Vulkan"
        case .appleMetal: "Apple D3DMetal (Game Porting Toolkit)"
        case .dxmt: "DXMT (open source, LGPL) — D3D10/11 on Metal"
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
                    #"[ -f "$SUPPORT/renderer/d3dmetal/external/libd3dshared.dylib" ] && export CX_APPLEGPTK_LIBD3DSHARED_PATH="$SUPPORT/renderer/d3dmetal/external/libd3dshared.dylib""#,
                    #"export WINEDLLOVERRIDES="dxgi,d3d11,d3d12,d3d12core=b""#]
        case .dxmt:
            return [#"export WINEDLLPATH_DXMT="$SUPPORT/renderer/dxmt/wine""#,
                    #"export DXMT_LOG_PATH="$SUPPORT/Logs""#,
                    // Report the same graphics card as Apple Metal (D3DMetal: AMD 0x1002/0x66AF). Games remember
                    // settings per card — CS2 resets its video settings and window mode whenever the card changes —
                    // so switching between Apple Metal and DXMT would otherwise wipe the game's own settings.
                    #"export DXMT_CONFIG="${DXMT_CONFIG:+$DXMT_CONFIG;}dxgi.customVendorId=1002;dxgi.customDeviceId=66af""#,
                    #"export WINEDLLOVERRIDES="dxgi,d3d10core,d3d11,winemetal=b""#]
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
    /// Disc 2, 3… of a multi-disc game (Disc 1 is `disc`). Drive D: holds one at a time.
    public var extraDiscs: [DiscSpec]?
    public var is64Bit: Bool?
    public var detectedAPIs: [String] = []
    /// Optional component switches, managed by CompatibilityFixes.
    /// Built-in BF1942 display recipe uses a verified menu-size copy beside the original.
    public var bf1942MenuCopy: Bool?
    public var borderless: Bool?
    public var legacyD3D9: Bool?
    /// Graphics mode the user confirmed actually played well (nil = not play-tested yet).
    public var confirmedGraphics: GraphicsPreset?
    public var createdAt = Date()
    public var launcherSHA: String?
    /// Extra environment variables for the game (advanced). Applied after the graphics mode, so they can override it.
    public var environment: [String: String]?
    /// Game resolution: the Mac's screen switches to these pixels while the game runs (nil = leave it).
    public var displayPixels: [Int]?
    /// Unused: Wine's Mac driver has no virtual screen (kept so settings saved by test builds still load).
    public var virtualScreen: [Int]?
    /// The store the game came from (GOG, Epic, Amazon); Epic and Amazon add sign-in details at launch.
    public var store: StoreLink?

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
            edition: "Added with Nokcandu · " + (store.map { "From \($0.store.title)" } ?? source.title),
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

    /// "<name>.app" in the game apps folder, or "<name> (2).app"… when taken. Parentheses keep a suffix from
    /// reading as part of the title ("StarCraft 2" is a different game). A leftover from a setup that never
    /// finished (no Info.plist yet) is reported instead of silently taking the next name.
    public static func freeAppURL(_ name: String, in folder: URL = NokPaths.gameAppsFolder) throws -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent("\(name).app")
        if fm.fileExists(atPath: first.path), !fm.fileExists(atPath: first.appendingPathComponent("Contents/Info.plist").path) {
            throw NokError("\(name).app is left over from a setup that didn't finish. Resume or remove it under Add Game → Unfinished setups (or move it to the Trash), then try again.")
        }
        var target = first, n = 2
        while fm.fileExists(atPath: target.path) { target = folder.appendingPathComponent("\(name) (\(n)).app"); n += 1 }
        return target
    }

    public static func safeFolderName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: ":*?\"<>|/\\").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
            .replacing(#/ {2,}/#, with: " ")            // "Counter-Strike: Source" → "Counter-Strike Source"
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
    public static func findExecutables(prefix: URL, nameHint: String, limit: Int = 12, searchFolder: URL? = nil) -> [ExeCandidate] {
        let driveC = prefix.appendingPathComponent("drive_c")
        let fm = FileManager.default
        let hints = nameHint.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        var out: [ExeCandidate] = []
        // Enumerators do not descend into symlinks. Follow linked game folders explicitly,
        // keeping the logical C: path and guarding against cycles and excessive depth.
        func scan(_ directory: URL, depth: Int, ancestors: Set<String>) {
            guard depth <= 7 else { return }
            let real = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard !ancestors.contains(real) else { return }
            var visited = ancestors; visited.insert(real)
            guard let children = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: real, isDirectory: true), includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return }
            for child in children {
                let url = directory.appendingPathComponent(child.lastPathComponent)
                let name = url.lastPathComponent.lowercased()
                if fm.isDirectory(url.resolvingSymlinksInPath()) {
                    if !skipDirs.contains(name) { scan(url, depth: depth + 1, ancestors: visited) }
                    continue
                }
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey])
                guard name.hasSuffix(".exe"), !skipNamePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                guard let win = windowsPath(forUnix: url, prefix: prefix) else { continue }
                let size = Int64(vals?.fileSize ?? 0)
                var score = Int(min(size / 200_000, 200))              // bigger usually = the game
                score += hints.filter { name.contains($0) }.count * 60
                score += hints.filter { win.lowercased().contains($0) }.count * 15
                score -= depth * 4
                if name.contains("launcher") { score -= 10 }
                // Battle.net: its launcher starts Battle.net.exe with the settings it needs under Wine
                // (--in-process-gpu --use-gl=swiftshader); starting Battle.net.exe directly crashes its window.
                if name == "battle.net launcher.exe" { score += 400 }
                if name.contains("editor") || name.contains("server") || name.contains("config") || name.contains("tool") { score -= 40 }
                out.append(ExeCandidate(url: url, windowsPath: win, size: size, score: score))
            }
        }
        scan(searchFolder ?? driveC, depth: 0, ancestors: [])
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: Launcher

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func shellQuoteIfNeeded(_ s: String) -> String {
        s.isEmpty || s.contains(where: { " \t'\"".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "") + "\"" : s
    }

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
    /// Some Windows launchers start their games with an environment of their own (Blizzard's agent does),
    /// which drops the variables that load Nokcandu's helper library. Windows builds such environments
    /// from the user's registry environment, so keep the same variables there too (synced only when they change).
    static let registryEnvBlock = #"""
    if [ "$CHECK_ONLY" = 0 ] && [ -f "$SUPPORT/nokcandu/nokcandu-rawmouse.dylib" ]; then
     REGENV="$SUPPORT/nokcandu/registry-env"
     WANT="$(for v in DYLD_INSERT_LIBRARIES NOKCANDU_APP_NAMES NOKCANDU_RAW_MOUSE_SCALE NOKCANDU_RAW_MOUSE_DEBUG NOKCANDU_RAW_MOUSE_SMOOTH; do printf '%s=%s\n' "$v" "${!v:-}"; done)"
     if [ "$(cat "$REGENV" 2>/dev/null || true)" != "$WANT" ]; then
      REG="$(/usr/bin/mktemp -t nokcandu-env)"
      { printf 'Windows Registry Editor Version 5.00\r\n\r\n[HKEY_CURRENT_USER\\Environment]\r\n'
        while IFS='=' read -r k val; do
         if [ -n "$val" ]; then printf '"%s"="%s"\r\n' "$k" "${val//\\/\\\\}"; else printf '"%s"=-\r\n' "$k"; fi
        done <<<"$WANT"; } > "$REG"
      "$SUPPORT/wine/bin/wine" regedit /S "$REG" >/dev/null 2>&1 && printf '%s' "$WANT" > "$REGENV" || true
      rm -f "$REG"
     fi
    fi

    """#

    public static func launcherScript(for c: CustomGameConfig) -> String {
        if c.source == .steamLibrary, let id = c.steamAppID {
            return SharedSteam.gameLauncherScript(appID: id, name: c.name, graphics: c.graphics, steamApp: SharedSteam.appURL,
                                                  arguments: splitArguments(c.arguments), displayPixels: c.displayPixels)
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
        export NOKCANDU_APP_NAME=\(shellQuote(c.name))
        # Graphics: \(c.graphics.title) (\(c.graphics.technical))

        """
        for line in c.graphics.launcherExports { s += line + "\n" }
        s += "# Performance switches set in Nokcandu (FPS counter, vsync, frame limit).\n"
        s += #"[ -f "$SUPPORT/nokcandu/perf.env" ] && . "$SUPPORT/nokcandu/perf.env""# + "\n"
        if c.legacyD3D9 == true {
            s += #"export WINEDLLPATH_D9VK="$SUPPORT/renderer/dxvk/wine""# + "\n"
        }
        let env = (c.environment ?? [:]).filter { CustomGames.isValidEnvName($0.key) }.sorted { $0.key < $1.key }
        if !env.isEmpty {
            s += "# Your extra settings\n"
            for (k, v) in env { s += "export \(k)=\(shellQuote(v))\n" }
        }
        s += EAAppInstaller.gameRendererExports(c)
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
        s += CustomGames.registryEnvBlock
        if c.exe.lowercased().hasSuffix("\\eadesktop.exe") {
            s += "if [ \"$CHECK_ONLY\" = 0 ]; then\n" + EACompatibility.block(watch: true) + "fi\n"
        }
        if let d = c.disc, c.extraDiscs?.isEmpty ?? true {
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
             \(Discs.launcherAttach)
            fi
            DISC_DEVICE=$(info "$MOUNT_DIR" DeviceNode)
            RAW_DEVICE="/dev/r${DISC_DEVICE#/dev/}"
            [ -r "$RAW_DEVICE" ]
            ln -sfn "$MOUNT_DIR" "$WINEPREFIX/dosdevices/d:"
            ln -sfn "$RAW_DEVICE" "$WINEPREFIX/dosdevices/d::"

            """
        } else if c.disc != nil {
            let discs = Discs.all(c)
            s += """
            # Discs: the game's \(discs.count) disc images. D: holds the one chosen in Nokcandu (Discs → Put in drive D:,
            # also while playing); each is mounted read-only at its own folder inside the app.
            DISC_IMAGES=(\(discs.map { shellQuote($0.imageName) }.joined(separator: " ")))
            CUR=$(head -n 1 "$SUPPORT/nokcandu/current-disc" 2>/dev/null || echo 0)
            { [[ "$CUR" =~ ^[0-9]+$ ]] && [ "$CUR" -lt ${#DISC_IMAGES[@]} ]; } || CUR=0
            DISC_IMAGE="$SUPPORT/${DISC_IMAGES[$CUR]}"
            MOUNT_DIR="$SUPPORT/MountedDisc"; [ "$CUR" -gt 0 ] && MOUNT_DIR="$SUPPORT/MountedDisc$((CUR + 1))"
            info() { /usr/sbin/diskutil info -plist "$1" 2>/dev/null | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null || true; }
            if [ "$(info "$MOUNT_DIR" MountPoint)" != "$MOUNT_DIR" ]; then
             [ -f "$DISC_IMAGE" ]
             mkdir -p "$MOUNT_DIR"
             \(Discs.launcherAttach)
            fi
            DISC_DEVICE=$(info "$MOUNT_DIR" DeviceNode)
            RAW_DEVICE="/dev/r${DISC_DEVICE#/dev/}"
            [ -r "$RAW_DEVICE" ]
            ln -sfn "$MOUNT_DIR" "$WINEPREFIX/dosdevices/d:"
            ln -sfn "$RAW_DEVICE" "$WINEPREFIX/dosdevices/d::"

            """
        }
        if c.bf1942MenuCopy == true {
            let target = c.exe.split(separator: "\\").dropLast().joined(separator: "\\") + "\\" + BF1942DisplayFix.copyName
            s += "GAME_EXE=\(shellQuote(target))\n"
            let restart = c.exe.split(separator: "\\").dropLast().joined(separator: "\\") + "\\" + BF1942DisplayFix.restartCopyName
            s += "export NOKCANDU_BORDERLESS_RESTART_TARGET=\(shellQuote(restart))\n"
            s += #"[ -f "$GAME_DIR/BF1942-Nokcandu.exe" ] || { echo 'Nokcandu: BF1942 display copy is missing. Undo or reapply its display fix.'; exit 1; }"# + "\n"
            s += #"BF_SOURCE_SHA=$(/usr/bin/shasum -a 256 "$GAME_DIR/BF1942.exe" | /usr/bin/awk '{print $1}')"# + "\n"
            s += #"case "$BF_SOURCE_SHA" in \#(BF1942DisplayFix.originalSHA)|\#(BF1942DisplayFix.previousCorrectedSHA)|\#(BF1942DisplayFix.correctedSHA)) ;; *) echo 'Nokcandu: BF1942 changed since the menu fix. Undo its display settings before using this version.'; exit 1 ;; esac"# + "\n"
            s += #"BF_COPY_SHA=$(/usr/bin/shasum -a 256 "$GAME_DIR/BF1942-Nokcandu.exe" | /usr/bin/awk '{print $1}')"# + "\n"
            s += #"[ "$BF_COPY_SHA" = \#(shellQuote(BF1942DisplayFix.correctedSHA)) ] || { echo 'Nokcandu: BF1942 display copy changed. Restore it before launching.'; exit 1; }"# + "\n"
            s += #"BF_RESTART_SHA=$(/usr/bin/shasum -a 256 "$GAME_DIR/BF194N.exe" | /usr/bin/awk '{print $1}')"# + "\n"
            s += #"[ "$BF_RESTART_SHA" = \#(shellQuote(BF1942DisplayFix.correctedSHA)) ] || { echo 'Nokcandu: BF1942 mod restart copy changed. Reapply its display fix.'; exit 1; }"# + "\n"
        }
        let args = splitArguments(c.arguments).map(shellQuote).joined(separator: " ")
        if let link = c.store { s += StoreAccounts.launcherLines(link) }
        let storeArgs = c.store == nil ? "" : #" ${STORE_ARGS[@]+"${STORE_ARGS[@]}"}"#
        s += """
        [ -x "$SUPPORT/wine/bin/wine" ]
        [ -f "$GAME_DIR/"\(shellQuote(exeName)) ]
        if [ "$CHECK_ONLY" = 1 ]; then printf 'Launcher check passed: game and engine are ready.\\n'; exit 0; fi
        \(GameDisplay.launcherLines(c.displayPixels, tool: #""$SUPPORT/nokcandu/screen-size""#, log: #""$LOG_DIR/display.log""#,
                                     pattern: GameDisplay.watchPattern(exeName: c.bf1942MenuCopy == true ? BF1942DisplayFix.copyName : exeName)))cd "$GAME_DIR"
        STATUS=0
        \(c.borderless == true ? #"export NOKCANDU_BORDERLESS_TARGET="$GAME_EXE"; export NOKCANDU_BORDERLESS_DLL='C:\nokcandu\borderless\window.dll'; GAME_EXE='C:\nokcandu\borderless\launcher.exe'"# : "")
        "$SUPPORT/wine/bin/wine" "$GAME_EXE"\(args.isEmpty ? "" : " " + args)\(storeArgs) || STATUS=$?
        echo "nokcandu: game exited with status $STATUS after ${SECONDS}s"
        exit $STATUS

        """
        return HelperPatch.scopeWineLibrary(s)
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
    public static func save(_ config: CustomGameConfig, to game: InstalledGame, force: Bool = false, allowDisplayProgramChange: Bool = false) throws {
        if case .launcherRunning = GameLauncher.runState(of: game) { throw NokError("Quit \(game.name) first.") }
        var c = config
        let installed = CompatibilityFixes.installedIDs(for: game)
        if !allowDisplayProgramChange, BF1942DisplayFix.hasChanges(for: game),
           let old = CustomGameConfig.load(contents: game.contents), old.exe != c.exe {
            throw NokError("Undo BF1942 display settings in Display before changing the game's program.")
        }
        if let old = CustomGameConfig.load(contents: game.contents), old.exe != c.exe, !installed.isEmpty {
            throw NokError("Undo compatibility fixes in Fixes before changing the game's program.")
        }
        if c.legacyD3D9 == true && c.graphics != .classic3D {
            throw NokError("Undo DirectX 8 compatibility in Fixes before changing graphics modes.")
        }
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
