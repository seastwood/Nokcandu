import Foundation

/// The Zero Hour + GeneralsOnline recipe as explicit stages (SETUP GUIDE "Installation sequence").
/// STATUS: implemented but not yet run end-to-end on a clean machine. Each stage verifies its own
/// result, so a wrong assumption stops the install with a message instead of continuing.
public enum ZeroHourInstall {
    public static let steamAppID = 2732960
    public static let generalsOnlineSite = URL(string: "https://www.playgenerals.online/index.php")!
    static let gameDriveLink = "drive_c/Games/Zero Hour"

    public static var stages: [InstallStage] {
        [Preflight(), Runtime(), CreateApp(), Prefix(), EngineTest(), SteamContent(), GameDrive(), Registry(),
         OptionsFile(), GeneralsOnline(), DotNetLauncher(), ICU(), Graphics(), AppBuild(), LauncherCheck(), PlayTest()]
    }

    static func python() -> String? {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] where FileManager.default.isExecutableFile(atPath: p) {
            if (try? Shell.run(p, ["--version"], timeout: 20))?.ok == true { return p }
        }
        return nil
    }

    static func opened(_ ctx: InstallContext, _ id: String) -> Bool { ctx.state.inputs["\(id).opened"] == "1" }
    static func markOpened(_ ctx: InstallContext, _ id: String) throws { ctx.state.inputs["\(id).opened"] = "1"; try ctx.saveState() }

    static func flushRegistry(_ ctx: InstallContext) async throws {
        let ws = ctx.support.appendingPathComponent("wine/bin/wineserver")
        _ = try await Shell.runAsync(ws.path, ["-w"], env: ctx.wineEnvironment, timeout: 120)
    }

    // MARK: Stages

    struct Preflight: InstallStage {
        let info = StageInfo(id: "preflight", title: "Check this Mac",
                             detail: "Free space, Python for the helper scripts, and a safe place for the new app.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { ctx.state.inputs["preflight.ok"] == "1" }
        func run(_ ctx: InstallContext) async throws {
            let need: Int64 = 8 * 1_000_000_000
            if let free = FileManager.default.availableCapacity(at: ctx.targetApp.deletingLastPathComponent()), free < need {
                throw NokError("Needs about 8 GB free; \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available.")
            }
            guard ZeroHourInstall.python() != nil else {
                throw NokError("Python 3 is needed for the launcher helper. Install Apple's Command Line Tools (xcode-select --install) or Homebrew python, then retry.")
            }
            if FileManager.default.fileExists(atPath: ctx.targetApp.path) && !ctx.state.createdTarget {
                throw NokError("\(ctx.targetApp.lastPathComponent) already exists and was not created by this install.")
            }
            ctx.log("Target: \(ctx.targetApp.path)")
            ctx.state.inputs["preflight.ok"] = "1"
            try ctx.saveState()
        }
    }

    struct Runtime: InstallStage {
        let info = StageInfo(id: "runtime", title: "Prepare the game engine",
                             detail: "Caches the tested Wine engine and graphics files (copied from an existing app or downloaded, then hash-checked).", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { RuntimeManager.isCached(ctx.recipe.runtime) }
        func run(_ ctx: InstallContext) async throws {
            if let source = RuntimeManager.importCandidate(for: ctx.recipe, in: ctx.library) {
                try RuntimeManager.importRuntime(for: ctx.recipe, from: source, log: ctx.log)
            } else {
                ctx.log("Downloading the tested Wine engine and graphics files (about 260 MB)…")
                try await Setup.downloadTestedEngine(log: ctx.log)
            }
        }
    }

    struct CreateApp: InstallStage {
        let info = StageInfo(id: "create-app", title: "Create the game app",
                             detail: "A new, separate app with its own private Windows environment. Existing games are not touched.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            FileManager.default.isExecutableFile(atPath: ctx.wine.path) && FileManager.default.fileExists(atPath: ctx.contents.appendingPathComponent("Frameworks").path)
        }
        func run(_ ctx: InstallContext) async throws {
            let fm = FileManager.default
            if !fm.fileExists(atPath: ctx.targetApp.path) {
                ctx.state.createdTarget = true
                try ctx.saveState()
            } else if !ctx.state.createdTarget {
                throw NokError("Refusing to modify an app this install did not create.")
            }
            for d in ["MacOS", "Resources", "SharedSupport/Logs", "SharedSupport/GameFiles"] {
                try fm.createDirectory(at: ctx.contents.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            try Data("APPL????".utf8).write(to: ctx.contents.appendingPathComponent("PkgInfo"))
            ctx.log("Cloning runtime into the app (APFS clone: no extra space until files change)…")
            try RuntimeManager.install(ctx.recipe.runtime, into: ctx.contents)
        }
    }

    struct Prefix: InstallStage {
        let info = StageInfo(id: "prefix", title: "Set up the private Windows environment",
                             detail: "Creates this game's own Wine prefix.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            FileManager.default.fileExists(atPath: ctx.prefix.appendingPathComponent("system.reg").path) &&
            FileManager.default.fileExists(atPath: ctx.prefix.appendingPathComponent("drive_c/windows/syswow64").path)
        }
        func run(_ ctx: InstallContext) async throws {
            let r = try await ctx.runWine(["wineboot", "-i"], timeout: 600)
            try await ZeroHourInstall.flushRegistry(ctx)
            if !r.ok { ctx.log("wineboot exited with \(r.status)") }
        }
    }

    struct EngineTest: InstallStage {
        let info = StageInfo(id: "engine-test", title: "Test the engine",
                             detail: "Runs a basic Windows command. This proves the engine starts — not that graphics or gameplay work.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { ctx.state.inputs["engine-test.ok"] == "1" }
        func run(_ ctx: InstallContext) async throws {
            let r = try await ctx.runWine(["cmd", "/c", "ver"], timeout: 120)
            guard r.stdout.localizedCaseInsensitiveContains("Windows") else {
                throw NokError("The engine did not answer `cmd /c ver` (exit \(r.status)). \(r.stderr.suffix(300))")
            }
            ctx.state.inputs["engine-test.ok"] = "1"
            try ctx.saveState()
        }
    }

    struct SteamContent: InstallStage {
        let info = StageInfo(id: "steam", title: "Download your Steam copy",
                             detail: "Opens Terminal with Valve's SteamCMD. Sign in and approve Steam Guard there — Nokcandu never sees your password. Or choose a folder that already has the Windows game files.",
                             kind: .handoff)
        func isDone(_ ctx: InstallContext) -> Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: ctx.gameFiles.appendingPathComponent("Generals.exe").path) &&
                   fm.fileExists(atPath: ctx.gameFiles.appendingPathComponent("installScript.vdf").path)
        }
        func run(_ ctx: InstallContext) async throws {
            if let existing = ctx.input("existingGameFolder") {
                let src = URL(fileURLWithPath: existing)
                guard FileManager.default.fileExists(atPath: src.appendingPathComponent("Generals.exe").path) else {
                    throw NokError("That folder has no Generals.exe. Choose the Windows Zero Hour folder (the one with installScript.vdf).")
                }
                ctx.log("Cloning game files from \(src.path)…")
                try? FileManager.default.removeItem(at: ctx.gameFiles)    // empty folder created earlier
                try FileManager.default.cloneItem(at: src, to: ctx.gameFiles)
                return
            }
            guard let user = ctx.input("steamUser") else {
                throw NokError("Enter your Steam account name (not your password), or choose an existing game folder.")
            }
            if ZeroHourInstall.opened(ctx, info.id) { return }   // already handed off; just re-check
            guard let steamcmd = Shell.which("steamcmd") else {
                throw NokError("SteamCMD is not installed. Install Valve's SteamCMD (for example `brew install --cask steamcmd`), then press Continue.")
            }
            guard user.range(of: #"^[A-Za-z0-9_.@-]+$"#, options: .regularExpression) != nil else {
                throw NokError("That account name has unexpected characters.")
            }
            try NokPaths.ensure(ctx.workDir)
            let script = ctx.workDir.appendingPathComponent("steam-download.command")
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let body = """
            #!/bin/bash
            # Nokcandu: download your own Steam copy of Zero Hour (Windows content).
            # Sign in and approve Steam Guard below. Nokcandu does not read or store your password.
            set -e
            \(q(steamcmd)) +@sSteamCmdForcePlatformType windows +force_install_dir \(q(ctx.gameFiles.path)) +login \(q(user)) +app_update \(ZeroHourInstall.steamAppID) validate +quit
            echo
            echo "Finished. Return to Nokcandu and press Continue."
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let r = try Shell.run("/usr/bin/open", ["-a", "Terminal", script.path])
            guard r.ok else { throw NokError("Could not open Terminal: \(r.combined)") }
            try ZeroHourInstall.markOpened(ctx, info.id)
            ctx.log("SteamCMD opened in Terminal.")
        }
    }

    struct GameDrive: InstallStage {
        let info = StageInfo(id: "game-drive", title: "Connect the game folder",
                             detail: "Maps C:\\Games\\Zero Hour to the game files.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: ctx.prefix.appendingPathComponent(ZeroHourInstall.gameDriveLink).path)) == "../../../GameFiles"
        }
        func run(_ ctx: InstallContext) async throws {
            let link = ctx.prefix.appendingPathComponent(ZeroHourInstall.gameDriveLink)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../GameFiles")
        }
    }

    struct Registry: InstallStage {
        let info = StageInfo(id: "registry", title: "Register the game",
                             detail: "Writes exactly the registry values from Steam's installScript.vdf.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            let reg = (try? String(contentsOf: ctx.prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
            return reg.contains(#"Wow6432Node\\Electronic Arts\\EA Games\\Command and Conquer Generals Zero Hour]"#) &&
                   reg.contains(#""InstallPath"="C:\\Games\\Zero Hour\\""#)
        }
        func run(_ ctx: InstallContext) async throws {
            let vdfText = try String(contentsOf: ctx.gameFiles.appendingPathComponent("installScript.vdf"), encoding: .utf8)
            let reg = try VDF.registryFile(fromInstallScript: try VDF.parse(vdfText), installDir: #"C:\Games\Zero Hour"#)
            try NokPaths.ensure(ctx.workDir)
            let file = ctx.workDir.appendingPathComponent("install-script.reg")
            try reg.write(to: file, atomically: true, encoding: .utf8)
            ctx.log(reg)
            try await ctx.runWine(["regedit", "/S", file.path], timeout: 120)
            try await ZeroHourInstall.flushRegistry(ctx)
        }
    }

    struct OptionsFile: InstallStage {
        let info = StageInfo(id: "options", title: "Starting game settings",
                             detail: "Creates Options.ini (1280 × 800, Medium detail, antialiasing off) only if you don't have one. Existing settings and saves are kept.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { FileManager.default.fileExists(atPath: DisplayController.optionsURL.path) }
        func run(_ ctx: InstallContext) async throws {
            let text = "AntiAliasing = 0\nResolution = 1280 800\nStaticGameLOD = Medium\n"
            try ctx.journal.write(Data(text.utf8), to: DisplayController.optionsURL, reason: "Initial Options.ini")
        }
    }

    struct GeneralsOnline: InstallStage {
        let info = StageInfo(id: "generalsonline", title: "Install GeneralsOnline",
                             detail: "Download the official installer from playgenerals.online, choose it here, and follow its own steps and agreements. When it asks: game = C:\\Games\\Zero Hour\\Generals.exe; options = Documents\\Command and Conquer Generals Zero Hour Data\\Options.ini.",
                             kind: .handoff, needs: ["goInstaller"])
        func isDone(_ ctx: InstallContext) -> Bool {
            FileManager.default.fileExists(atPath: ctx.gameFiles.appendingPathComponent("GeneralsOnlineZH.exe").path) &&
            FileManager.default.fileExists(atPath: ctx.prefix.appendingPathComponent("drive_c/Program Files (x86)/dotnet/dotnet.exe").path)
        }
        func run(_ ctx: InstallContext) async throws {
            guard let path = ctx.input("goInstaller") else { return }
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.lowercased() == "exe", FileManager.default.fileExists(atPath: path) else {
                throw NokError("Choose the GeneralsOnline installer (.exe) you downloaded.")
            }
            if ZeroHourInstall.opened(ctx, info.id) { return }
            try ZeroHourInstall.markOpened(ctx, info.id)
            ctx.log("Starting the official installer. Complete it in its own window…")
            let r = try await ctx.runWine([path], cwd: url.deletingLastPathComponent(), timeout: 3 * 3600)
            ctx.log("Installer closed (exit \(r.status)).")
        }
    }

    struct DotNetLauncher: InstallStage {
        let info = StageInfo(id: "dotnet-launcher", title: "Launcher compatibility",
                             detail: "Extracts the unmodified .NET launcher files from GeneralsOnlineZH.exe (the original stays untouched).", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            guard let cache = try? String(contentsOf: ctx.gameFiles.appendingPathComponent(".wine-launcher-sha256"), encoding: .utf8),
                  let sha = try? Hashing.sha256(file: ctx.gameFiles.appendingPathComponent("GeneralsOnlineZH.exe")) else { return false }
            return cache.trimmingCharacters(in: .whitespacesAndNewlines) == sha &&
                FileManager.default.fileExists(atPath: ctx.contents.appendingPathComponent("Resources/refresh-launcher.py").path)
        }
        func run(_ ctx: InstallContext) async throws {
            guard let helper = NokPaths.bundledResource("refresh-generals-launcher.py") else { throw NokError("Helper missing from Nokcandu.app") }
            let dst = ctx.contents.appendingPathComponent("Resources/refresh-launcher.py")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: helper, to: dst)
            guard let py = ZeroHourInstall.python() else { throw NokError("Python 3 not found") }
            let r = try await Shell.runAsync(py, ["-I", dst.path, ctx.gameFiles.path], timeout: 300)
            ctx.log(r.combined)
            guard r.ok else { throw NokError("Launcher extraction stopped: \(r.stderr.suffix(400))") }
        }
    }

    struct ICU: InstallStage {
        let info = StageInfo(id: "icu", title: "Time-zone support",
                             detail: "Downloads Microsoft's official ICU 72.1.0.3 package over HTTPS, checks pinned hashes, and adds the small icu.dll adapter.", kind: .automatic)
        func sys(_ ctx: InstallContext) -> URL { ctx.prefix.appendingPathComponent("drive_c/windows/syswow64") }
        func isDone(_ ctx: InstallContext) -> Bool {
            var want = ICUPins.dlls
            want["icu.dll"] = ICUPins.adapter
            return want.allSatisfy { (name, sha) in (try? Hashing.sha256(file: sys(ctx).appendingPathComponent(name))) == sha }
        }
        func run(_ ctx: InstallContext) async throws {
            let fm = FileManager.default
            var pkg: URL
            if let local = ctx.input("icuPackage") {
                pkg = URL(fileURLWithPath: local)
            } else {
                try NokPaths.ensure(NokPaths.downloads)
                pkg = NokPaths.downloads.appendingPathComponent(ICUPins.packageURL.lastPathComponent)
                if !fm.fileExists(atPath: pkg.path) {
                    ctx.log("Downloading \(ICUPins.packageURL.absoluteString)")
                    let (tmp, resp) = try await URLSession.shared.download(from: ICUPins.packageURL)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NokError("Download failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)).") }
                    try fm.moveItem(at: tmp, to: pkg)
                }
            }
            let unpack = ctx.workDir.appendingPathComponent("icu-package")
            try? fm.removeItem(at: unpack)
            try NokPaths.ensure(unpack)
            let r = try Shell.run("/usr/bin/ditto", ["-x", "-k", pkg.path, unpack.path])
            guard r.ok else { throw NokError("Could not unpack the ICU package: \(r.combined)") }
            let native = unpack.appendingPathComponent("runtimes/win-x86/native")
            for (name, sha) in ICUPins.dlls {
                let f = native.appendingPathComponent(name)
                guard (try? Hashing.sha256(file: f)) == sha else { throw NokError("\(name) is missing or does not match the pinned Microsoft build; stopped.") }
            }
            for name in ICUPins.dlls.keys {
                let dst = sys(ctx).appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: native.appendingPathComponent(name), to: dst)
            }
            guard let builder = NokPaths.bundledResource("build-icu-adapter.py"), let py = ZeroHourInstall.python() else {
                throw NokError("ICU adapter helper missing")
            }
            let adapter = sys(ctx).appendingPathComponent("icu.dll")
            let b = try await Shell.runAsync(py, ["-I", builder.path, native.path, adapter.path], timeout: 60)
            ctx.log(b.combined)
            guard (try? Hashing.sha256(file: adapter)) == ICUPins.adapter else { throw NokError("The generated icu.dll adapter does not match the validated one.") }
            if let lic = (try? fm.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.uppercased().hasPrefix("LICENSE") }) {
                let dst = ctx.contents.appendingPathComponent("Resources/Microsoft-ICU-LICENSE.txt")
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: lic, to: dst)
            } else {
                ctx.log("Note: no LICENSE file found in the package; retain Microsoft's license manually.")
            }
        }
    }

    struct Graphics: InstallStage {
        let info = StageInfo(id: "graphics", title: "Validated graphics settings",
                             detail: "Applies the tested renderer settings and checks Wine's own Direct3D files are the originals.", kind: .automatic)
        static let reg = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
        "csmt"=dword:00000000

        [HKEY_CURRENT_USER\\Software\\Microsoft\\Avalon.Graphics]
        "DisableHWAcceleration"=dword:00000001

        [HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\GeneralsOnlineZH_60.exe\\Mac Driver]
        "CaptureDisplaysForFullscreen"="n"

        """
        func isDone(_ ctx: InstallContext) -> Bool {
            let u = (try? String(contentsOf: ctx.prefix.appendingPathComponent("user.reg"), encoding: .utf8)) ?? ""
            return u.contains("\"csmt\"=dword:00000000") && u.contains("\"DisableHWAcceleration\"=dword:00000001") &&
                   u.contains("\"CaptureDisplaysForFullscreen\"=\"n\"") && systemDLLsOriginal(ctx)
        }
        func systemDLLsOriginal(_ ctx: InstallContext) -> Bool {
            ["d3d8.dll", "d3d9.dll"].allSatisfy { n in
                let rel = "SharedSupport/prefix/drive_c/windows/syswow64/\(n)"
                return (try? Hashing.sha256(file: ctx.contents.appendingPathComponent(rel))) == ctx.recipe.pinnedHashes[rel]
            }
        }
        func run(_ ctx: InstallContext) async throws {
            let file = ctx.workDir.appendingPathComponent("graphics.reg")
            try Self.reg.write(to: file, atomically: true, encoding: .utf8)
            try await ctx.runWine(["regedit", "/S", file.path], timeout: 120)
            try await ZeroHourInstall.flushRegistry(ctx)
            if !systemDLLsOriginal(ctx) {
                throw NokError("Wine's system d3d8/d3d9 DLLs are not the originals for this engine. The renderer must come from renderer/d9vk only.")
            }
        }
    }

    struct AppBuild: InstallStage {
        let info = StageInfo(id: "app-build", title: "Finish the Mac app",
                             detail: "Adds the validated launcher, display helper, original game icon, and app details.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            let launcher = ctx.contents.appendingPathComponent("MacOS/generals-launcher")
            guard let sha = try? Hashing.sha256(file: launcher) else { return false }
            return ctx.recipe.knownLauncherHashes[sha] != nil &&
                FileManager.default.fileExists(atPath: ctx.contents.appendingPathComponent("Info.plist").path) &&
                FileManager.default.isExecutableFile(atPath: ctx.contents.appendingPathComponent("Resources/screen-size").path)
        }
        func run(_ ctx: InstallContext) async throws {
            let fm = FileManager.default
            guard let template = NokPaths.bundledResource("generals-launcher"),
                  let screen = NokPaths.bundledResource("screen-size") else { throw NokError("Launcher template missing from Nokcandu.app") }
            let launcher = ctx.contents.appendingPathComponent("MacOS/generals-launcher")
            try? fm.removeItem(at: launcher)
            try fm.copyItem(at: template, to: launcher)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            let screenDst = ctx.contents.appendingPathComponent("Resources/screen-size")
            try? fm.removeItem(at: screenDst)
            try fm.copyItem(at: screen, to: screenDst)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: screenDst.path)

            var iconFile = ""
            let ico = ctx.gameFiles.appendingPathComponent("GeneralsZH.ico")
            let icns = ctx.contents.appendingPathComponent("Resources/GeneralsZeroHour.icns")
            if fm.fileExists(atPath: ico.path) {
                let png = ctx.workDir.appendingPathComponent("icon.png")
                _ = try? Shell.run("/usr/bin/sips", ["-s", "format", "png", ico.path, "--out", png.path])
                let r = try? Shell.run("/usr/bin/sips", ["-s", "format", "icns", png.path, "--out", icns.path])
                if r?.ok == true, fm.fileExists(atPath: icns.path) { iconFile = icns.lastPathComponent }
            }
            if iconFile.isEmpty { ctx.log("Note: could not convert the original icon automatically; the app works without it.") }

            let info: [String: Any] = [
                "CFBundleDevelopmentRegion": "English",
                "CFBundleExecutable": "generals-launcher",
                "CFBundleIconFile": iconFile,
                "CFBundleIdentifier": "local.nokcandu.generalszerohour.\(ctx.state.installID)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": ctx.targetApp.deletingPathExtension().lastPathComponent,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.6",
                "NSBGOnly": "1",
                "NSHighResolutionCapable": true,
                "NokcanduRecipe": ctx.recipe.id,
                "D9VK": 1,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info.merging(AppPrivacy.keys) { a, _ in a }, format: .xml, options: 0)
            try data.write(to: ctx.contents.appendingPathComponent("Info.plist"))
            _ = try? Shell.run("/usr/bin/touch", [ctx.targetApp.path])
        }
    }

    struct LauncherCheck: InstallStage {
        let info = StageInfo(id: "check", title: "Launcher self-check",
                             detail: "Runs the app's own preflight (game files, engine, .NET launcher).", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { ctx.state.inputs["check.ok"] == "1" }
        func run(_ ctx: InstallContext) async throws {
            let r = try await Shell.runAsync("/bin/bash", [ctx.contents.appendingPathComponent("MacOS/generals-launcher").path, "--check"], timeout: 300)
            ctx.log(r.combined)
            guard r.ok else { throw NokError("Self-check failed: \(r.combined.suffix(400))") }
            ctx.state.inputs["check.ok"] = "1"
            try ctx.saveState()
        }
    }

    struct PlayTest: InstallStage {
        let info = StageInfo(id: "playtest", title: "Play test",
                             detail: "Open the new app, start a skirmish, and play a minute. Confirm only if it actually played smoothly — a running process is not proof.",
                             kind: .handoff, needs: ["playtest"])
        func isDone(_ ctx: InstallContext) -> Bool { ctx.state.inputs["playtest"] == "confirmed" }
        func run(_ ctx: InstallContext) async throws {}
    }
}
