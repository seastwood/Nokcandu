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
         PrepareFiles(source: source), Acquire(source: source), ChooseExe(source: source), StoreFiles(), Graphics(), Build(), Check(), PlayTest()]
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

    /// Game files on another drive (e.g. ExFAT): link C:\Games\<name> to a folder there before the
    /// installer runs, so a big install goes straight onto that drive.
    struct PrepareFiles: InstallStage {
        let source: GameSource
        let info = StageInfo(id: "files-prep", title: "Get the game's drive ready", detail: "The game's files go on the drive you chose; the app stays on this Mac.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            guard ctx.input("filesFolder") != nil, source == .installer || source == .folder || source == .store else { return true }
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: CustomInstall.gamesFolder(ctx).path)) != nil
        }
        func run(_ ctx: InstallContext) async throws {
            guard let f = ctx.input("filesFolder") else { return }
            let fm = FileManager.default
            let link = CustomInstall.gamesFolder(ctx)
            let ext = URL(fileURLWithPath: f).appendingPathComponent(link.lastPathComponent, isDirectory: true)
            guard fm.fileExists(atPath: f) else { throw NokError("The drive for the game's files (\(f)) isn't connected.") }
            try fm.createDirectory(at: ext, withIntermediateDirectories: true)
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let items = try? fm.contentsOfDirectory(atPath: link.path), items.isEmpty { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: ext.path)
            ctx.log("Game files will be stored on \(GameFolders.volumeName(ext)): \(ext.path)")
        }
    }

    /// After the program is known: if its folder isn't on the chosen drive yet (e.g. a disc installer
    /// picked C:\Program Files), move it there now.
    struct StoreFiles: InstallStage {
        let info = StageInfo(id: "files-store", title: "Store the game's files", detail: "Moves the installed game onto the drive you chose.", kind: .automatic)
        func isDone(_ ctx: InstallContext) -> Bool {
            if ctx.input("folderMode") == "existing" { return true }
            guard ctx.input("filesFolder") != nil, let exe = ctx.input("exe"), !exe.isEmpty,
                  let folder = GameMover.gameFilesFolder(exe: exe, prefix: ctx.prefix) else { return true }
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil
        }
        func run(_ ctx: InstallContext) async throws {
            if ctx.input("folderMode") == "existing" { return }
            guard let f = ctx.input("filesFolder"), let exe = ctx.input("exe"),
                  let folder = GameMover.gameFilesFolder(exe: exe, prefix: ctx.prefix) else { return }
            try GameMover.relocate(folder, to: URL(fileURLWithPath: f), progress: { ctx.log($0) })
            // The C:\Games\<name> folder prepared for the installer went unused: tidy it away.
            let fm = FileManager.default, prepared = CustomInstall.gamesFolder(ctx)
            if prepared != folder, let real = try? fm.destinationOfSymbolicLink(atPath: prepared.path),
               (try? fm.contentsOfDirectory(atPath: real))?.isEmpty == true {
                try? fm.removeItem(atPath: real); try? fm.removeItem(at: prepared)
            }
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
                                 detail: "Choose the game's disc image — or all of its discs (.iso, .cdr, .bin/.cue, .img/.ccd, .mdf). Nokcandu keeps a copy inside the app, puts Disc 1 in drive D: and starts its setup; swap discs here when setup asks.",
                                 kind: .handoff, needs: ["isoPath"])
            case .steamLibrary:
                return StageInfo(id: "acquire", title: "Install Steam and the game",
                                 detail: "1. Download SteamSetup.exe from Steam's site and choose it here. 2. Steam opens inside the app: sign in (Steam Guard happens there) and install the game. 3. When Steam says it's installed, quit Steam and press Continue.",
                                 kind: .handoff, needs: ["steamAppID", "steamSetup"])
            case .steam:
                return StageInfo(id: "acquire", title: "Download your Steam copy",
                                 detail: "Opens Terminal with Valve's SteamCMD. Sign in and approve Steam Guard there — Nokcandu never sees your password.",
                                 kind: .handoff, needs: ["steamUser", "steamAppID"])
            case .store:
                return StageInfo(id: "acquire", title: "Download the game",
                                 detail: "Downloads your copy's Windows files from the store. Big games take a while; if it stops, press Continue to pick up where it left off.",
                                 kind: .automatic)
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
                return !CustomGames.findExecutables(prefix: ctx.prefix, nameHint: CustomInstall.name(ctx), limit: 1, searchFolder: CustomInstall.gamesFolder(ctx)).isEmpty
                    && FileManager.default.fileExists(atPath: CustomInstall.gamesFolder(ctx).path)
            case .store:
                return ctx.state.inputs["acquire.finished"] == "1"
            case .installer, .disc:
                return ctx.state.inputs["acquire.finished"] == "1"
                    && !CustomGames.findExecutables(prefix: ctx.prefix, nameHint: CustomInstall.name(ctx), limit: 1).isEmpty
            }
        }

        func run(_ ctx: InstallContext) async throws {
            switch source {
            case .folder: try copyFolder(ctx)
            case .store: try await storeDownload(ctx)
            case .installer: try await runInstaller(ctx)
            case .disc:
                if ctx.input("disc.recoveryFolder") != nil {
                    try copyFolder(ctx)
                    markFinished(ctx)
                } else { try await installFromDisc(ctx) }
            case .steam: try steamCMD(ctx)
            case .steamLibrary: try await steamLibrary(ctx)
            }
        }

        func copyFolder(_ ctx: InstallContext) throws {
            guard let p = ctx.input("folderPath") else { return }
            let src = URL(fileURLWithPath: p)
            let dst = CustomInstall.gamesFolder(ctx)
            guard FileManager.default.isDirectory(src) else { throw NokError("That isn't a folder.") }
            let fm = FileManager.default
            if ctx.input("folderMode") == "existing" {
                guard src.resolvingSymlinksInPath().path != dst.resolvingSymlinksInPath().path,
                      !src.path.hasPrefix(ctx.prefix.path + "/") else {
                    throw NokError("Choose the original game folder outside this app.")
                }
                if let _ = try? fm.destinationOfSymbolicLink(atPath: dst.path) { try fm.removeItem(at: dst) }
                else if fm.fileExists(atPath: dst.path) {
                    guard (try fm.contentsOfDirectory(atPath: dst.path)).isEmpty else {
                        throw NokError("The app already has game files. Use Continue to check them, or start a separate setup.")
                    }
                    try fm.removeItem(at: dst)
                }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: src.path)
                try src.path.write(to: ctx.support.appendingPathComponent("referenced-game-folder.txt"), atomically: true, encoding: .utf8)
                ctx.log("Using existing files without copying: \(src.path). They will be kept when this app is removed.")
                return
            }
            ctx.log("Copying \(src.path)…")
            let target = dst.resolvingSymlinksInPath()
            let sourcePath = src.resolvingSymlinksInPath().path
            guard sourcePath != target.path, !target.path.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(target.path + "/") else {
                throw NokError("The source and destination overlap. Choose a separate original game folder.")
            }
            // Never erase an existing folder when retrying a failed import.
            if fm.fileExists(atPath: target.path), !(try fm.contentsOfDirectory(atPath: target.path)).isEmpty {
                throw NokError("The destination already contains files. Press Continue to check them, or choose Use Existing Folder Without Copying.")
            }
            let staging = target.deletingLastPathComponent().appendingPathComponent(".nok-import-" + UUID().uuidString)
            defer { try? fm.removeItem(at: staging) }
            if GameFolders.holdsApps(target.deletingLastPathComponent()) { try fm.cloneItem(at: src, to: staging) }
            else { try GameMover.copyPlain(src, staging) }
            try GameMover.removeCopiedMacMetadata(in: staging)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
            if let bottle = ctx.input("bottle.path") {
                Bottles.importUserData(from: URL(fileURLWithPath: bottle), into: ctx.prefix, log: ctx.log)
            }
        }

        func storeDownload(_ ctx: InstallContext) async throws {
            guard let kind = ctx.input("store.kind").flatMap(Store.init(rawValue:)), let id = ctx.input("store.id") else {
                throw NokError("This install doesn't say which store game to download.")
            }
            guard StoreAccounts.isSignedIn(kind) else { throw NokError("Sign in to \(kind.title) in Nokcandu's Store Library first.") }
            let folder = CustomInstall.gamesFolder(ctx)
            ctx.log("Downloading from \(kind.title)…")
            let r = try await StoreAccounts.download(StoreLink(store: kind, id: id), into: folder,
                                                    includeDLC: ctx.input("store.dlc") == "1", log: ctx.log) { p in
                ctx.reportProgress("Downloading from \(kind.title) — \(p.label)", fraction: p.fraction)
            }
            // The store reports real paths (maybe on another drive); the game sees them under C:\Games\<name>.
            let real = folder.resolvingSymlinksInPath().path
            var exe = r.exe.resolvingSymlinksInPath().path
            if exe.hasPrefix(real + "/") { exe = folder.path + exe.dropFirst(real.count) }
            guard let win = CustomGames.windowsPath(forUnix: URL(fileURLWithPath: exe), prefix: ctx.prefix) else {
                throw NokError("The game's program ended up outside the app: \(exe)")
            }
            ctx.state.inputs["exe"] = win
            ctx.state.inputs["arguments"] = r.arguments
            ctx.state.inputs["acquire.finished"] = "1"
            try ctx.saveState()
            ctx.log("Ready: \(win)")
        }

        func runInstaller(_ ctx: InstallContext) async throws {
            guard let p = ctx.input("installerPath") else { return }
            if ctx.input("launcherKind") == PCLauncher.ea.rawValue || URL(fileURLWithPath: p).lastPathComponent.lowercased() == "eaappinstaller.exe" {
                try await EAAppInstaller.run(ctx, installer: URL(fileURLWithPath: p))
                return
            }
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
            if ZeroHourInstall.opened(ctx, info.id) {
                markFinished(ctx)
                guard !CustomGames.findExecutables(prefix: ctx.prefix, nameHint: CustomInstall.name(ctx), limit: 1).isEmpty else {
                    throw NokError("Setup closed, but no game program was found on C:. Run Setup Again, or choose Copy Game Folder After Setup to import installed files or loose game files from the disc. A completed setup screen alone does not confirm that files were installed.")
                }
                return
            }
            // One or more discs (Disc 1 first): keep each inside the app, converting .bin/.cue etc. to .iso.
            let picked = (ctx.input("isoPaths") ?? p).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            var images: [String] = [], labels: [String] = []
            for (index, u) in picked.enumerated() {
                let i = try Discs.importImage(u, into: ctx.support, log: ctx.log) { phase, fraction in
                    ctx.reportProgress("Disc \(index + 1) of \(picked.count): " + phase, fraction: fraction)
                }
                if let n = i.note { ctx.log(n) }
                images.append(i.imageName); labels.append(i.label)
            }
            guard !images.isEmpty else { return }
            ctx.reportProgress("Mounting disc 1")
            try Discs.insert(0, images: images, support: ctx.support, prefix: ctx.prefix)
            let mount = Discs.mountDir(ctx.support, index: 0)
            let reg = ctx.workDir.appendingPathComponent("cdrom.reg")
            try "Windows Registry Editor Version 5.00\n\n[HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives]\n\"d:\"=\"cdrom\"\n\n".write(to: reg, atomically: true, encoding: .utf8)
            try await ctx.runWine(["regedit", "/S", reg.path], timeout: 120)
            ctx.state.inputs["disc.image"] = images[0]
            ctx.state.inputs["disc.label"] = labels[0]
            ctx.state.inputs["disc.images"] = images.joined(separator: "\n")
            ctx.state.inputs["disc.labels"] = labels.joined(separator: "\n")
            try ctx.saveState()
            ctx.log(images.count == 1 ? "Disc \"\(labels[0])\" is drive D:."
                                      : "Disc 1 (\"\(labels[0])\") is drive D:. When setup asks for the next disc, click Insert Disc 2 here.")

            guard Self.discSetup(mount) != nil else {
                throw NokError("No setup program found on disc 1. Use \"Existing game folder\" if this game runs without installing.")
            }
            try FileManager.default.createDirectory(at: CustomInstall.gamesFolder(ctx), withIntermediateDirectories: true)
            try ZeroHourInstall.markOpened(ctx, info.id)
            ctx.reportProgress("Starting Windows setup — finish it in its own window")
            try await Discs.runSetup(0, images: images, support: ctx.support, prefix: ctx.prefix, env: ctx.wineEnvironment, log: ctx.log)
            if images.count > 1 {
                ctx.log("If the other discs are expansions (their own setup), install them now with Run Setup for each disc above, then press Continue.")
            }
            markFinished(ctx)
            guard !CustomGames.findExecutables(prefix: ctx.prefix, nameHint: CustomInstall.name(ctx), limit: 1).isEmpty else {
                throw NokError("Setup closed, but no game program was found on C:. Run Setup Again, or use Copy Game Folder After Setup to import installed files or loose game files from the disc.")
            }
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
            if ctx.input("launcherKind") == PCLauncher.ea.rawValue, ctx.input("ea.client-configured") != "1" { return false }
            guard let c = CustomGameConfig.load(contents: ctx.contents),
                  let sha = try? Hashing.sha256(file: ctx.contents.appendingPathComponent("MacOS/\(CustomGames.launcherName)")) else { return false }
            return sha == c.launcherSHA && FileManager.default.fileExists(atPath: ctx.contents.appendingPathComponent("Info.plist").path)
        }
        func run(_ ctx: InstallContext) async throws {
            let name = CustomInstall.name(ctx)
            var disc: DiscSpec?
            var extra: [DiscSpec]?
            if let img = ctx.input("disc.image") {
                disc = DiscSpec(imageName: img, volumeLabel: ctx.state.inputs["disc.label"] ?? "", internalMountDir: "SharedSupport/MountedDisc")
                let imgs = (ctx.state.inputs["disc.images"] ?? "").split(separator: "\n").map(String.init)
                let lbls = (ctx.state.inputs["disc.labels"] ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if imgs.count > 1 {
                    extra = imgs.indices.dropFirst().map { DiscSpec(imageName: imgs[$0], volumeLabel: lbls.indices.contains($0) ? lbls[$0] : "",
                                                                     internalMountDir: "SharedSupport/MountedDisc\($0 + 1)") }
                }
            }
            var c = CustomGameConfig(id: CustomGames.slug(name) + "-" + ctx.state.installID.suffix(4), name: name,
                                     source: CustomInstall.source(ctx),
                                     steamAppID: ctx.input("steamAppID").flatMap(Int.init),
                                     exe: ctx.input("exe") ?? "", arguments: ctx.input("arguments") ?? "",
                                     graphics: ctx.input("graphics").flatMap(GraphicsPreset.init(rawValue:)) ?? .classic3D,
                                     disc: disc,
                                     is64Bit: ctx.input("is64").map { $0 == "1" },
                                     detectedAPIs: (ctx.input("apis") ?? "").split(separator: ",").map(String.init))
            if let existing = GameLibrary.inspect(ctx.targetApp) {
                c = CompatibilityFixes.preservingInstalledSettings(c, for: existing)
            }
            c.extraDiscs = extra
            if let k = ctx.input("store.kind").flatMap(Store.init(rawValue:)), let sid = ctx.input("store.id") { c.store = StoreLink(store: k, id: sid) }
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
            if let link = c.store, let exe = iconSource, StoreAccounts.writeStoreIcon(link, exe: exe, to: icns, workDir: ctx.workDir) {
                iconFile = icns.lastPathComponent
            } else if let src = iconSource, PEFile.writeIcns(from: src, to: icns, workDir: ctx.workDir) {
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
            if ctx.input("launcherKind") == PCLauncher.ea.rawValue, let game = GameLibrary.inspect(ctx.targetApp) {
                try await EAAppInstaller.configureClient(game, log: ctx.log)
                ctx.state.inputs["ea.client-configured"] = "1"
                try ctx.saveState()
            }
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
