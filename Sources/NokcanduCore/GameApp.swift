import Foundation

/// A tiny app wrapper around an app's Wine (SharedSupport/GameApp/<Name>.app). Wine's processes are bare
/// programs, so macOS shows them as "wine" and never offers Game Mode. Nokcandu's helper library relaunches
/// each game process from this wrapper's Contents/MacOS before Wine starts (same arguments and connection),
/// so macOS sees a real app: the game's name and icon, and the games category that Game Mode needs.
/// The wrapper holds a copy of the small `wine` loader; everything else links back to the real engine.
public enum GameApp {
    static let folderName = "GameApp"
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Settings → Advanced can switch this off; Wine then runs as plain "wine" again (no Game Mode).
    public static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "gameAppsOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "gameAppsOff") }
    }

    /// "size:modification time" of the engine's loader. The helper library compares it before relaunching, so a
    /// wrapper made for an older engine (e.g. just after an engine update) is never used.
    static func engineStamp(_ wine: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: wine.path),
              let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value):\(Int64(date.timeIntervalSince1970))"
    }

    /// Tests turn off signing and registering with macOS.
    static var useSystemTools = true

    static func remove(_ app: URL) {
        if useSystemTools { _ = try? Shell.run(lsregister, ["-u", app.path], timeout: 30) }
        try? FileManager.default.removeItem(at: app)
    }

    /// Removes an app's wrappers (when switched off).
    public static func removeAll(host h: URL) {
        let dir = h.appendingPathComponent("SharedSupport/\(folderName)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "app" { remove(u) }
        try? FileManager.default.removeItem(at: dir)
    }

    public static func bundleID(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return "local.nokcandu.game." + s.split(separator: "-").joined(separator: "-")
    }

    static func safeName(_ name: String) -> String {
        let s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Game" : s
    }

    /// The loader copy is named after the game: macOS lists privacy permissions (Input Monitoring for raw
    /// mouse, the microphone) under the program's file name, so a plain "wine" told nobody which game it was.
    /// "wine" stays as a link to it for anything that looks for that name.
    static func executableName(_ name: String) -> String { safeName(name) == "wine" ? "wine-game" : safeName(name) }

    static func plist(name: String, icon: Bool, game: Bool = true) -> [String: Any] {
        var p: [String: Any] = [
            "CFBundleExecutable": executableName(name),
            "CFBundleIdentifier": bundleID(name),
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "NSHighResolutionCapable": true,
            // Start in the background like bare Wine does; Wine brings a process forward when it shows a window
            // (otherwise every helper process — Steam's web helpers, Wine's services — would get a Dock icon).
            "LSUIElement": true,
            "NSMicrophoneUsageDescription": "\(name) wants to use the microphone (for example for voice chat).",
        ]
        if icon { p["CFBundleIconFile"] = "game" }
        // Games only — launchers (Steam, Battle.net) and their many helper processes aren't games.
        if game { p["LSApplicationCategoryType"] = "public.app-category.games"; p["GCSupportsGameMode"] = true }
        else { p["LSApplicationCategoryType"] = "public.app-category.utilities" }
        return p
    }

    /// One wrapper to create: its name, and the app whose icon it shows.
    public struct Wrapper: Hashable {
        public var name: String; public var iconFrom: URL?; public var isGame = true
        public init(name: String, iconFrom: URL?, isGame: Bool = true) { self.name = name; self.iconFrom = iconFrom; self.isGame = isGame }
    }

    /// Creates or updates an app's wrappers (one per program name — "Steam", "Counter-Strike 2"…) and the
    /// program → wrapper list the helper library reads. `fallback` is used for programs not in `programs`.
    public static func ensure(host h: URL, wrappers: [Wrapper], programs: [String: String], fallback: String) {
        let fm = FileManager.default
        let support = h.appendingPathComponent("SharedSupport")
        let wine = support.appendingPathComponent("wine/bin/wine")
        guard enabled else { removeAll(host: h); return }
        guard fm.isExecutableFile(atPath: wine.path), let engine = engineStamp(wine) else { return }
        let dir = support.appendingPathComponent(folderName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var seen = Set<String>(), keep = Set<String>()
        for w in wrappers where seen.insert(safeName(w.name)).inserted {
            keep.insert(safeName(w.name) + ".app")
            ensureOne(dir: dir, wine: wine, name: w.name, iconFrom: w.iconFrom, isGame: w.isGame)
        }
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where u.pathExtension == "app" && !keep.contains(u.lastPathComponent) { remove(u) }
        var lines = ["#engine\t" + engine, "*\t" + safeName(fallback) + ".app"]
        for (exe, name) in programs.sorted(by: { $0.key < $1.key }) where seen.contains(safeName(name)) {
            lines.append(exe.lowercased() + "\t" + safeName(name) + ".app")
        }
        let text = lines.joined(separator: "\n") + "\n", list = dir.appendingPathComponent("programs.tsv")
        if (try? String(contentsOf: list, encoding: .utf8)) != text { try? Data(text.utf8).write(to: list, options: .atomic) }
    }

    static func ensureOne(dir: URL, wine: URL, name: String, iconFrom: URL?, isGame: Bool) {
        let fm = FileManager.default
        let app = dir.appendingPathComponent(safeName(name) + ".app", isDirectory: true)
        let c = app.appendingPathComponent("Contents", isDirectory: true)
        var changed = false
        try? fm.createDirectory(at: c.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: c.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        // The loader copy gets re-signed with the wrapper, so remember which engine loader it came from.
        let exeName = executableName(name)
        let loader = c.appendingPathComponent("MacOS/\(exeName)"), stamp = c.appendingPathComponent("Resources/loader-sha256")
        let link = c.appendingPathComponent("MacOS/wine")
        let source = try? Hashing.sha256(file: wine)
        if !fm.fileExists(atPath: loader.path) || source == nil || (try? String(contentsOf: stamp, encoding: .utf8)) != source {
            try? fm.removeItem(at: loader)
            if (try? fm.copyItem(at: wine, to: loader)) == nil { return }
            if let source { try? source.write(to: stamp, atomically: true, encoding: .utf8) }
            changed = true
        }
        // Wrappers from before kept the loader itself at MacOS/wine: make that the link.
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != exeName {
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: exeName)
            changed = true
        }
        // A loader left over from an earlier name of this wrapper.
        for f in (try? fm.contentsOfDirectory(atPath: c.appendingPathComponent("MacOS").path)) ?? []
            where ![exeName, "wine", "wineserver"].contains(f) {
            try? fm.removeItem(at: c.appendingPathComponent("MacOS/\(f)")); changed = true
        }
        // Paths Wine looks for next to its loader (the server, its libraries and data).
        let links = [("MacOS/wineserver", "../../../../wine/bin/wineserver"), ("lib", "../../../wine/lib"),
                     ("share", "../../../wine/share"), ("bin", "MacOS")]
        for (path, target) in links {
            let u = c.appendingPathComponent(path)
            if (try? fm.destinationOfSymbolicLink(atPath: u.path)) != target {
                try? fm.removeItem(at: u)
                try? fm.createSymbolicLink(atPath: u.path, withDestinationPath: target)
                changed = true
            }
        }
        // The game's icon (macOS uses it until Wine sets the program's own).
        var hasIcon = false
        if let from = iconFrom, let info = NSDictionary(contentsOf: from.appendingPathComponent("Info.plist")),
           var icon = info["CFBundleIconFile"] as? String, !icon.isEmpty {
            if !icon.hasSuffix(".icns") { icon += ".icns" }
            let src = from.appendingPathComponent("Resources/\(icon)"), dst = c.appendingPathComponent("Resources/game.icns")
            if fm.fileExists(atPath: src.path) {
                hasIcon = true
                if (try? Hashing.sha256(file: dst)) != (try? Hashing.sha256(file: src)) {
                    try? fm.removeItem(at: dst); try? fm.copyItem(at: src, to: dst); changed = true
                }
            }
        }
        let plistURL = c.appendingPathComponent("Info.plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist(name: name, icon: hasIcon, game: isGame), format: .xml, options: 0),
           (try? Data(contentsOf: plistURL)) != data {
            try? data.write(to: plistURL, options: .atomic); changed = true
        }
        if changed && useSystemTools {
            _ = try? Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 60)
            // Register it, so macOS (the Games app, Game Mode) knows the app's name and icon.
            _ = try? Shell.run(lsregister, ["-f", app.path], timeout: 30)
        }
    }

    /// The wrapper of an app, if it has one.
    public static func wrapper(host h: URL) -> URL? {
        let dir = h.appendingPathComponent("SharedSupport/\(folderName)", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
    }
}
