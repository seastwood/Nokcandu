import Foundation

/// "Resizable window": the game runs on a virtual monitor (the resolution you pick) whose whole picture is
/// shown in one normal Mac window you can move, resize, minimize or make full screen. The Mac's display is
/// never changed. It's done by Nokcandu's build of Wine's Mac driver (Engine/winemac: Wine 10.0 plus
/// patches), which Nokcandu puts into the game's own engine while the setting is on, keeping the engine's
/// original driver beside it. Off puts the original back.
///
/// Fail-safe by design: the driver only does anything when the game's Windows registry says
/// "WindowedFullscreen"="y", and the stock driver ignores that value — so an engine update that brings
/// back the stock driver just means the game runs normally until Nokcandu reinstalls its driver.
/// While playing, Ctrl-Cmd-C frees or returns the mouse and Shift-Cmd-Esc always frees it, whatever the game does.
public enum WindowedPresentation {
    /// The three files that make up the driver, relative to the engine's lib/wine.
    static let files = ["x86_64-unix/winemac.so", "x86_64-windows/winemac.drv", "i386-windows/winemac.drv"]
    /// The stock driver of the engines Nokcandu's driver is built for (Sikarugir Wine 10.0), by file.
    static let stockSHA: [String: String] = [
        "x86_64-unix/winemac.so": "40ac732abaa0a44716d944cc9982c04bcc56c0a206b66c313fe7cc3837404f94",
        "x86_64-windows/winemac.drv": "d729e977f2c1f9fdede61d8f1ef12a9bf6612334733064eda1e2e102d997e694",
        "i386-windows/winemac.drv": "8ed070d98ed7184e1bb6e2934db469f82c78581858a6bc05c38ca288531b4994",
    ]
    public static let resolutions: [[Int]] = [
        [640, 480], [800, 600], [1024, 768], [1280, 720], [1280, 800], [1280, 960], [1280, 1024], [1366, 768],
        [1440, 900], [1600, 900], [1600, 1200], [1680, 1050], [1920, 1080], [1920, 1200], [2560, 1440], [2560, 1600],
    ]

    static func lib(_ host: URL) -> URL { host.appendingPathComponent("SharedSupport/wine/lib/wine") }
    static func backup(_ host: URL) -> URL { host.appendingPathComponent("SharedSupport/nokcandu/winemac.original", isDirectory: true) }

    /// Nokcandu's driver as bundled in the app (Resources/winemac, built by Engine/winemac/build.sh).
    public static var bundled: URL? {
        guard let d = NokPaths.bundledResource("winemac") else { return nil }
        return files.allSatisfy { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) } ? d : nil
    }

    public enum EngineState: Equatable { case stock, nokcandu, outdated, unsupported, missing }

    static func sha(_ u: URL) -> String? { try? Hashing.sha256(file: u) }

    /// What driver this app's engine has now.
    public static func engineState(host h: URL) -> EngineState {
        let l = lib(h)
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: l.appendingPathComponent($0).path) }) else { return .missing }
        // The .so is re-signed when installed, so compare the Windows halves and recognise ours by its exports' strings.
        if files.allSatisfy({ sha(l.appendingPathComponent($0)) == stockSHA[$0] }) { return .stock }
        if let b = bundled {
            let ours = files.dropFirst().allSatisfy { sha(l.appendingPathComponent($0)) == sha(b.appendingPathComponent($0)) }
            if ours, isOurs(l.appendingPathComponent(files[0])) {
                // Current = the installed file is the one Nokcandu signed, made from the driver this Nokcandu carries.
                let st = installedStamp(h)
                return st?.installed == sha(l.appendingPathComponent(files[0])) && st?.source == sha(b.appendingPathComponent(files[0]))
                    ? .nokcandu : .outdated
            }
        }
        if isOurs(l.appendingPathComponent(files[0])) { return .outdated }
        return .unsupported
    }

    /// Ours contains the name of its shared mode file; the stock driver doesn't. (Not the registry value's
    /// name: the compiler turns that short string into instructions, so it isn't in the file as text.)
    static let marker = ".nokcandu-virtual-display"
    static func isOurs(_ so: URL) -> Bool {
        guard let d = try? Data(contentsOf: so) else { return false }
        return d.range(of: Data(marker.utf8)) != nil
    }
    static func stamp(_ h: URL) -> URL { backup(h).appendingPathComponent("installed.sha256") }
    /// "installed-sha source-sha": the signed copy in the engine, and the bundled driver it was made from.
    static func installedStamp(_ h: URL) -> (installed: String, source: String)? {
        let parts = ((try? String(contentsOf: stamp(h), encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    // MARK: Per-game setting

    /// Each game keeps its own choice in its own app (so games sharing a launcher can differ); it is applied to
    /// the shared Windows environment when the game starts (restarting the launcher if it runs with another).
    static func settingFile(_ g: InstalledGame) -> URL { g.contents.appendingPathComponent("SharedSupport/nokcandu/resizable-window") }
    /// What the environment's registry was last set to ("off" or "WxH").
    static func appliedFile(_ host: URL) -> URL { host.appendingPathComponent("SharedSupport/nokcandu/resizable-window.applied") }

    /// "Automatic": the virtual screen starts like the Mac's screen (or at the game's last resolution) and
    /// follows the resolutions the game itself switches to.
    public static let automatic = [0, 0]
    public static func text(_ s: [Int]) -> String { s == automatic ? "auto" : "\(s[0])x\(s[1])" }
    public static func title(_ s: [Int]) -> String { s == automatic ? "Automatic" : "\(s[0]) × \(s[1])" }

    public static func parse(_ text: String?) -> [Int]? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if t == "auto" { return automatic }
        let p = t.split(separator: "x").compactMap { Int($0) }
        guard p.count == 2, (320...16384).contains(p[0]), (200...16384).contains(p[1]) else { return nil }
        return p
    }

    static func lastFile(_ g: InstalledGame) -> URL { g.contents.appendingPathComponent("SharedSupport/nokcandu/resizable-window.last") }
    /// The resolution chosen the last time it was on (Automatic if never chosen), for turning it back on.
    public static func lastChoice(for g: InstalledGame) -> [Int] {
        parse(try? String(contentsOf: lastFile(g), encoding: .utf8)) ?? automatic
    }

    public static func setting(for g: InstalledGame) -> [Int]? {
        if let t = try? String(contentsOf: settingFile(g), encoding: .utf8) { return parse(t) }
        return g.custom?.windowedPresentation     // test builds kept it in game.json
    }

    static func applied(host h: URL) -> [Int]? {
        if let t = try? String(contentsOf: appliedFile(h), encoding: .utf8) { return parse(t) }
        // Never recorded: read the registry itself.
        guard let u = try? String(contentsOf: h.appendingPathComponent("SharedSupport/prefix/user.reg"), encoding: .utf8),
              u.contains("\"WindowedFullscreen\"=\"y\"") else { return nil }
        guard let r = u.range(of: #""WindowedResolution"="([0-9]+x[0-9]+)""#, options: .regularExpression) else { return automatic }
        return parse(String(u[r]).components(separatedBy: "\"")[3])
    }

    /// Why it can't be used for this game (nil = it can).
    public static func unavailable(for g: InstalledGame) -> String? {
        if g.native != nil { return "Mac games use their own windows." }
        guard let h = WineTools.hostContents(for: g) else { return "This game has no Windows environment." }
        if bundled == nil { return "This copy of Nokcandu doesn't include its Wine Mac driver." }
        switch engineState(host: h) {
        case .unsupported: return "This game's Wine engine isn't one Nokcandu's driver is built for."
        case .missing: return "This game's Wine engine has no Mac driver."
        default: return nil
        }
    }

    /// Records the game's choice (nil = off); it takes effect when the game next starts.
    public static func saveSetting(_ size: [Int]?, for g: InstalledGame) throws {
        if let s = size, s.count != 2 || parse(text(s)) == nil { throw NokError("Unsupported resolution.") }
        let f = settingFile(g), fm = FileManager.default
        try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        // "off" (not a missing file) so a choice from a test build in game.json can't come back.
        try Data((size.map(text) ?? "off").utf8).write(to: f, options: .atomic)
        if let s = size { try? Data(text(s).utf8).write(to: lastFile(g), options: .atomic) }
        if var c = g.custom, c.windowedPresentation != nil || (size != nil && c.displayPixels != nil) {
            c.windowedPresentation = nil
            if size != nil { c.displayPixels = nil }     // the Mac's display stays as it is
            try CustomGames.saveAll(c, to: g, force: false)
        }
    }

    /// Saves the game's choice. Applied now if its Windows environment is closed, otherwise at the next start.
    public static func save(_ size: [Int]?, for g: InstalledGame) async throws {
        if size != nil, let r = unavailable(for: g) { throw NokError(r) }
        try saveSetting(size, for: g)
        if !(await WineTools.environmentIsRunning(for: g)) { try await prepareForLaunch(GameLibrary.inspect(g.appURL) ?? g) }
    }

    /// Before starting a game whose environment is closed: make the environment match the game's choice.
    public static func prepareForLaunch(_ g: InstalledGame) async throws {
        guard g.native == nil, let h = WineTools.hostContents(for: g) else { return }
        let want = setting(for: g)
        if want == applied(host: h), want == nil || engineState(host: h) == .nokcandu { return }
        if await WineTools.environmentIsRunning(for: g) { return }
        try apply(want, host: h)
    }

    /// The game's choice differs from what its running launcher/environment started with: why a restart is needed.
    public static func restartReason(for g: InstalledGame) async -> String? {
        guard g.native == nil, let h = WineTools.hostContents(for: g) else { return nil }
        let want = setting(for: g)
        guard want != applied(host: h), await WineTools.environmentIsRunning(for: g) else { return nil }
        if want == nil && engineState(host: h) != .nokcandu { return nil }
        let host = GameLibrary.inspect(h.deletingLastPathComponent())?.name ?? "its launcher"
        return want.map { "\(g.name) is set to play in a resizable window (\(title($0))), but \(host) is running with a different setting." }
            ?? "\(g.name) is set to use the Mac's screen, but \(host) is running with a resizable window."
    }

    /// Sets the (closed) environment: driver and registry.
    static func apply(_ size: [Int]?, host h: URL) throws {
        let prefix = h.appendingPathComponent("SharedSupport/prefix")
        if let s = size {
            try install(host: h)
            try setMacDriver(["WindowedFullscreen": "y", "WindowedResolution": s == automatic ? nil : "\(s[0])x\(s[1])"], prefix: prefix)
        } else {
            try setMacDriver(["WindowedFullscreen": nil, "WindowedResolution": nil], prefix: prefix)
            try restore(host: h)
        }
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent(".nokcandu-virtual-display"))
        try FileManager.default.createDirectory(at: appliedFile(h).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((size.map(text) ?? "off").utf8).write(to: appliedFile(h), options: .atomic)
    }

    // MARK: Driver install / restore

    /// Puts Nokcandu's driver into the app's engine (keeping the original once), re-signed.
    static func install(host h: URL) throws {
        guard let b = bundled else { throw NokError("This copy of Nokcandu doesn't include its Wine Mac driver.") }
        let fm = FileManager.default, l = lib(h), bk = backup(h)
        switch engineState(host: h) {
        case .nokcandu: return
        case .unsupported, .missing: throw NokError("This game's Wine engine isn't one Nokcandu's driver is built for; nothing was changed.")
        case .stock:
            try? fm.removeItem(at: bk)
            try fm.createDirectory(at: bk, withIntermediateDirectories: true)
            for f in files {
                let dst = bk.appendingPathComponent(f)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: l.appendingPathComponent(f), to: dst)
            }
        case .outdated:
            guard files.allSatisfy({ sha(bk.appendingPathComponent($0)) == stockSHA[$0] }) else {
                throw NokError("The engine's original Mac driver is missing from its backup; repair the game's engine first.")
            }
        }
        for f in files {
            let dst = l.appendingPathComponent(f), tmp = dst.appendingPathExtension("nokcandu-tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: b.appendingPathComponent(f), to: tmp)
            if f.hasSuffix(".so") {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
                let sign = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", tmp.path], timeout: 60)
                guard sign.ok else { try? fm.removeItem(at: tmp); throw NokError("Couldn't sign the Mac driver: \(sign.combined.suffix(200))") }
                try Data("\(sha(tmp) ?? "") \(sha(b.appendingPathComponent(f)) ?? "")\n".utf8).write(to: stamp(h), options: .atomic)
            }
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
        }
    }

    /// Puts the engine's own driver back (no-op if it never had ours).
    static func restore(host h: URL) throws {
        let fm = FileManager.default, l = lib(h), bk = backup(h)
        guard engineState(host: h) == .nokcandu || engineState(host: h) == .outdated else { return }
        guard files.allSatisfy({ sha(bk.appendingPathComponent($0)) == stockSHA[$0] }) else {
            throw NokError("The engine's original Mac driver is missing from its backup.")
        }
        for f in files {
            let dst = l.appendingPathComponent(f), tmp = dst.appendingPathExtension("nokcandu-tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: bk.appendingPathComponent(f), to: tmp)
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
        }
        try? fm.removeItem(at: bk)
    }

    // MARK: Registry

    static let header = "[Software\\\\Wine\\\\Mac Driver]"

    /// Sets (or with nil, removes) string values in the prefix's Mac Driver key. The game must not be running.
    static func setMacDriver(_ values: [String: String?], prefix: URL) throws {
        let u = prefix.appendingPathComponent("user.reg")
        var user = try String(contentsOf: u, encoding: .utf8)
        for (name, _) in values {
            // Drop any existing line for this value (inside any section; the names are ours).
            user = user.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("\"\(name)\"=") }.joined(separator: "\n")
        }
        let add = values.sorted { $0.key < $1.key }.compactMap { k, v in v.map { "\"\(k)\"=\"\($0)\"\n" } }.joined()
        if !add.isEmpty {
            if let r = user.range(of: header) {
                var end = user[r.upperBound...].firstIndex(of: "\n").map { user.index(after: $0) } ?? user.endIndex
                if user[end...].hasPrefix("#time=") { end = user[end...].firstIndex(of: "\n").map { user.index(after: $0) } ?? user.endIndex }
                user.insert(contentsOf: add, at: end)
            } else {
                user += (user.hasSuffix("\n") ? "" : "\n") + "\n\(header) 0\n" + add
            }
        }
        try Data(user.utf8).write(to: u, options: .atomic)
    }

    public static func registryOn(prefix: URL) -> Bool {
        ((try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)) ?? "").contains("\"WindowedFullscreen\"=\"y\"")
    }

    /// Keeps environments that use it working after an engine or Nokcandu update (new driver build):
    /// reinstalls the driver where it's missing or outdated. Skips running environments and unknown engines.
    public static func refresh(_ games: [InstalledGame]) {
        guard bundled != nil else { return }
        var hosts = Set<URL>()
        for g in games where g.native == nil { if let h = WineTools.hostContents(for: g), applied(host: h) != nil { hosts.insert(h) } }
        for h in hosts where WineTools.ownedProcesses(contents: h).isEmpty {
            let state = engineState(host: h)
            if state == .stock || state == .outdated { try? install(host: h) }
        }
    }
}
