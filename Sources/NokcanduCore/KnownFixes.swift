import Foundation

/// Per-game fixes from Proton's community database (umu-protonfixes, BSD-2-Clause,
/// https://github.com/Open-Wine-Components/umu-protonfixes). Each game's fix is a small Python file;
/// Nokcandu reads the common, safe instructions out of it (extra Windows components, launch options,
/// environment variables, DLL overrides) and offers to apply them. Anything else is listed, not run.
public struct KnownFix: Codable, Hashable, Sendable {
    public var summary: String
    public var source: URL
    public var verbs: [String] = []            // winetricks components, e.g. "d3dcompiler_47"
    public var arguments: [String] = []
    public var environment: [String: String] = [:]
    public var dllOverrides: [String: String] = [:]   // dll → "n" | "b" | "n,b" | "b,n" | ""
    public var notApplied: [String] = []       // other steps, described in words
    public var isEmpty: Bool { verbs.isEmpty && arguments.isEmpty && environment.isEmpty && dllOverrides.isEmpty }
    public var fingerprint: String { Hashing.sha256(data: (try? JSONEncoder().encode(self)) ?? Data()) }
}

public enum KnownFixes {
    static let repo = "https://raw.githubusercontent.com/Open-Wine-Components/umu-protonfixes/master"
    static let databaseURL = URL(string: "https://raw.githubusercontent.com/Open-Wine-Components/umu-database/main/umu-database.csv")!
    static var cacheDir: URL { NokPaths.support.appendingPathComponent("KnownFixes", isDirectory: true) }

    /// Where a game's fix file might be, most specific first.
    static func candidates(_ g: InstalledGame) async -> [String] {
        var out: [String] = []
        if let id = g.custom?.steamAppID { out.append("gamefixes-steam/\(id).py") }
        if let link = g.custom?.store {
            switch link.store {
            case .gog: out.append("gamefixes-gog/umu-\(link.id).py")
            case .epic, .amazon:
                if let umu = await umuID(store: link.store == .epic ? "egs" : "amazon", codename: link.id) {
                    out += ["gamefixes-\(link.store == .epic ? "egs" : "amazon")/\(umu).py", "gamefixes-umu/\(umu).py"]
                    if let steam = umu.split(separator: "-").last, Int(steam) != nil { out.append("gamefixes-steam/\(steam).py") }
                }
            }
        }
        if out.isEmpty, let umu = await umuID(title: LibraryOrganizer.canonicalName(g)) {
            out.append("gamefixes-umu/\(umu).py")
            if let steam = umu.split(separator: "-").last, Int(steam) != nil { out.append("gamefixes-steam/\(steam).py") }
        }
        return out
    }

    /// umu-database.csv: TITLE,STORE,CODENAME,UMU_ID,… (cached for a week).
    static func database() async -> [[String]] {
        let f = cacheDir.appendingPathComponent("umu-database.csv")
        let age = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 7 * 86400, let (d, r) = try? await URLSession.shared.data(from: databaseURL), (r as? HTTPURLResponse)?.statusCode == 200 {
            try? NokPaths.ensure(cacheDir); try? d.write(to: f, options: .atomic)
        }
        guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().map { line in csvFields(String(line)) }
    }

    static func csvFields(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() } else if ch == ",", !quoted { out.append(cur); cur = "" } else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }

    static func umuID(store: String, codename: String) async -> String? {
        await database().first { $0.count > 3 && $0[1] == store && $0[2].caseInsensitiveCompare(codename) == .orderedSame }?[3]
    }
    static func umuID(title: String) async -> String? {
        let t = AntiCheat.normalized(title)
        return await database().first { $0.count > 3 && AntiCheat.normalized($0[0]) == t }?[3]
    }

    /// The fix for a game, if Proton's database has one with anything Nokcandu can use or show.
    public static func lookup(_ g: InstalledGame) async -> KnownFix? {
        for path in await candidates(g) {
            guard let text = await fetch(path) else { continue }
            let fix = parse(text, source: URL(string: "https://github.com/Open-Wine-Components/umu-protonfixes/blob/master/\(path)")!)
            if !fix.isEmpty || !fix.notApplied.isEmpty { return fix }
        }
        return nil
    }

    /// Downloads a fix file (following the repo's symlinks, which arrive as a one-line file name).
    static func fetch(_ path: String, depth: Int = 0) async -> String? {
        let cached = cacheDir.appendingPathComponent(path.replacingOccurrences(of: "/", with: "__"))
        let age = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? .infinity
        var text: String?
        if age < 7 * 86400 { text = try? String(contentsOf: cached, encoding: .utf8) }
        if text == nil {
            guard let (d, r) = try? await URLSession.shared.data(from: URL(string: "\(repo)/\(path)")!) else { return nil }
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            try? NokPaths.ensure(cacheDir)
            let body = code == 200 ? String(decoding: d, as: UTF8.self) : ""
            try? body.write(to: cached, atomically: true, encoding: .utf8)     // remember misses too
            text = body
        }
        guard let t = text, !t.isEmpty else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if depth < 3, !trimmed.contains("\n"), trimmed.hasSuffix(".py") {
            let dir = (path as NSString).deletingLastPathComponent
            return await fetch(dir + "/" + trimmed, depth: depth + 1)
        }
        return t
    }

    // MARK: Reading a fix file

    static func strings(in args: String) -> [String] {
        var out: [String] = []
        let re = try! NSRegularExpression(pattern: #"'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)""#)
        for m in re.matches(in: args, range: NSRange(args.startIndex..., in: args)) {
            for i in 1...2 { if let r = Range(m.range(at: i), in: args) { out.append(String(args[r]).replacingOccurrences(of: "\\\\", with: "\\")) } }
        }
        return out
    }

    public static func parse(_ text: String, source: URL) -> KnownFix {
        var fix = KnownFix(summary: "", source: source)
        // The main() docstring is the human summary.
        if let r = text.range(of: #"def main\([^)]*\)[^:]*:\s*(?:"""|''')([\s\S]*?)(?:"""|''')"#, options: .regularExpression) {
            let m = String(text[r])
            if let q = m.range(of: #"(?:"""|''')"#, options: .regularExpression) {
                fix.summary = m[q.upperBound...].replacingOccurrences(of: "\"\"\"", with: "").replacingOccurrences(of: "'''", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Each util.<call>(…) — joined across lines.
        let flat = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: " ")
        let call = try! NSRegularExpression(pattern: #"util\.([a-z_]+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#)
        for m in call.matches(in: flat, range: NSRange(flat.startIndex..., in: flat)) {
            guard let nr = Range(m.range(at: 1), in: flat), let ar = Range(m.range(at: 2), in: flat) else { continue }
            let name = String(flat[nr]), args = String(flat[ar]), s = strings(in: args)
            switch name {
            case "protontricks":
                if let v = s.first, v.range(of: #"^[A-Za-z0-9_.=-]+$"#, options: .regularExpression) != nil { fix.verbs.append(v) }
            case "append_argument":
                if let a = s.first { fix.arguments.append(a) }
            case "set_environment":
                if s.count >= 2, GameProfile.envNameAllowed(s[0]) { fix.environment[s[0]] = s[1] }
            case "winedll_override":
                if let dll = s.first {
                    let order: String
                    if args.contains("NATIVE_BUILTIN") { order = "n,b" } else if args.contains("BUILTIN_NATIVE") { order = "b,n" }
                    else if args.contains("NATIVE") { order = "n" } else if args.contains("BUILTIN") { order = "b" } else { order = "" }
                    fix.dllOverrides[dll] = order
                }
            case "disable_esync", "disable_fsync", "disable_ntsync", "disable_nvapi", "set_game_drive", "check_verb_requirements":
                continue   // Linux/Proton-only switches; nothing to do on a Mac
            case "regedit_add": fix.notApplied.append("Registry setting: \(s.prefix(2).joined(separator: " → "))")
            case "set_ini_options", "set_xml_options": fix.notApplied.append("Changes a game settings file (\(s.last ?? "config")).")
            case "set_dxvk_option": fix.notApplied.append("DXVK option: \(s.prefix(2).joined(separator: " = "))")
            case "replace_command": fix.notApplied.append("Starts a different program: \(s.joined(separator: " → "))")
            case "set_cpu_topology_limit", "set_cpu_topology", "set_cpu_topology_nosmt": fix.notApplied.append("Limits the CPU cores the game sees.")
            case "install_eac_runtime", "install_battleye_runtime": fix.notApplied.append("Proton's anti-cheat runtime (Linux only — not available on a Mac).")
            default: fix.notApplied.append("\(name.replacingOccurrences(of: "_", with: " ").capitalized)\(s.isEmpty ? "" : ": " + s.joined(separator: ", "))")
            }
        }
        return fix
    }

    // MARK: Applying

    static func marker(_ g: InstalledGame) -> URL { g.nokcanduState.appendingPathComponent("known-fix.json") }

    /// The fix this game already has (applied or dismissed), so it isn't offered again.
    public static func handled(_ g: InstalledGame) -> String? {
        try? String(contentsOf: marker(g), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func markHandled(_ g: InstalledGame, _ fix: KnownFix) {
        try? NokPaths.ensure(g.nokcanduState)
        try? fix.fingerprint.write(to: marker(g), atomically: true, encoding: .utf8)
    }

    /// Adds the launch options, environment and DLL overrides to the game's settings, then installs any
    /// Windows components with winetricks.
    public static func apply(_ fix: KnownFix, to g: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        guard var c = g.custom else { throw NokError("Only games set up by Nokcandu can take fixes.") }
        var changed = false
        let existing = CustomGames.splitArguments(c.arguments)
        let newArgs = fix.arguments.flatMap { CustomGames.splitArguments($0) }.filter { !existing.contains($0) }
        if !newArgs.isEmpty { c.arguments = (existing + newArgs).map(CustomGames.shellQuoteIfNeeded).joined(separator: " "); changed = true }
        var env = c.environment ?? [:]
        for (k, v) in fix.environment where env[k] == nil { env[k] = v; changed = true }
        if !fix.dllOverrides.isEmpty {
            var parts = (env["WINEDLLOVERRIDES"] ?? "").split(separator: ";").map(String.init).filter { !$0.isEmpty }
            for (dll, order) in fix.dllOverrides.sorted(by: { $0.key < $1.key }) where !parts.contains(where: { $0.hasPrefix(dll + "=") }) {
                parts.append("\(dll)=\(order)")
            }
            env["WINEDLLOVERRIDES"] = parts.joined(separator: ";"); changed = true
        }
        c.environment = env.isEmpty ? nil : env
        if changed { try CustomGames.save(c, to: g); log("Saved launch options and settings.") }
        if !fix.verbs.isEmpty {
            try await Winetricks.run(fix.verbs, in: g, log: log)
        }
        markHandled(g, fix)
    }
}

/// Winetricks (LGPL-2.1, https://github.com/Winetricks/winetricks) installs Windows components such as
/// Visual C++ runtimes or DirectX pieces into a game's Windows environment. Downloaded on first use.
public enum Winetricks {
    static let version = "20260125"
    static let sha256 = "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"
    static var url: URL { URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(version)/src/winetricks")! }
    static var script: URL { StoreTools.dir.appendingPathComponent("winetricks") }

    static func ensure() async throws -> URL {
        if (try? Hashing.sha256(file: script)) == sha256 { return script }
        try NokPaths.ensure(StoreTools.dir)
        let (tmp, r) = try await URLSession.shared.download(from: url)
        guard (r as? HTTPURLResponse)?.statusCode == 200, (try? Hashing.sha256(file: tmp)) == sha256 else {
            throw NokError("Couldn't download winetricks (or it didn't match the expected file).")
        }
        try? FileManager.default.removeItem(at: script)
        try FileManager.default.moveItem(at: tmp, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Installs components into the game's (or its launcher's) Windows environment.
    public static func run(_ verbs: [String], in g: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        guard let host = WineTools.hostContents(for: g) else { throw NokError("This game has no Windows environment of its own.") }
        let s = try await ensure()
        let support = host.appendingPathComponent("SharedSupport")
        let wineBin = support.appendingPathComponent("wine/bin")
        // New apps omit Configure.app. Prefer Nokcandu's source-built archive tool.
        let cab = NokPaths.bundledResource("cabextract")?.deletingLastPathComponent()
            ?? host.appendingPathComponent("Configure.app/Contents/Resources")
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = nil
        env["WINEPREFIX"] = support.appendingPathComponent("prefix").path
        env["WINE"] = wineBin.appendingPathComponent("wine").path
        env["WINESERVER"] = wineBin.appendingPathComponent("wineserver").path
        env["DYLD_FALLBACK_LIBRARY_PATH"] = host.appendingPathComponent("Frameworks").path + ":/usr/lib"
        env["PATH"] = [cab.path, wineBin.path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["W_OPT_UNATTENDED"] = "1"
        env["WINEDEBUG"] = "-all"
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        log("Installing \(verbs.joined(separator: ", ")) with winetricks… (this downloads from Microsoft and can take a few minutes)")
        let r = try await Shell.runAsync("/bin/sh", [s.path, "-q", "--unattended"] + verbs, env: env, timeout: 3600) { out in
            for line in out.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty { log(String(line)) }
        }
        guard r.ok else { throw NokError("winetricks couldn't install \(verbs.joined(separator: ", ")): \(r.combined.suffix(300))") }
        log("Installed \(verbs.joined(separator: ", ")).")
    }
}
