import Foundation

/// Game stores Nokcandu can sign in to and install from: GOG, Epic and Amazon. Each uses a well-known
/// open-source command-line client (the same ones the Heroic launcher uses), downloaded on first use:
///   GOG    — heroic-gogdl (GPL-3.0)      Epic — legendary (GPL-3.0)      Amazon — nile (GPL-3.0)
/// They run as separate programs; Nokcandu only starts them. Tokens stay in Nokcandu's own folder.
public enum Store: String, Codable, CaseIterable, Identifiable, Sendable {
    case gog, epic, amazon
    public var id: String { rawValue }
    public var title: String {
        switch self { case .gog: "GOG"; case .epic: "Epic Games"; case .amazon: "Amazon Games" }
    }
    public var symbol: String {
        switch self { case .gog: "g.circle"; case .epic: "e.circle"; case .amazon: "a.circle" }
    }
    var tool: (name: String, url: String, sha256: String, project: String) {
        switch self {
        case .gog:
            ("gogdl", "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/v1.3.1/gogdl_macos_arm64",
             "33a6d9b329c35f1caa7968009bf2f4f0a6f57cd00f749a4d2cb2204f3e794d2e", "https://github.com/Heroic-Games-Launcher/heroic-gogdl")
        case .epic:
            ("legendary", "https://github.com/legendary-gl/legendary/releases/download/0.21.1/legendary_macOS_arm64",
             "d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e", "https://github.com/legendary-gl/legendary")
        case .amazon:
            ("nile", "https://github.com/imLinguin/nile/releases/download/v1.2.0/nile_macOS_arm64",
             "6cc74eb19117c8c309b0b94657e1e267642a3b4840d7386a133dcf6f3bffeab0", "https://github.com/imLinguin/nile")
        }
    }
    public var toolProject: String { tool.project }

    /// GOG's sign-in page; after signing in it lands on embed.gog.com/on_login_success?code=…
    static let gogClientID = "46899977096215655"
    /// Epic's sign-in page; after signing in it shows {"authorizationCode": "…"} at /id/api/redirect.
    static let epicLoginURL = "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode"
}

/// The store a game came from, saved with the game's settings.
public struct StoreLink: Codable, Hashable, Sendable {
    public var store: Store
    public var id: String
    public init(store: Store, id: String) { self.store = store; self.id = id }
}

/// A game in the user's store library.
public struct StoreGame: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var store: Store
    public var title: String
    public var image: URL?
    public var windows: Bool
    /// The store also has a Mac version.
    public var mac: Bool = false
    /// Epic's namespace (matches anti-cheat data).
    public var namespace: String? = nil
}

public enum StoreTools {
    public static var dir: URL { NokPaths.support.appendingPathComponent("Tools", isDirectory: true) }
    public static func url(_ s: Store) -> URL { dir.appendingPathComponent(s.tool.name) }
    public static func configDir(_ s: Store) -> URL { NokPaths.support.appendingPathComponent("Stores/\(s.rawValue)", isDirectory: true) }
    static var gogAuth: URL { configDir(.gog).appendingPathComponent("auth.json") }

    public static func isInstalled(_ s: Store) -> Bool {
        (try? Hashing.sha256(file: url(s))) == s.tool.sha256
    }

    /// Downloads the store's client if it's missing (checked against a pinned SHA-256).
    @discardableResult
    public static func ensure(_ s: Store) async throws -> URL {
        let u = url(s)
        if isInstalled(s) { return u }
        try NokPaths.ensure(dir)
        let (tmp, resp) = try await URLSession.shared.download(from: URL(string: s.tool.url)!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NokError("Couldn't download \(s.tool.name) (\(s.title) support).") }
        guard (try? Hashing.sha256(file: tmp)) == s.tool.sha256 else {
            try? FileManager.default.removeItem(at: tmp)
            throw NokError("The downloaded \(s.tool.name) didn't match the expected file, so it wasn't used.")
        }
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.moveItem(at: tmp, to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    /// Environment for the clients: their own config folders, nothing from a game's Wine setup.
    public static func environment(_ s: Store) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        for k in ["DYLD_INSERT_LIBRARIES", "WINEPREFIX", "WINEDLLOVERRIDES"] { e[k] = nil }
        e["LEGENDARY_CONFIG_PATH"] = configDir(.epic).path
        e["NILE_CONFIG_PATH"] = configDir(.amazon).path
        e["PYTHONUNBUFFERED"] = "1"
        return e
    }

    static func baseArgs(_ s: Store) -> [String] { s == .gog ? ["--auth-config-path", gogAuth.path] : [] }

    public static func run(_ s: Store, _ args: [String], timeout: TimeInterval = 120) async throws -> ShellResult {
        let tool = try await ensure(s)
        try NokPaths.ensure(configDir(s))
        return try await Shell.runAsync(tool.path, baseArgs(s) + args, env: environment(s), timeout: timeout)
    }

    /// Runs a client and returns its whole standard output (library lists can be megabytes of JSON —
    /// more than the normal output capture keeps).
    public static func capture(_ s: Store, _ args: [String], timeout: TimeInterval = 300) async throws -> (status: Int32, out: Data, err: String) {
        let tool = try await ensure(s)
        try NokPaths.ensure(configDir(s))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nokcandu-\(s.rawValue)-\(UUID().uuidString).json")
        let errURL = tmp.appendingPathExtension("err")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: errURL) }
        let p = Process()
        p.executableURL = tool
        p.arguments = baseArgs(s) + args
        p.environment = environment(s)
        let outH = try FileHandle(forWritingTo: tmp), errH = try FileHandle(forWritingTo: errURL)
        p.standardOutput = outH; p.standardError = errH; p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate(); throw NokError("\(s.title) didn't answer in time.") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try? outH.close(); try? errH.close()
        let out = (try? Data(contentsOf: tmp)) ?? Data()
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (p.terminationStatus, out, err)
    }

    /// Runs a long download, passing each output line to `log`.
    public static func stream(_ s: Store, _ args: [String], log: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let tool = try await ensure(s)
        try NokPaths.ensure(configDir(s))
        let p = Process()
        p.executableURL = tool
        p.arguments = baseArgs(s) + args
        p.environment = environment(s)
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let buffer = Locked(""), lastProgress = Locked(Date.distantPast)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let t = String(data: d, encoding: .utf8) else { return }
            var parts = (buffer.value + t.replacingOccurrences(of: "\r", with: "\n")).components(separatedBy: "\n")
            buffer.value = parts.removeLast()
            for l in parts where !l.trimmingCharacters(in: .whitespaces).isEmpty {
                // Progress lines come many times a second; pass one every few seconds.
                let isProgress = l.contains("Progress:") || l.contains("= Progress") || l.contains("%")
                if isProgress { if Date().timeIntervalSince(lastProgress.value) < 3 { continue }; lastProgress.value = Date() }
                log(l)
            }
        }
        try p.run()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                p.terminationHandler = { _ in c.resume() }
            }
        } onCancel: { p.terminate() }
        pipe.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus
    }
}

// MARK: - Accounts

public enum StoreAccounts {
    public static func isSignedIn(_ s: Store) -> Bool {
        let fm = FileManager.default
        switch s {
        case .gog: return fm.fileExists(atPath: StoreTools.gogAuth.path)
        case .epic: return fm.fileExists(atPath: StoreTools.configDir(.epic).appendingPathComponent("user.json").path)
        case .amazon: return fm.fileExists(atPath: StoreTools.configDir(.amazon).appendingPathComponent("nile/user.json").path)
        }
    }

    public static func gogLoginURL() -> URL {
        URL(string: "https://auth.gog.com/auth?client_id=\(Store.gogClientID)&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy")!
    }
    public static var epicLoginURL: URL { URL(string: Store.epicLoginURL)! }

    /// Amazon's sign-in needs a per-device URL from nile. Returns the URL and what to send back after.
    public static func amazonLogin() async throws -> (url: URL, finish: [String: String]) {
        let r = try await StoreTools.run(.amazon, ["auth", "--login", "--non-interactive"])
        guard let json = r.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let u = (d["url"] as? String).flatMap(URL.init(string:)) else {
            throw NokError("Amazon sign-in couldn't start: \(r.combined.suffix(300))")
        }
        var finish: [String: String] = [:]
        for k in ["code_verifier", "serial", "client_id"] { if let v = d[k] as? String { finish[k] = v } }
        return (u, finish)
    }

    /// Recognizes the page a sign-in ends on and pulls out the one-time code.
    public static func code(from url: URL, store: Store) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch store {
        case .gog:
            guard url.host == "embed.gog.com", url.path.hasPrefix("/on_login_success") else { return nil }
            return items.first { $0.name == "code" }?.value
        case .amazon:
            return items.first { $0.name == "openid.oa2.authorization_code" }?.value
        case .epic:
            return nil   // Epic shows the code in the page body (see epicCode(fromPageText:))
        }
    }
    public static func epicCode(fromPageText t: String) -> String? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { return nil }
        return d["authorizationCode"] as? String
    }

    public static func finishSignIn(_ s: Store, code: String, amazon: [String: String] = [:]) async throws {
        let r: ShellResult
        switch s {
        case .gog: r = try await StoreTools.run(.gog, ["auth", "--code", code])
        case .epic: r = try await StoreTools.run(.epic, ["auth", "--code", code, "--disable-webview"])
        case .amazon:
            r = try await StoreTools.run(.amazon, ["register", "--code", code,
                                                    "--code-verifier", amazon["code_verifier"] ?? "",
                                                    "--serial", amazon["serial"] ?? "", "--client-id", amazon["client_id"] ?? ""])
        }
        guard r.ok, isSignedIn(s) else { throw NokError("\(s.title) sign-in didn't finish: \(r.combined.suffix(300))") }
    }

    public static func signOut(_ s: Store) async {
        switch s {
        case .gog: try? FileManager.default.removeItem(at: StoreTools.gogAuth)
        case .epic: _ = try? await StoreTools.run(.epic, ["auth", "--delete"])
        case .amazon: _ = try? await StoreTools.run(.amazon, ["auth", "--logout"])
        }
    }

    // MARK: Library

    public static func library(_ s: Store) async throws -> [StoreGame] {
        switch s {
        case .gog: return try await gogLibrary()
        case .epic:
            let r = try await StoreTools.capture(.epic, ["list", "--json", "--platform", "Windows"])
            guard r.status == 0, let arr = jsonArray(r.out) else { throw NokError("Epic library: \(r.err.suffix(300))") }
            return arr.compactMap { g in
                guard let id = g["app_name"] as? String, let t = g["app_title"] as? String else { return nil }
                let meta = g["metadata"] as? [String: Any]
                let platforms = ((meta?["releaseInfo"] as? [[String: Any]]) ?? []).flatMap { ($0["platform"] as? [String]) ?? [] }
                let img = ((meta?["keyImages"] as? [[String: Any]]) ?? [])
                    .first { ($0["type"] as? String) == "DieselGameBoxTall" || ($0["type"] as? String) == "DieselGameBox" }?["url"] as? String
                return StoreGame(id: id, store: .epic, title: t, image: img.flatMap(URL.init(string:)), windows: true, mac: platforms.contains("Mac"),
                                 namespace: meta?["namespace"] as? String)
            }
        case .amazon:
            _ = try await StoreTools.run(.amazon, ["library", "sync"], timeout: 300)
            let r = try await StoreTools.capture(.amazon, ["library", "list", "--json"])
            guard r.status == 0, let arr = jsonArray(r.out) else { throw NokError("Amazon library: \(r.err.suffix(300))") }
            return arr.compactMap { g in
                guard let p = g["product"] as? [String: Any], let id = p["id"] as? String, let t = p["title"] as? String else { return nil }
                let img = ((p["productDetail"] as? [String: Any])?["details"] as? [String: Any])?["logoUrl"] as? String
                return StoreGame(id: id, store: .amazon, title: t, image: img.flatMap(URL.init(string:)), windows: true)
            }
        }
    }

    static func jsonArray(_ out: Data) -> [[String: Any]]? {
        guard let start = out.firstIndex(of: UInt8(ascii: "[")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: out[start...])) as? [[String: Any]]
    }

    /// A fresh GOG access token (gogdl refreshes it when needed).
    static func gogToken() async throws -> String {
        let r = try await StoreTools.run(.gog, ["auth"])
        guard let line = r.stdout.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let t = d["access_token"] as? String else { throw NokError("GOG sign-in expired — sign in again.") }
        return t
    }

    static func gogLibrary() async throws -> [StoreGame] {
        let token = try await gogToken()
        var out: [StoreGame] = [], page = 1, pages = 1
        repeat {
            var req = URLRequest(url: URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page=\(page)")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (d, _) = try await URLSession.shared.data(for: req)
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { break }
            pages = j["totalPages"] as? Int ?? 1
            for p in (j["products"] as? [[String: Any]]) ?? [] {
                guard let id = (p["id"] as? Int).map(String.init) ?? p["id"] as? String, let t = p["title"] as? String else { continue }
                let works = (p["worksOn"] as? [String: Any])?["Windows"] as? Bool ?? true
                let mac = (p["worksOn"] as? [String: Any])?["Mac"] as? Bool ?? false
                let img = (p["image"] as? String).flatMap { URL(string: "https:\($0)_196.jpg") }
                out.append(StoreGame(id: id, store: .gog, title: t, image: img, windows: works, mac: mac))
            }
            page += 1
        } while page <= pages && page < 100
        return out
    }

    // MARK: Install

    /// Downloads a game's Windows files into `folder` (C:\Games\<name>, possibly a link to another drive).
    /// Returns the program to start and its arguments.
    public static func download(_ g: StoreLink, into folder: URL, log: @escaping @Sendable (String) -> Void) async throws -> (exe: URL, arguments: String) {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = (try? fm.destinationOfSymbolicLink(atPath: folder.path)).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? folder
        switch g.store {
        case .gog:
            let status = try await StoreTools.stream(.gog, ["download", g.id, "--platform", "windows", "--path", real.path,
                                                            "--support", real.appendingPathComponent(".gog-support").path, "--skip-dlcs"], log: log)
            guard status == 0 else { throw NokError("The GOG download stopped (exit \(status)). Press Continue to resume it.") }
            return try gogPlayTask(in: real, id: g.id)
        case .epic:
            let status = try await StoreTools.stream(.epic, ["install", g.id, "--base-path", real.deletingLastPathComponent().path,
                                                             "--game-folder", real.lastPathComponent, "--platform", "Windows",
                                                             "--skip-sdl", "-y"], log: log)
            guard status == 0 else { throw NokError("The Epic download stopped (exit \(status)). Press Continue to resume it.") }
            let installed = StoreTools.configDir(.epic).appendingPathComponent("installed.json")
            guard let d = try? Data(contentsOf: installed), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let me = j[g.id] as? [String: Any], let exe = me["executable"] as? String, !exe.isEmpty else {
                throw NokError("Epic finished, but didn't say which program starts the game.")
            }
            return (real.appendingPathComponent(exe.replacingOccurrences(of: "\\", with: "/")), "")
        case .amazon:
            let status = try await StoreTools.stream(.amazon, ["install", g.id, "--path", real.path], log: log)
            guard status == 0 else { throw NokError("The Amazon download stopped (exit \(status)). Press Continue to resume it.") }
            let fuel = real.appendingPathComponent("fuel.json")
            guard let d = try? Data(contentsOf: fuel), let t = String(data: d, encoding: .utf8),
                  let cmd = jsonValue(t, "Command") else { throw NokError("Amazon finished, but the game has no fuel.json to start it from.") }
            return (real.appendingPathComponent(cmd.replacingOccurrences(of: "\\", with: "/")), "")
        }
    }

    /// GOG games describe how to start in goggame-<id>.info → playTasks (the primary one).
    static func gogPlayTask(in root: URL, id: String) throws -> (exe: URL, arguments: String) {
        let fm = FileManager.default
        var info: URL?
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.lastPathComponent.lowercased().hasPrefix("goggame-") && u.pathExtension.lowercased() == "info" {
                if u.lastPathComponent.lowercased() == "goggame-\(id).info" { info = u; break }
                if info == nil { info = u }
                if e.level > 3 { e.skipDescendants() }
            }
        }
        guard let info, let d = try? Data(contentsOf: info), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tasks = j["playTasks"] as? [[String: Any]] else {
            throw NokError("GOG finished, but the game has no start information (goggame-\(id).info).")
        }
        let task = tasks.first { ($0["isPrimary"] as? Bool) == true && ($0["path"] as? String) != nil } ?? tasks.first { ($0["path"] as? String) != nil }
        guard let t = task, let path = t["path"] as? String else { throw NokError("GOG's start information names no program.") }
        let base = info.deletingLastPathComponent()
        return (base.appendingPathComponent(path.replacingOccurrences(of: "\\", with: "/")), (t["arguments"] as? String) ?? "")
    }

    /// Pulls a "Key": "value" out of JSON5-ish text (Amazon's fuel.json may have comments).
    static func jsonValue(_ text: String, _ key: String) -> String? {
        guard let r = text.range(of: #""\#(key)"\s*:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else { return nil }
        let m = String(text[r])
        guard let q = m.range(of: #":\s*""#, options: .regularExpression) else { return nil }
        return String(m[q.upperBound...].dropLast()).replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Icons

    /// GOG ships a proper icon with each game (goggame-<id>.ico next to its start info) — clearer than the
    /// one inside an old .exe. Other stores: nil (the .exe's icon is used).
    public static func storeIcon(_ link: StoreLink, exe: URL) -> URL? {
        guard link.store == .gog else { return nil }
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<4 {
            let ico = dir.appendingPathComponent("goggame-\(link.id).ico")
            if FileManager.default.fileExists(atPath: ico.path) { return ico }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    public static func writeStoreIcon(_ link: StoreLink, exe: URL, to icns: URL, workDir: URL) -> Bool {
        guard let ico = storeIcon(link, exe: exe) else { return false }
        try? NokPaths.ensure(workDir)
        let png = workDir.appendingPathComponent("store-icon.png")
        // An .ico holds several sizes; sips takes the largest.
        _ = try? Shell.run("/usr/bin/sips", ["-s", "format", "png", ico.path, "--out", png.path])
        guard FileManager.default.fileExists(atPath: png.path) else { return false }
        _ = try? Shell.run("/usr/bin/sips", ["-Z", "512", png.path])
        let r = try? Shell.run("/usr/bin/sips", ["-s", "format", "icns", png.path, "--out", icns.path])
        return r?.ok == true && FileManager.default.fileExists(atPath: icns.path)
    }

    /// Store games added before Nokcandu used the store's icon get it now (once).
    @discardableResult
    public static func refreshIcons(_ games: [InstalledGame]) -> Bool {
        var changed = false
        for g in games {
            guard let c = g.custom, let link = c.store, let rel = c.exeRelativeToContents else { continue }
            let marker = g.nokcanduState.appendingPathComponent("store-icon")
            guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
            let exe = g.contents.appendingPathComponent(rel)
            let icns = g.contents.appendingPathComponent("Resources/AppIcon.icns")
            let work = NokPaths.support.appendingPathComponent("Work/icon-\(c.id)")
            defer { try? FileManager.default.removeItem(at: work) }
            if writeStoreIcon(link, exe: exe, to: icns, workDir: work) {
                _ = try? Shell.run("/usr/bin/touch", [g.appURL.path])
                changed = true
            }
            try? "1\n".write(to: marker, atomically: true, encoding: .utf8)
        }
        return changed
    }

    // MARK: Launch

    /// Lines for a game's launcher that fetch what the store adds when a game starts (Epic: sign-in token and
    /// account; Amazon: its SDK settings). Fills STORE_ARGS; plays offline if the store can't be reached.
    public static func launcherLines(_ link: StoreLink) -> String {
        guard link.store != .gog else { return "STORE_ARGS=()\n" }
        let q = CustomGames.shellQuote
        let tool = q(StoreTools.url(link.store).path)
        let cmd: String
        switch link.store {
        case .epic: cmd = "LEGENDARY_CONFIG_PATH=\(q(StoreTools.configDir(.epic).path)) \(tool) launch \(q(link.id)) --json --skip-version-check"
        case .amazon: cmd = "NILE_CONFIG_PATH=\(q(StoreTools.configDir(.amazon).path)) \(tool) launch \(q(link.id)) --json"
        case .gog: cmd = "true"
        }
        let js = #"function run(a){var j=JSON.parse(a[0]),o=[],x=j.command?(j.command.arguments||[]):[].concat(j.game_parameters||[],j.user_parameters||[],j.egl_parameters||[]);x.forEach(function(v){o.push("A\t"+v)});var e=j.env||{};for(var k in e){o.push("E\t"+k+"="+e[k])}return o.join("\n")}"#
        return """
        # \(link.store.title): sign-in and launch details from the store (the game still starts offline without them).
        STORE_ARGS=()
        if [ -x \(tool) ] && [ "$CHECK_ONLY" = 0 ]; then
         STORE_JSON=$(env -u DYLD_INSERT_LIBRARIES \(cmd) 2>>"$LOG_DIR/store.log" | grep '^{' | tail -n 1 || true)
         if [ -n "$STORE_JSON" ]; then
          while IFS= read -r L; do
           case "$L" in
            A$'\\t'*) STORE_ARGS+=("${L#A$'\\t'}") ;;
            E$'\\t'*) export "${L#E$'\\t'}" ;;
           esac
          done < <(/usr/bin/osascript -l JavaScript -e \(q(js)) "$STORE_JSON" 2>/dev/null || true)
         else
          echo "nokcandu: \(link.store.title) didn't answer; starting offline"
         fi
        fi

        """
    }
}
