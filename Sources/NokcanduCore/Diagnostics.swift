import Foundation

/// Diagnostics keep failure layers apart so "it doesn't start" can be narrowed down.
/// They never treat "process running" as proof of playable gameplay.
public enum DiagLayer: String, CaseIterable, Codable, Identifiable {
    case app = "App & launcher"
    case runtime = "Wine runtime"
    case dotnet = "Launcher / .NET"
    case rendering = "Rendering"
    case display = "Display"
    case disc = "Disc"
    case network = "Networking & anti-cheat"
    case process = "Running state"
    public var id: String { rawValue }
}

public enum DiagStatus: String, Codable { case ok, warning, failure, info
    public var symbol: String { switch self { case .ok: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .failure: "xmark.octagon.fill"; case .info: "info.circle" } }
}

public struct DiagCheck: Identifiable, Codable, Hashable {
    public var id = UUID()
    public var layer: DiagLayer
    public var title: String
    public var status: DiagStatus
    public var detail: String
}

public struct DiagReport {
    public var game: InstalledGame
    public var date = Date()
    public var checks: [DiagCheck]
    public var logs: [(name: String, tail: String)]

    public var worst: DiagStatus {
        if checks.contains(where: { $0.status == .failure }) { return .failure }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        return .ok
    }

    public func text() -> String {
        var out = "Nokcandu diagnostics — \(game.name)\n\(ISO8601DateFormatter().string(from: date))\n"
        out += "App: \(game.appURL.path)\nRecipe: \(game.recipe?.id ?? "none (not managed)")\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        for layer in DiagLayer.allCases {
            let cs = checks.filter { $0.layer == layer }
            guard !cs.isEmpty else { continue }
            out += "## \(layer.rawValue)\n"
            for c in cs { out += "[\(c.status.rawValue.uppercased())] \(c.title): \(c.detail)\n" }
            out += "\n"
        }
        for l in logs { out += "## Log: \(l.name) (last lines)\n\(l.tail)\n\n" }
        return out
    }

    /// Writes the report to Application Support/Nokcandu/Diagnostics and returns its URL.
    public func save() throws -> URL {
        try NokPaths.ensure(NokPaths.diagnostics)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = NokPaths.diagnostics.appendingPathComponent("\(game.name)-\(f.string(from: date)).txt")
        try text().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

public enum Diagnostics {
    public static func collect(_ g: InstalledGame, includeHashes: Bool = true) -> DiagReport {
        if g.usesSharedSteam { return collectSteamGame(g) }
        if g.battleNet != nil { return collectBattleNetGame(g) }
        var c: [DiagCheck] = []
        let fm = FileManager.default
        func add(_ l: DiagLayer, _ t: String, _ s: DiagStatus, _ d: String) { c.append(DiagCheck(layer: l, title: t, status: s, detail: d)) }
        func exists(_ rel: String) -> Bool { fm.fileExists(atPath: g.contents.appendingPathComponent(rel).path) }

        // App & launcher
        if let l = g.launcherURL, fm.isExecutableFile(atPath: l.path) {
            let sha = (try? Hashing.sha256(file: l)) ?? "?"
            if let known = g.recipe?.knownLauncherHashes[sha] {
                add(.app, "Launcher", .ok, known)
            } else if g.recipe?.display != nil, DisplayController.launcherState(g) == .nokcanduPatched {
                add(.app, "Launcher", .ok, "Validated launcher + Nokcandu display setting")
            } else if g.recipe != nil {
                add(.app, "Launcher", .warning, "Differs from the validated launcher (sha256 \(sha.prefix(12))…). Updates or manual edits can cause this.")
            } else {
                add(.app, "Launcher", .info, "\(l.lastPathComponent) (no recipe to compare against)")
            }
        } else {
            add(.app, "Launcher", .failure, "Launcher script missing or not executable.")
        }
        add(.app, "Icon", g.iconURL != nil ? .ok : .warning, g.iconURL?.lastPathComponent ?? "No icon file set")
        if let r = g.recipe, let dir = g.gameDirectory {
            let exe = dir.appendingPathComponent(r.primaryExecutable)
            add(.app, "Game files", fm.fileExists(atPath: exe.path) ? .ok : .failure,
                fm.fileExists(atPath: exe.path) ? "\(r.primaryExecutable) present" : "\(r.primaryExecutable) not found in \(dir.lastPathComponent)")
        }

        // Runtime
        let wine = g.support.appendingPathComponent("wine/bin/wine")
        if fm.isExecutableFile(atPath: wine.path) {
            let v = g.wineVersion ?? "unknown"
            if let u = EngineUpdate.state(for: g) {
                add(.runtime, "Wine engine", .info, "\(v) — updated by you (\(u.status == .trying ? "trying" : "kept")); Nokcandu tested \(EngineVersion.tested)")
            } else if let want = g.recipe?.runtime.wineVersionString {
                add(.runtime, "Wine engine", v == want ? .ok : .warning, v == want ? "\(g.recipe!.runtime.engine) (\(v))" : "Found \(v); recipe expects \(want)")
            } else {
                add(.runtime, "Wine engine", .info, v)
            }
        } else {
            add(.runtime, "Wine engine", .failure, "SharedSupport/wine/bin/wine missing")
        }
        add(.runtime, "Bundled frameworks", exists("Frameworks") ? .ok : .failure, exists("Frameworks") ? "Present" : "Contents/Frameworks missing")
        add(.runtime, "Private prefix", fm.isDirectory(g.prefix.appendingPathComponent("drive_c")) ? .ok : .failure, "SharedSupport/prefix")

        // Pinned hashes, grouped to their layer
        if includeHashes, let r = g.recipe {
            let updated = EngineUpdate.state(for: g) != nil
            for (rel, want) in r.pinnedHashes.sorted(by: { $0.key < $1.key }) where !(updated && RuntimeManager.components.contains { rel.hasPrefix($0 + "/") }) {
                let layer: DiagLayer = rel.contains("renderer") || rel.contains("vulkan") || rel.hasSuffix("d3d8.dll") || rel.hasSuffix("d3d9.dll")
                    ? .rendering : (rel.contains("icu") ? .dotnet : .runtime)
                let url = g.contents.appendingPathComponent(rel)
                var name = (rel as NSString).lastPathComponent
                if rel.contains("renderer/") { name += " (renderer)" } else if rel.contains("syswow64/d3d") { name += " (Wine system)" }
                guard fm.fileExists(atPath: url.path) else { add(layer, name, .failure, "Missing: \(rel)"); continue }
                let got = (try? Hashing.sha256(file: url)) ?? ""
                add(layer, name, got == want ? .ok : .warning, got == want ? "Matches recipe" : "Hash differs from the validated file (\(got.prefix(12))…)")
            }
        }

        // .NET launcher (Zero Hour)
        if g.recipe?.id == RecipeCatalog.zeroHour.id, let dir = g.gameDirectory {
            let dotnet = g.prefix.appendingPathComponent("drive_c/Program Files (x86)/dotnet/dotnet.exe")
            add(.dotnet, "x86 .NET host", fm.fileExists(atPath: dotnet.path) ? .ok : .failure, fm.fileExists(atPath: dotnet.path) ? "dotnet.exe present" : "dotnet.exe missing")
            let desktopRT = g.prefix.appendingPathComponent("drive_c/Program Files (x86)/dotnet/shared/Microsoft.WindowsDesktop.App")
            let versions = (try? fm.contentsOfDirectory(atPath: desktopRT.path))?.sorted() ?? []
            add(.dotnet, "Windows Desktop Runtime", versions.isEmpty ? .failure : .ok, versions.isEmpty ? "Not installed" : versions.joined(separator: ", "))
            let packed = dir.appendingPathComponent("GeneralsOnlineZH.exe")
            let cache = (try? String(contentsOf: dir.appendingPathComponent(".wine-launcher-sha256"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = try? Hashing.sha256(file: packed)
            let parts = ["Launcher.dll", "Launcher.runtimeconfig.json", "Launcher.deps.json", "Sentry.dll"].filter { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            if current == nil {
                add(.dotnet, "GeneralsOnline launcher", .failure, "GeneralsOnlineZH.exe missing")
            } else if cache == current && parts.isEmpty {
                add(.dotnet, "GeneralsOnline launcher", .ok, "Extracted components match the installed client")
            } else {
                add(.dotnet, "GeneralsOnline launcher", .warning, "Client changed since extraction (or parts missing: \(parts.joined(separator: ", "))). The next launch re-extracts automatically; an unknown bundle format will stop with a clear message.")
            }
            let userReg = (try? String(contentsOf: g.prefix.appendingPathComponent("user.reg"), encoding: .utf8)) ?? ""
            add(.dotnet, "Launcher UI acceleration off", userReg.contains("DisableHWAcceleration\"=dword:00000001") ? .ok : .warning, "HKCU\\Software\\Microsoft\\Avalon.Graphics")
            add(.rendering, "Direct3D csmt", userReg.contains("\"csmt\"=dword:00000000") ? .ok : .info, "csmt=0 (retained from the validated setup)")
            add(.display, "Wine display capture", userReg.contains("\"CaptureDisplaysForFullscreen\"=\"n\"") ? .ok : .warning, "CaptureDisplaysForFullscreen=n for GeneralsOnlineZH_60.exe")
            let icd = g.contents.appendingPathComponent("Resources/vulkan/icd.d/kosmickrisp_mesa_icd.json")
            add(.rendering, "Vulkan driver manifest", fm.fileExists(atPath: icd.path) ? .ok : .failure, "KosmicKrisp ICD")
            if let log = tailOfFile(g.logs.appendingPathComponent("GeneralsOnlineZH_60_d3d9.log"), maxLines: 400),
               let line = log.components(separatedBy: .newlines).first(where: { $0.contains("Found device") }) {
                add(.rendering, "Last renderer start", .info, line.replacingOccurrences(of: "info:", with: "").trimmingCharacters(in: .whitespaces))
            }
            let eac = dir.appendingPathComponent("EasyAntiCheat")
            add(.network, "Anti-cheat files", fm.isDirectory(eac) ? .info : .warning, fm.isDirectory(eac) ? "EasyAntiCheat present (left untouched)" : "EasyAntiCheat folder missing")
            add(.network, "Online play", .info, "Not validated — a real online match with the official client checks intact is still pending.")
        }

        if let spec = GameDataSpec.forGame(g) {
            let missing = spec.missingEssentials
            add(.app, "Settings folder (outside the app)", missing.isEmpty ? .ok : .failure,
                missing.isEmpty ? spec.title : "Missing \(missing.joined(separator: ", ")) in \(spec.title). Use Repair.")
        }

        // Display
        if DisplayController.supports(g) {
            let s = DisplayController.status(g)
            add(.display, "Mode", s.consistent ? .ok : .warning,
                "\(s.mode.title); desktop \(s.desktop); Options.ini \(s.optionsResolution ?? "n/a"); launcher.json windowed=\(s.launcherJSONWindowed.map { String($0) } ?? "n/a")")
        } else {
            add(.display, "Mode", .info, "Game uses its own display settings (not managed by Nokcandu).")
        }

        // Disc
        if let disc = g.recipe?.disc {
            let iso = g.support.appendingPathComponent(disc.imageName)
            add(.disc, "Disc image", fm.fileExists(atPath: iso.path) ? .ok : .failure, disc.imageName)
            let dLink = try? fm.destinationOfSymbolicLink(atPath: g.prefix.appendingPathComponent("dosdevices/d:").path)
            let rawLink = try? fm.destinationOfSymbolicLink(atPath: g.prefix.appendingPathComponent("dosdevices/d::").path)
            add(.disc, "Drive D: mapping", dLink != nil ? .info : .warning, "d: → \(dLink ?? "none"), d:: → \(rawLink ?? "none") (refreshed by the launcher each start)")
            let mounted = ["/Volumes/\(disc.volumeLabel)", g.contents.appendingPathComponent(disc.internalMountDir).path].first { path in
                (try? Shell.run("/usr/sbin/diskutil", ["info", path], timeout: 10))?.stdout.contains("Volume Name:              \(disc.volumeLabel)") == true
            }
            add(.disc, "Disc mounted", .info, mounted.map { "Mounted at \($0)" } ?? "Not mounted now (mounted read-only automatically at launch)")
        }

        // Process
        switch GameLauncher.runState(of: g) {
        case .notRunning: add(.process, "Launcher", .info, "Not running")
        case .launcherRunning(let pid): add(.process, "Launcher", .info, "Running (pid \(pid)). This only shows the launcher is alive — not that gameplay works.")
        }

        var logs: [(String, String)] = []
        if let names = try? fm.contentsOfDirectory(atPath: g.logs.path) {
            for n in names.sorted() where n.hasSuffix(".log") {
                if let t = tailOfFile(g.logs.appendingPathComponent(n), maxLines: 40) { logs.append((n, t)) }
            }
        }
        c.append(contentsOf: audioDriverChecks(g))
        return DiagReport(game: g, checks: c, logs: logs)
    }

    /// Steam-library games: this app is only a launcher; the game lives in the shared Steam app.
    static func collectSteamGame(_ g: InstalledGame) -> DiagReport {
        var c: [DiagCheck] = []
        func add(_ l: DiagLayer, _ t: String, _ s: DiagStatus, _ d: String) { c.append(DiagCheck(layer: l, title: t, status: s, detail: d)) }
        let cfg = g.custom!
        if let l = g.launcherURL, let sha = try? Hashing.sha256(file: l) {
            add(.app, "Launcher", sha == cfg.launcherSHA ? .ok : .warning, sha == cfg.launcherSHA ? "Nokcandu-generated (starts app \(cfg.steamAppID ?? 0) through shared Steam)" : "Changed outside Nokcandu")
        } else { add(.app, "Launcher", .failure, "Missing") }
        add(.app, "Icon", g.iconURL != nil ? .ok : .warning, g.iconURL?.lastPathComponent ?? "No icon")
        add(.runtime, "Shared Steam app", SharedSteam.isSetUp ? .ok : .failure, SharedSteam.isSetUp ? SharedSteam.appURL.path : "Not set up — open Steam Library in Nokcandu")
        if let id = cfg.steamAppID {
            let game = SharedSteam.installedGames().first { $0.appID == id }
            add(.app, "Installed in Steam", game?.installed == true ? .ok : .failure,
                game.map { $0.installed ? "\($0.name) · \(ByteCountFormatter.string(fromByteCount: $0.sizeOnDisk ?? 0, countStyle: .file))" : "Download not finished" } ?? "Not installed in the shared Steam")
        }
        add(.rendering, "Graphics", cfg.graphics.validated ? .ok : .info, "\(cfg.graphics.title) — \(cfg.graphics.technical)\(cfg.confirmedGraphics == cfg.graphics ? " (you confirmed it plays well)" : "")")
        if let mode = SharedSteam.runningMode {
            add(.process, "Steam", .info, "Running in \(mode.title) mode\(mode == cfg.graphics ? "" : " — this game will ask to restart Steam")")
        } else {
            add(.process, "Steam", .info, "Not running")
        }
        add(.network, "Online play", .info, "Valve's anti-cheat (VAC) under Wine is not officially supported; no confirmed bans, but the risk isn't zero.")
        var logs: [(String, String)] = []
        let steamLog = SharedSteam.contents.appendingPathComponent("SharedSupport/Logs/steam.log")
        if let t = tailOfFile(steamLog, maxLines: 40) { logs.append(("steam.log (shared Steam)", t)) }
        c.append(contentsOf: audioDriverChecks(g))
        return DiagReport(game: g, checks: c, logs: logs)
    }

    static func collectBattleNetGame(_ g: InstalledGame) -> DiagReport {
        var c: [DiagCheck] = []
        func add(_ l: DiagLayer, _ t: String, _ s: DiagStatus, _ d: String) { c.append(DiagCheck(layer: l, title: t, status: s, detail: d)) }
        let link = g.battleNet!
        if let l = g.launcherURL, let sha = try? Hashing.sha256(file: l) {
            let want = Hashing.sha256(data: Data(BattleNet.launcherScript(link).utf8))
            add(.app, "Launcher", sha == want ? .ok : .warning, sha == want ? "Starts \(link.code) through Battle.net" : "Changed outside Nokcandu")
        } else { add(.app, "Launcher", .failure, "Missing") }
        let hostURL = URL(fileURLWithPath: link.hostApp)
        let host = GameLibrary.inspect(hostURL)
        add(.runtime, "Battle.net app", host != nil ? .ok : .failure, host != nil ? link.hostApp : "Not found at \(link.hostApp)")
        if let h = host {
            let game = BattleNet.installedGames(host: h).first { $0.uid == link.uid }
            add(.app, "Installed in Battle.net", game != nil ? .ok : .failure, game.map { "\($0.name) · \($0.installLocation)" } ?? "Not installed (install it in Battle.net)")
            if let loc = game?.installLocation, let u = BattleNet.unixPath(loc, prefix: h.prefix) {
                add(.app, "Game files", FileManager.default.fileExists(atPath: u.path) ? .ok : .failure,
                    FileManager.default.fileExists(atPath: u.path) ? u.path : "\(u.path) not found — is the drive connected?")
            }
            add(.rendering, "Graphics", .info, "Uses Battle.net's: \(h.custom?.graphics.title ?? "?")")
        }
        return DiagReport(game: g, checks: c, logs: [])
    }

    /// Nokcandu's fixes to Wine's audio driver (microphone input, buffer size) still apply to this engine?
    static func audioDriverChecks(_ g: InstalledGame) -> [DiagCheck] {
        guard let h = WineTools.hostContents(for: g) else { return [] }
        switch AudioBuffer.status(host: h) {
        case .fixed:
            return [DiagCheck(layer: .runtime, title: "Audio driver", status: .ok, detail: "Microphone fix and audio buffer setting apply to this engine")]
        case .needsFix:
            return [DiagCheck(layer: .runtime, title: "Audio driver", status: .warning, detail: "Microphone fix not applied yet — it's applied when Nokcandu next starts")]
        case .unrecognized:
            return [DiagCheck(layer: .runtime, title: "Audio driver", status: .warning, detail: "This engine's audio driver isn't the version Nokcandu knows: microphones may not work and the audio buffer setting is unavailable. Report it on GitHub so Nokcandu can be updated.")]
        case .missing:
            return []
        }
    }
}
