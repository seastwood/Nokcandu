import Foundation

/// General installer: any owned Windows game → its own Mac app with a private Wine prefix.
/// Stages are the same shape as the Zero Hour recipe (resumable, journaled, self-checking), but the
/// game-specific parts are chosen by the user: source, the game's .exe, and a graphics mode.
public enum CustomInstall {
    public static let recipeID = "custom"

    /// Placeholder recipe used while installing (runtime + folders); the real one comes from game.json.
    static func installRecipe(name: String) -> GameRecipe {
        var r = CustomGameConfig(id: CustomGames.slug(name), name: name, source: .installer,
                                 exe: "C:\\Games\\\(CustomGames.safeFolderName(name))\\game.exe", graphics: .classic3D).recipe
        r.id = recipeID
        r.pinnedHashes = RecipeCatalog.zeroHour.pinnedHashes.filter { RuntimeManager.components.contains(where: $0.key.hasPrefix) }
        return r
    }

    public static func stages(for source: GameSource) -> [InstallStage] {
        [Preflight(), ZeroHourInstall.Runtime(), ZeroHourInstall.CreateApp(), ZeroHourInstall.Prefix(), ZeroHourInstall.EngineTest(),
         Acquire(source: source), ChooseExe(source: source), Graphics(), Build(), Check(), PlayTest()]
    }

    static func name(_ ctx: InstallContext) -> String { ctx.input("name") ?? "Game" }
    static func source(_ ctx: InstallContext) -> GameSource { ctx.input("source").flatMap(GameSource.init(rawValue:)) ?? .installer }
    static func gamesFolder(_ ctx: InstallContext) -> URL {
        ctx.prefix.appendingPathComponent("drive_c/Games/\(CustomGames.safeFolderName(name(ctx)))")
    }
    static var steamDir: String { "drive_c/Program Files (x86)/Steam" }

    // MARK: Stages

    struct Preflight: InstallStage {
        let info = StageInfo(id: "preflight", title: "Check this Mac", detail: "Free space and a safe place for the new app.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { ctx.state.inputs["preflight.ok"] == "1" }
        func run(_ ctx: InstallContext) async throws {
            var need: Int64 = 3_000_000_000
            for key in ["installerPath", "isoPath"] {
                if let p = ctx.input(key), let s = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int64 { need += s * 3 }
            }
            if let free = FileManager.default.availableCapacity(at: ctx.targetApp.deletingLastPathComponent()), free < need {
                throw NokError("Needs about \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) free; \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available. Steam games also need room for the game itself.")
            }
            if FileManager.default.fileExists(atPath: ctx.targetApp.path) && !ctx.state.createdTarget {
                throw NokError("\(ctx.targetApp.lastPathComponent) already exists.")
            }
            ctx.state.inputs["preflight.ok"] = "1"
            try ctx.saveState()
        }
    }

    struct Acquire: InstallStage {
        let source: GameSource
        var info: StageInfo {
            switch source {
            case .installer:
                return StageInfo(id: "acquire", title: "Run the game's installer",
                                 detail: "Choose the setup .exe or .msi. It opens in its own window — install to C:\\Games if it asks, and accept only what you agree to. Typing paths works better than pasting there.",
                                 kind: .handoff, needs: ["installerPath"])
            case .disc:
                return StageInfo(id: "acquire", title: "Install from the disc image",
                                 detail: "Choose the game's .iso. Nokcandu keeps a copy inside the app, mounts it read-only as drive D:, and starts the disc's setup.",
                                 kind: .handoff, needs: ["isoPath"])
            case .steamLibrary:
                return StageInfo(id: "acquire", title: "Install Steam and the game",
                                 detail: "1. Download SteamSetup.exe from Steam's site and choose it here. 2. Steam opens inside the app: sign in (Steam Guard happens there) and install the game. 3. When Steam says it's installed, quit Steam and press Continue.",
                                 kind: .handoff, needs: ["steamAppID", "steamSetup"])
            case .steam:
                return StageInfo(id: "acquire", title: "Download your Steam copy",
                                 detail: "Opens Terminal with Valve's SteamCMD. Sign in and approve Steam Guard there — Nokcandu never sees your password.",
                                 kind: .handoff, needs: ["steamUser", "steamAppID"])
            case .folder:
                return StageInfo(id: "acquire", title: "Copy the game folder",
                                 detail: "Choose the folder that contains the game's .exe. It's copied into the new app (APFS clone when possible).",
                                 kind: .automatic, needs: ["folderPath"])
            }
        }

        func isDone(_ ctx: InstallContext) -> Bool {
            switch source {
            case .steamLibrary:
                guard let id = ctx.input("steamAppID") else { return false }
                let manifest = ctx.prefix.appendingPathComponent("\(CustomInstall.steamDir)/steamapps/appmanifest_\(id).acf")
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let node = try? VDF.parse(text), let flags = node["AppState"]?["StateFlags"]?.string.flatMap(Int.init) else { return false }
                return flags & 4 != 0   // "fully installed"
            case .steam, .folder:
                return !CustomGames.findExecutables(prefix: ctx.prefix, nameHint: CustomInstall.name(ctx), limit: 1).isEmpty
                    && FileManager.default.fileExists(atPath: CustomInstall.gamesFolder(ctx).path)
            case .installer, .disc:
                return ctx.state.inputs["acquire.finished"] == "1"
                    && !CustomGames.findExecutables(prefix: ctx.prefix, nameHint: CustomInstall.name(ctx), limit: 1).isEmpty
            }
        }

        func run(_ ctx: InstallContext) async throws {
            switch source {
            case .folder: try copyFolder(ctx)
            case .installer: try await runInstaller(ctx)
            case .disc: try await installFromDisc(ctx)
            case .steam: try steamCMD(ctx)
            case .steamLibrary: try await steamLibrary(ctx)
            }
        }

        func copyFolder(_ ctx: InstallContext) throws {
            guard let p = ctx.input("folderPath") else { return }
            let src = URL(fileURLWithPath: p)
            let dst = CustomInstall.gamesFolder(ctx)
            guard FileManager.default.isDirectory(src) else { throw NokError("That isn't a folder.") }
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            ctx.log("Copying \(src.path)…")
            try FileManager.default.cloneItem(at: src, to: dst)
        }

        func runInstaller(_ ctx: InstallContext) async throws {
            guard let p = ctx.input("installerPath") else { return }
            if ZeroHourInstall.opened(ctx, info.id) { return markFinished(ctx) }
            let url = URL(fileURLWithPath: p)
            guard ["exe", "msi"].contains(url.pathExtension.lowercased()), FileManager.default.fileExists(atPath: p) else {
                throw NokError("Choose a Windows setup file (.exe or .msi).")
            }
            try FileManager.default.createDirectory(at: CustomInstall.gamesFolder(ctx), withIntermediateDirectories: true)
            try ZeroHourInstall.markOpened(ctx, info.id)
            ctx.log("Starting the installer. Finish it in its own window…")
            let r = try await ctx.runWine(["start", "/wait", "/unix", p], cwd: url.deletingLastPathComponent(), timeout: 4 * 3600)
            ctx.log("Installer closed (exit \(r.status)).")
            markFinished(ctx)
        }

        func installFromDisc(_ ctx: InstallContext) async throws {
            guard let p = ctx.input("isoPath") else { return }
            if ZeroHourInstall.opened(ctx, info.id) { return markFinished(ctx) }
            let iso = URL(fileURLWithPath: p)
            let fm = FileManager.default
            let imageName = CustomGames.safeFolderName(iso.deletingPathExtension().lastPathComponent) + ".iso"
            let stored = ctx.support.appendingPathComponent(imageName)
            if !fm.fileExists(atPath: stored.path) {
                ctx.log("Keeping a copy of the disc image inside the app…")
                try fm.cloneItem(at: iso, to: stored)
            }
            let mount = ctx.support.appendingPathComponent("MountedDisc")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            let info0 = try? Shell.run("/usr/sbin/diskutil", ["info", "-plist", mount.path])
            if info0.map({ !$0.stdout.contains("<string>\(mount.path)</string>") }) ?? true {
                let r = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, stored.path], timeout: 120)
                guard r.ok else { throw NokError("macOS couldn't mount that image: \(r.combined)") }
            }
            let plist = try Shell.run("/usr/sbin/diskutil", ["info", "-plist", mount.path]).stdout
            let dict = (try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)) as? [String: Any]
            let label = dict?["VolumeName"] as? String ?? ""
            guard let node = dict?["DeviceNode"] as? String, dict?["MountPoint"] as? String == mount.path else {
                throw NokError("The image mounted, but its device couldn't be identified.")
            }
            let raw = "/dev/r" + node.dropFirst("/dev/".count)
            let dos = ctx.prefix.appendingPathComponent("dosdevices")
            for (name, dest) in [("d:", mount.path), ("d::", raw)] {
                let link = dos.appendingPathComponent(name)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: dest)
            }
            let reg = ctx.workDir.appendingPathComponent("cdrom.reg")
            try "Windows Registry Editor Version 5.00\n\n[HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives]\n\"d:\"=\"cdrom\"\n\n".write(to: reg, atomically: true, encoding: .utf8)
            try await ctx.runWine(["regedit", "/S", reg.path], timeout: 120)
            ctx.state.inputs["disc.image"] = imageName
            ctx.state.inputs["disc.label"] = label
            try ctx.saveState()
            ctx.log("Disc \"\(label)\" is drive D:.")

            let setup = Self.discSetup(mount)
            guard let setup else {
                throw NokError("No setup program found on the disc. Use \"Existing game folder\" if this game runs without installing.")
            }
            try FileManager.default.createDirectory(at: CustomInstall.gamesFolder(ctx), withIntermediateDirectories: true)
            try ZeroHourInstall.markOpened(ctx, info.id)
            ctx.log("Starting D:\\\(setup). Finish it in its own window…")
            let r = try await ctx.runWine(["start", "/wait", "/d", "D:\\", "D:\\" + setup.replacingOccurrences(of: "/", with: "\\")],
                                          cwd: mount, timeout: 4 * 3600)
            ctx.log("Setup closed (exit \(r.status)).")
            markFinished(ctx)
        }

        /// autorun.inf's open= entry, else a setup/install program at the disc root.
        static func discSetup(_ mount: URL) -> String? {
            let fm = FileManager.default
            let root = (try? fm.contentsOfDirectory(atPath: mount.path)) ?? []
            if let inf = root.first(where: { $0.lowercased() == "autorun.inf" }),
               let text = try? String(contentsOf: mount.appendingPathComponent(inf), encoding: .isoLatin1) {
                for line in text.components(separatedBy: .newlines) {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.lowercased().hasPrefix("open=") {
                        let cmd = l.dropFirst(5).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                        let rel = cmd.replacingOccurrences(of: "\\", with: "/")
                        if !rel.isEmpty, rel.lowercased().hasSuffix(".exe"),
                           let match = caseInsensitive(rel, in: mount) { return match }
                    }
                }
            }
            for want in ["setup.exe", "install.exe", "autorun.exe"] {
                if let hit = root.first(where: { $0.lowercased() == want }) { return hit }
            }
            return nil
        }

        static func caseInsensitive(_ rel: String, in base: URL) -> String? {
            var cur = base, parts: [String] = []
            for comp in rel.split(separator: "/") {
                guard let hit = (try? FileManager.default.contentsOfDirectory(atPath: cur.path))?
                        .first(where: { $0.caseInsensitiveCompare(String(comp)) == .orderedSame }) else { return nil }
                parts.append(hit); cur = cur.appendingPathComponent(hit)
            }
            return parts.joined(separator: "/")
        }

        func markFinished(_ ctx: InstallContext) {
            ctx.state.inputs["acquire.finished"] = "1"
            try? ctx.saveState()
        }

        func steamCMD(_ ctx: InstallContext) throws {
            guard let user = ctx.input("steamUser"), let app = ctx.input("steamAppID").flatMap(Int.init) else {
                throw NokError("Enter your Steam account name and the game's App ID.")
            }
            if ZeroHourInstall.opened(ctx, info.id) { return }
            guard let steamcmd = Shell.which("steamcmd") else {
                throw NokError("SteamCMD isn't installed. Install Valve's SteamCMD (for example `brew install --cask steamcmd`), then press Continue.")
            }
            guard user.range(of: #"^[A-Za-z0-9_.@-]+$"#, options: .regularExpression) != nil else { throw NokError("That account name has unexpected characters.") }
            try NokPaths.ensure(ctx.workDir)
            let dir = CustomInstall.gamesFolder(ctx)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let q = CustomGames.shellQuote
            let script = ctx.workDir.appendingPathComponent("steam-download.command")
            try """
            #!/bin/bash
            # Nokcandu: download your own Steam copy (Windows files). Sign in below; Nokcandu never sees your password.
            set -e
            \(q(steamcmd)) +@sSteamCmdForcePlatformType windows +force_install_dir \(q(dir.path)) +login \(q(user)) +app_update \(app) validate +quit
            echo; echo "Finished. Return to Nokcandu and press Continue."
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let r = try Shell.run("/usr/bin/open", ["-a", "Terminal", script.path])
            guard r.ok else { throw NokError("Could not open Terminal: \(r.combined)") }
            try ZeroHourInstall.markOpened(ctx, info.id)
        }

        func steamLibrary(_ ctx: InstallContext) async throws {
            throw NokError("Steam games are added from the Steam Library in Nokcandu, so they share one Steam.")
            guard ctx.input("steamAppID").flatMap(Int.init) != nil else { throw NokError("Enter the game's Steam App ID.") }
            let steamExe = ctx.prefix.appendingPathComponent("\(CustomInstall.steamDir)/steam.exe")
            if !FileManager.default.fileExists(atPath: steamExe.path) {
                guard let setup = ctx.input("steamSetup"), setup.lowercased().hasSuffix(".exe"), FileManager.default.fileExists(atPath: setup) else {
                    throw NokError("Choose SteamSetup.exe downloaded from Steam's website.")
                }
                ctx.log("Running Steam's installer — finish it in its window (untick \"Run Steam\" if you like).")
                _ = try await ctx.runWine(["start", "/wait", "/unix", setup], timeout: 3600)
                guard FileManager.default.fileExists(atPath: steamExe.path) else {
                    throw NokError("Steam didn't install to C:\\Program Files (x86)\\Steam. Run its installer again with the default folder.")
                }
            }
            if ZeroHourInstall.opened(ctx, info.id) { return }
            try ZeroHourInstall.markOpened(ctx, info.id)
            ctx.log("Opening Steam. Sign in, install the game, wait for it to finish, then quit Steam (Steam menu → Exit).")
            // Steam stays open while the user works; Nokcandu waits for it to exit.
            let r = try await ctx.runWine([CustomGames.steamExe] + CustomGames.steamWineFlags.split(separator: " ").map(String.init),
                                          timeout: 12 * 3600)
            ctx.log("Steam closed (exit \(r.status)).")
        }
    }

    struct ChooseExe: InstallStage {
        let source: GameSource
        var info: StageInfo {
            source == .steamLibrary
            ? StageInfo(id: "exe", title: "How to start the game", detail: "Steam games start through Steam, so the app opens Steam and launches the game.", kind: .automatic)
            : StageInfo(id: "exe", title: "Choose the game's program",
                        detail: "Pick the .exe that starts the game (Nokcandu lists the likeliest first). If unsure, choose the one named after the game, not a setup or uninstaller.",
                        kind: .handoff, needs: ["exe"])
        }
        func isDone(_ ctx: InstallContext) -> Bool {
            guard let exe = ctx.input("exe"), let rel = CustomGames.driveCRelative(windowsPath: exe) else { return false }
            return FileManager.default.fileExists(atPath: ctx.prefix.appendingPathComponent("drive_c/\(rel)").path)
        }
        func run(_ ctx: InstallContext) async throws {
            if source == .steamLibrary {
                ctx.state.inputs["exe"] = CustomGames.steamExe
                ctx.state.inputs["arguments"] = CustomGames.steamArguments(appID: Int(ctx.input("steamAppID") ?? "0") ?? 0)
                try ctx.saveState()
            }
        }
    }

    struct Graphics: InstallStage {
        let info = StageInfo(id: "graphics", title: "Pick a graphics mode",
                             detail: "Suggested from what the game uses. You can switch it any time after installing.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { ctx.input("graphics").flatMap(GraphicsPreset.init(rawValue:)) != nil }
        func run(_ ctx: InstallContext) async throws {
            var probe: URL?
            if CustomInstall.source(ctx) == .steamLibrary, let id = ctx.input("steamAppID") {
                // Look at the game's own exe inside steamapps/common for the suggestion.
                let manifest = ctx.prefix.appendingPathComponent("\(CustomInstall.steamDir)/steamapps/appmanifest_\(id).acf")
                if let t = try? String(contentsOf: manifest, encoding: .utf8), let dir = (try? VDF.parse(t))?["AppState"]?["installdir"]?.string {
                    let common = ctx.prefix.appendingPathComponent("\(CustomInstall.steamDir)/steamapps/common/\(dir)")
                    probe = (try? FileManager.default.contentsOfDirectory(at: common, includingPropertiesForKeys: [.fileSizeKey]))?
                        .filter { $0.pathExtension.lowercased() == "exe" }
                        .max { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                }
            } else if let exe = ctx.input("exe"), let rel = CustomGames.driveCRelative(windowsPath: exe) {
                probe = ctx.prefix.appendingPathComponent("drive_c/\(rel)")
            }
            let pe = probe.flatMap(PEFile.inspect)
            let preset = GraphicsPreset.suggest(for: pe)
            ctx.state.inputs["graphics"] = preset.rawValue
            if let pe {
                ctx.state.inputs["is64"] = pe.is64Bit ? "1" : "0"
                ctx.state.inputs["apis"] = pe.imports.map { $0.lowercased() }
                    .filter { ["d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "ddraw.dll", "opengl32.dll", "vulkan-1.dll", "steam_api.dll", "steam_api64.dll"].contains($0) }
                    .joined(separator: ",")
                if let probe { ctx.state.inputs["iconSource"] = probe.path }
                ctx.log("\(probe?.lastPathComponent ?? "game"): \(pe.is64Bit ? "64" : "32")-bit; uses \(ctx.state.inputs["apis"] ?? "-") → \(preset.title)")
            }
            try ctx.saveState()
        }
    }

    struct Build: InstallStage {
        let info = StageInfo(id: "app-build", title: "Finish the Mac app", detail: "Launcher, original game icon, and app details.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            guard let c = CustomGameConfig.load(contents: ctx.contents),
                  let sha = try? Hashing.sha256(file: ctx.contents.appendingPathComponent("MacOS/\(CustomGames.launcherName)")) else { return false }
            return sha == c.launcherSHA && FileManager.default.fileExists(atPath: ctx.contents.appendingPathComponent("Info.plist").path)
        }
        func run(_ ctx: InstallContext) async throws {
            let name = CustomInstall.name(ctx)
            var disc: DiscSpec?
            if let img = ctx.input("disc.image") {
                disc = DiscSpec(imageName: img, volumeLabel: ctx.state.inputs["disc.label"] ?? "", internalMountDir: "SharedSupport/MountedDisc")
            }
            var c = CustomGameConfig(id: CustomGames.slug(name) + "-" + ctx.state.installID.suffix(4), name: name,
                                     source: CustomInstall.source(ctx),
                                     steamAppID: ctx.input("steamAppID").flatMap(Int.init),
                                     exe: ctx.input("exe") ?? "", arguments: ctx.input("arguments") ?? "",
                                     graphics: ctx.input("graphics").flatMap(GraphicsPreset.init(rawValue:)) ?? .classic3D,
                                     disc: disc,
                                     is64Bit: ctx.input("is64").map { $0 == "1" },
                                     detectedAPIs: (ctx.input("apis") ?? "").split(separator: ",").map(String.init))
            let script = CustomGames.launcherScript(for: c)
            c.launcherSHA = Hashing.sha256(data: Data(script.utf8))
            let fm = FileManager.default
            let launcher = ctx.contents.appendingPathComponent("MacOS/\(CustomGames.launcherName)")
            try Data(script.utf8).write(to: launcher, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            let cfgURL = CustomGameConfig.url(in: ctx.contents)
            try fm.createDirectory(at: cfgURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try c.encoded().write(to: cfgURL, options: .atomic)

            var iconFile = ""
            let icns = ctx.contents.appendingPathComponent("Resources/AppIcon.icns")
            let iconSource = ctx.input("iconSource").map(URL.init(fileURLWithPath:))
                ?? CustomGames.driveCRelative(windowsPath: c.exe).map { ctx.prefix.appendingPathComponent("drive_c/\($0)") }
            if let src = iconSource, PEFile.writeIcns(from: src, to: icns, workDir: ctx.workDir) {
                iconFile = icns.lastPathComponent
            } else {
                ctx.log("Note: the game's .exe has no icon Nokcandu could read; the app uses a plain icon.")
            }
            let plist: [String: Any] = [
                "CFBundleDevelopmentRegion": "English",
                "CFBundleExecutable": CustomGames.launcherName,
                "CFBundleIconFile": iconFile,
                "CFBundleIdentifier": "local.nokcandu.\(c.id)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "14.6",
                "NSBGOnly": "1",
                "NSHighResolutionCapable": true,
                "NokcanduRecipe": "custom",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist.merging(AppPrivacy.keys) { a, _ in a }, format: .xml, options: 0)
                .write(to: ctx.contents.appendingPathComponent("Info.plist"))
            _ = try? Shell.run("/usr/bin/touch", [ctx.targetApp.path])
        }
    }

    struct Check: InstallStage {
        let info = StageInfo(id: "check", title: "Launcher self-check", detail: "Confirms the engine and the game's program are in place.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool { ctx.state.inputs["check.ok"] == "1" }
        func run(_ ctx: InstallContext) async throws {
            let r = try await Shell.runAsync("/bin/bash", [ctx.contents.appendingPathComponent("MacOS/\(CustomGames.launcherName)").path, "--check"], timeout: 120)
            ctx.log(r.combined)
            guard r.ok else { throw NokError("Self-check failed: \(r.combined.suffix(300))") }
            ctx.state.inputs["check.ok"] = "1"
            try ctx.saveState()
        }
    }

    struct PlayTest: InstallStage {
        let info = StageInfo(id: "playtest", title: "Play test",
                             detail: "Open the new app and actually play for a minute. If it looks wrong or won't start, try another graphics mode in Nokcandu. Confirm only when it plays well.",
                             kind: .handoff, needs: ["playtest"])
        func isDone(_ ctx: InstallContext) -> Bool {
            ctx.state.inputs["playtest"] == "confirmed" && CustomGameConfig.load(contents: ctx.contents)?.confirmedGraphics != nil
        }
        func run(_ ctx: InstallContext) async throws {
            guard ctx.state.inputs["playtest"] == "confirmed", var c = CustomGameConfig.load(contents: ctx.contents) else { return }
            c.confirmedGraphics = c.graphics
            try c.encoded().write(to: CustomGameConfig.url(in: ctx.contents), options: .atomic)
        }
    }
}
