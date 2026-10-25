import Foundation

/// Game data that lives OUTSIDE the game's app (so deleting it from Finder breaks the game), how to back
/// it up, and how to recreate the essentials. Today: Zero Hour keeps settings/replays in ~/Documents.
public struct GameDataSpec {
    public var folder: URL
    public var title: String
    /// Small files worth backing up and restoring, relative to `folder`.
    public var essentials: [String]
    /// Safe defaults for files that can't be restored from a backup.
    public var defaults: [String: () -> String]

    public static func forGame(_ g: InstalledGame) -> GameDataSpec? {
        guard g.recipe?.id == RecipeCatalog.zeroHour.id else { return nil }
        return GameDataSpec(
            folder: DisplayController.zeroHourDataFolder,
            title: "Documents › Command and Conquer Generals Zero Hour Data",
            essentials: ["Options.ini", "GeneralsOnlineData/launcher.json", "GeneralsOnlineData/settings.json", "Skirmish.ini", "Network.ini"],
            defaults: [
                "Options.ini": {
                    let d = DesktopSize.current()
                    return "AntiAliasing = 0\nResolution = \(d.width) \(d.height)\nStaticGameLOD = Medium\n"
                },
                "GeneralsOnlineData/launcher.json": {
                    "{\n  \"prefer_experiemental_client\": true,\n  \"windowed\": false,\n  \"windowed_width\": 1280,\n  \"windowed_height\": 800\n}\n"
                },
            ])
    }

    var backupDir: URL { NokPaths.support.appendingPathComponent("SettingsBackup/\(folder.lastPathComponent)", isDirectory: true) }

    /// Copies the current essentials into Nokcandu's backup (latest good copy). Called before each launch.
    public func snapshot() {
        let fm = FileManager.default
        for rel in essentials {
            guard let text = readTextAllowingCloud(folder.appendingPathComponent(rel), timeout: 2) else { continue }
            let dst = backupDir.appendingPathComponent(rel)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: dst, options: .atomic)
        }
    }

    public var missingEssentials: [String] {
        ["Options.ini", "GeneralsOnlineData/launcher.json"].filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}

public struct RepairStep: Identifiable {
    public enum Outcome: String { case ok, fixed, failed, skipped }
    public var id = UUID()
    public var title: String
    public var outcome: Outcome
    public var detail: String
}

/// "Repair": puts back what a game needs to start, without touching game content, saves, or anything that
/// is already fine. Everything it replaces goes to the Trash or the change journal first.
public enum Repair {
    public static func run(_ g: InstalledGame) -> [RepairStep] {
        var steps: [RepairStep] = []
        func add(_ t: String, _ o: RepairStep.Outcome, _ d: String) { steps.append(RepairStep(title: t, outcome: o, detail: d)) }
        let fm = FileManager.default

        if case .launcherRunning = GameLauncher.runState(of: g) {
            return [RepairStep(title: "Game is running", outcome: .skipped, detail: "Quit the game first, then run Repair.")]
        }

        // 1. Stale single-instance lock (left behind by a crash) and log folder.
        let lock = g.logs.appendingPathComponent("game.lock")
        if fm.fileExists(atPath: lock.path) {
            try? fm.removeItem(at: lock)
            add("Launch lock", .fixed, "Removed a leftover lock from a previous crash.")
        }
        if !g.usesSharedSteam && !fm.fileExists(atPath: g.logs.path) {
            try? fm.createDirectory(at: g.logs, withIntermediateDirectories: true)
            add("Logs folder", .fixed, "Recreated.")
        }

        if let link = g.battleNet {
            let ok = GameLibrary.inspect(URL(fileURLWithPath: link.hostApp)) != nil
            add("Battle.net app", ok ? .ok : .failed, ok ? link.hostApp : "Not found — set up Battle.net again, then re-add this game.")
            if let l = g.launcherURL {
                let want = BattleNet.launcherScript(link)
                if (try? Hashing.sha256(file: l)) != Hashing.sha256(data: Data(want.utf8)) {
                    do { try Data(want.utf8).write(to: l); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: l.path); add("Launcher", .fixed, "Rebuilt.") }
                    catch { add("Launcher", .failed, error.localizedDescription) }
                } else { add("Launcher", .ok, "In place.") }
            }
            return steps
        }

        // 2. Steam games live in the shared Steam app.
        if g.usesSharedSteam {
            if SharedSteam.isSetUp {
                SharedSteam.refreshHostScriptsIfNeeded()
                add("Shared Steam", .ok, "Steam.app and its helper are in place.")
            } else {
                add("Shared Steam", .failed, "Steam.app is missing or incomplete — set it up again from Steam Library.")
            }
            if let id = g.custom?.steamAppID {
                let installed = SharedSteam.installedGames().first { $0.appID == id }?.installed == true
                add("Game in Steam", installed ? .ok : .failed, installed ? "Installed." : "Not installed in the shared Steam — install it there (Steam Library → Install in Steam).")
            }
            steps += launcherSteps(g)
            return steps
        }

        // 3. Wine engine and graphics runtime: re-clone from Nokcandu's verified runtime cache if damaged.
        let wine = g.contents.appendingPathComponent("SharedSupport/wine/bin/wine")
        // An engine the user chose in Updates is checked against its own cached copy, not the recipe's.
        let engineUpdate = EngineUpdate.state(for: g)
        let pins: [String: String] = engineUpdate.flatMap { RuntimeManager.manifest(for: $0.runtimeID)?.verifiedHashes }
            ?? (g.recipe.map(RuntimeManager.runtimePins) ?? [:])
        let broken = !fm.isExecutableFile(atPath: wine.path) ||
            pins.contains { rel, sha in (try? Hashing.sha256(file: g.contents.appendingPathComponent(rel))) != sha }
        if broken {
            if let u = engineUpdate, RuntimeManager.isCached(id: u.runtimeID) {
                do {
                    let src = RuntimeManager.folder(for: u.runtimeID).appendingPathComponent("Contents")
                    for c in RuntimeManager.components {
                        let dst = g.contents.appendingPathComponent(c)
                        if fm.fileExists(atPath: dst.path) { try fm.trashItem(at: dst, resultingItemURL: nil) }
                        try fm.cloneItem(at: src.appendingPathComponent(c), to: dst)
                    }
                    add("Game engine", .fixed, "Restored \(u.engine) from Nokcandu's verified copy (old files are in the Trash).")
                } catch { add("Game engine", .failed, error.localizedDescription) }
            } else if let spec = g.recipe?.runtime, RuntimeManager.isCached(spec) {
                do {
                    for c in RuntimeManager.components {
                        let u = g.contents.appendingPathComponent(c)
                        if fm.fileExists(atPath: u.path) { try fm.trashItem(at: u, resultingItemURL: nil) }
                    }
                    try RuntimeManager.install(spec, into: g.contents)
                    add("Game engine", .fixed, "Restored the tested Wine engine and graphics files from Nokcandu's verified copy (old files are in the Trash).")
                } catch { add("Game engine", .failed, error.localizedDescription) }
            } else {
                add("Game engine", .failed, "Engine files are missing or changed, and Nokcandu has no verified copy to restore from.")
            }
        } else {
            add("Game engine", .ok, engineUpdate.map { "\($0.engine) (updated by you) is intact." } ?? "Wine engine and graphics files match.")
        }

        // 4. Windows environment basics.
        let driveC = g.prefix.appendingPathComponent("drive_c")
        if !fm.fileExists(atPath: driveC.path) {
            add("Windows environment", .failed, "The game's C: drive is missing; it needs reinstalling.")
        } else {
            let cLink = g.prefix.appendingPathComponent("dosdevices/c:")
            if (try? fm.destinationOfSymbolicLink(atPath: cLink.path)) != "../drive_c" {
                try? fm.createDirectory(at: cLink.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: cLink)
                do { try fm.createSymbolicLink(atPath: cLink.path, withDestinationPath: "../drive_c"); add("Drive C:", .fixed, "Reconnected.") }
                catch { add("Drive C:", .failed, error.localizedDescription) }
            } else {
                add("Windows environment", .ok, "C: drive in place.")
            }
            // Folders like Documents point at your Mac folders; recreate any that point nowhere.
            let users = driveC.appendingPathComponent("users")
            for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" && !user.hasPrefix(".") {
                for name in ["Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos"] {
                    let link = users.appendingPathComponent("\(user)/\(name)")
                    if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path), !fm.fileExists(atPath: dest) {
                        try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                        add("\(name) folder", .fixed, "Recreated \(dest).")
                    }
                }
            }
        }

        // 5. Game files present.
        if let r = g.recipe, let dir = g.gameDirectory {
            let exe = dir.appendingPathComponent(r.primaryExecutable)
            add("Game files", fm.fileExists(atPath: exe.path) ? .ok : .failed,
                fm.fileExists(atPath: exe.path) ? "\(r.primaryExecutable) present." : "\(r.primaryExecutable) is missing — the game files need reinstalling.")
        }

        // 6. Game data stored outside the app.
        if let spec = GameDataSpec.forGame(g) {
            steps += restoreData(spec)
        }

        steps += launcherSteps(g)
        return steps
    }

    static func restoreData(_ spec: GameDataSpec) -> [RepairStep] {
        let fm = FileManager.default
        var out: [RepairStep] = []
        try? fm.createDirectory(at: spec.folder, withIntermediateDirectories: true)
        var restored: [String] = [], created: [String] = []
        for rel in spec.essentials {
            let dst = spec.folder.appendingPathComponent(rel)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let backup = spec.backupDir.appendingPathComponent(rel)
            if let d = try? Data(contentsOf: backup), (try? d.write(to: dst)) != nil {
                restored.append(rel)
            } else if let make = spec.defaults[rel], (try? Data(make().utf8).write(to: dst)) != nil {
                created.append(rel)
            }
        }
        if restored.isEmpty && created.isEmpty {
            out.append(RepairStep(title: "Game settings folder", outcome: .ok, detail: "\(spec.title) has what the game needs."))
        } else {
            var d: [String] = []
            if !restored.isEmpty { d.append("Restored from Nokcandu's backup: \(restored.joined(separator: ", ")).") }
            if !created.isEmpty { d.append("Recreated with tested defaults: \(created.joined(separator: ", ")).") }
            d.append("Replays and custom maps can't be recreated — check the Trash if they were deleted.")
            out.append(RepairStep(title: "Game settings folder", outcome: .fixed, detail: d.joined(separator: " ")))
        }
        spec.snapshot()
        return out
    }

    static func launcherSteps(_ g: InstalledGame) -> [RepairStep] {
        let fm = FileManager.default
        if let c = g.custom {
            let launcher = g.contents.appendingPathComponent("MacOS/\(CustomGames.launcherName)")
            let sha = try? Hashing.sha256(file: launcher)
            let expected = Hashing.sha256(data: Data(CustomGames.launcherScript(for: c).utf8))
            if sha == expected && fm.isExecutableFile(atPath: launcher.path) {
                return [RepairStep(title: "Launcher", outcome: .ok, detail: "Matches the game's settings.")]
            }
            do {
                try CustomGames.save(c, to: g, force: true)
                return [RepairStep(title: "Launcher", outcome: .fixed, detail: "Rebuilt from the game's settings (the old one can be undone).")]
            } catch { return [RepairStep(title: "Launcher", outcome: .failed, detail: error.localizedDescription)] }
        }
        if g.recipe?.id == RecipeCatalog.zeroHour.id, let url = g.launcherURL {
            switch DisplayController.launcherState(g) {
            case .original, .nokcanduPatched:
                return [RepairStep(title: "Launcher", outcome: .ok, detail: "Tested launcher in place.")]
            case .missing, .unrecognized:
                guard let template = NokPaths.bundledResource("generals-launcher"), let data = try? Data(contentsOf: template) else {
                    return [RepairStep(title: "Launcher", outcome: .failed, detail: "Nokcandu's launcher template is missing.")]
                }
                do {
                    try ChangeJournal(scope: g.journalScope).write(data, to: url, reason: "Repair: tested launcher")
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                    return [RepairStep(title: "Launcher", outcome: .fixed, detail: "Put back the tested launcher (the old one can be undone).")]
                } catch { return [RepairStep(title: "Launcher", outcome: .failed, detail: error.localizedDescription)] }
            }
        }
        if let l = g.launcherURL {
            return [RepairStep(title: "Launcher", outcome: fm.isExecutableFile(atPath: l.path) ? .ok : .failed,
                               detail: fm.isExecutableFile(atPath: l.path) ? "Present." : "Missing — this app needs reinstalling.")]
        }
        return []
    }
}
