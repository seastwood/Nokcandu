import Foundation

/// A native app entry retains macOS privacy attribution while its existing
/// generated shell launcher runs. Manual scripts and unrelated apps stay intact.
public enum LauncherEntry {
    nonisolated(unsafe) static var resourceForTesting: URL?
    static let name = "nokcandu-launcher"
    static let key = "NokcanduLauncherScript"
    static let record = "launcher-entry.json"
    struct State: Codable { var original: Data; var installed: Data; var helperSHA: String; var sourceSHA: String? = nil }

    public static func ensure(_ game: InstalledGame) throws {
        guard game.native == nil, let script = game.launcherURL,
              case .notRunning = GameLauncher.runState(of: game),
              let source = resourceForTesting ?? NokPaths.bundledResource(name, executable: true) else { return }
        if let config = game.custom {
            guard let expected = config.launcherSHA, try Hashing.sha256(file: script) == expected else { return }
        } else {
            guard game.recipe != nil else { return }
            switch DisplayController.launcherState(game) {
            case .original, .nokcanduPatched: break
            default: return
            }
        }
        let plist = game.contents.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        let before = try Data(contentsOf: plist)
        guard var info = try PropertyListSerialization.propertyList(from: before, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String else { return }
        let target = game.contents.appendingPathComponent("MacOS/" + name)
        guard target.resolvingSymlinksInPath() == target else { return }
        let marker = game.nokcanduState.appendingPathComponent(record)
        let old = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        let sourceSHA = try Hashing.sha256(file: source)
        if let old {
            guard before == old.installed, try Hashing.sha256(file: target) == old.helperSHA else { return }
            if old.sourceSHA == sourceSHA { return }
        } else {
            guard info["CFBundleExecutable"] as? String == script.lastPathComponent,
                  info[key] == nil, !FileManager.default.fileExists(atPath: target.path),
                  target.resolvingSymlinksInPath() == target else { return }
        }
        info[key] = script.lastPathComponent
        info["CFBundleExecutable"] = name
        info["NSRemovableVolumesUsageDescription"] = "Access this game's files on your external drive."
        let installed = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        let priorHelper = old == nil ? nil : try Data(contentsOf: target)
        let priorMarker = try? Data(contentsOf: marker)
        // Sign outside the .app. Once this is CFBundleExecutable, codesign can
        // otherwise treat the file as the surrounding bundle and reject scripts.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("nokcandu-entry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try Data(contentsOf: source).write(to: stage, options: .atomic)
        var changed = false
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.path)
            let signed = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, stage.path], timeout: 30)
            guard signed.ok else { throw NokError("Couldn't prepare the game's native launcher: " + signed.combined) }
            guard try Data(contentsOf: plist) == before, target.resolvingSymlinksInPath() == target else { throw NokError("The app entry changed during preparation. It was preserved.") }
            if let old {
                guard try Hashing.sha256(file: target) == old.helperSHA else { throw NokError("The native launcher was edited during preparation. It was preserved.") }
            } else {
                guard !FileManager.default.fileExists(atPath: target.path) else { throw NokError("The native launcher destination is already in use. It was preserved.") }
            }
            try Data(contentsOf: stage).write(to: target, options: .atomic)
            changed = true
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            let state = State(original: old?.original ?? before, installed: installed, helperSHA: try Hashing.sha256(file: target), sourceSHA: sourceSHA)
            try NokPaths.ensure(game.nokcanduState)
            try JSONEncoder().encode(state).write(to: marker, options: .atomic)
            try installed.write(to: plist, options: .atomic)
            _ = try? Shell.run(GameApp.lsregister, ["-f", game.appURL.path], timeout: 30)
        } catch {
            guard changed else { throw error }
            try? before.write(to: plist, options: .atomic)
            if let priorHelper {
                try? priorHelper.write(to: target, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            } else { try? FileManager.default.removeItem(at: target) }
            if let priorMarker { try? priorMarker.write(to: marker, options: .atomic) }
            else { try? FileManager.default.removeItem(at: marker) }
            throw error
        }
    }
    public static func undo(_ game: InstalledGame) throws {
        guard case .notRunning = GameLauncher.runState(of: game) else { throw NokError("Quit the game first.") }
        let marker = game.nokcanduState.appendingPathComponent(record)
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: marker))
        let plist = game.contents.appendingPathComponent("Info.plist"), target = game.contents.appendingPathComponent("MacOS/" + name)
        guard try Data(contentsOf: plist) == state.installed, try Hashing.sha256(file: target) == state.helperSHA else { throw NokError("The launcher entry was edited. It was left untouched.") }
        try state.original.write(to: plist, options: .atomic)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.removeItem(at: marker)
    }
}
