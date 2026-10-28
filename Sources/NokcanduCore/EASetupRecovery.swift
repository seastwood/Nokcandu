import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Recovery for an EA download whose final setup was never run. Runs the game's own original
/// Touchup package, not a replacement installer; no certificate stores or verifier settings change.
public enum EASetupRecovery {
    public struct Plan {
        public let folder: URL
        public let program: URL
        public let locale: String
        public let windowsFolder: String
        let hostApp: URL
        let fingerprints: [URL: String]
        public var name: String { folder.lastPathComponent }
        public var arguments: [String] {
            [program.path, "install", "-locale", locale, "-installPath", windowsFolder, "-autologging"]
        }
    }
    private final class Manifest: NSObject, XMLParserDelegate {
        var stack: [String] = [], paths: [String] = [], parameters: [String] = [], locales: [String] = []
        var root = "", text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if stack.isEmpty { root = name }
            stack.append(name); text = ""
            if name == "localeInfo", let locale = attributes["locale"], locale.range(of: "^[a-z]{2}_[A-Z]{2}$", options: .regularExpression) != nil {
                locales.append(locale)
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if stack == ["game", "executable", "filePath"] { paths.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if stack == ["game", "executable", "parameters"] { parameters.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            _ = stack.popLast(); text = ""
        }
    }
    static func manifestLocale(_ data: Data, preferred: String) throws -> String {
        guard data.count < 2_000_000 else { throw NokError("This EA setup manifest is too large.") }
        let reader = Manifest(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.root == "game", reader.paths.count == 1,
              reader.paths[0].lowercased() == "/__installer/touchup.exe",
              reader.parameters == [#"install -locale {locale} -installPath "{installLocation}" -autologging"#],
              !reader.locales.isEmpty else {
            throw NokError("This folder doesn't have a supported EA game setup package. Choose the game folder downloaded by EA.")
        }
        if reader.locales.contains(preferred) { return preferred }
        return reader.locales.contains("en_US") ? "en_US" : reader.locales[0]
    }
    static func windowsFolder(_ folder: URL, host: InstalledGame) throws -> String {
        if let path = CustomGames.windowsPath(forUnix: folder, prefix: host.prefix) { return path }
        // EA commonly records external folders through Z:. Prefer the same stable spelling.
        let drives = Drives.list(for: host).filter { $0.connected && !$0.gameDisc }
        let ordered = drives.sorted { a, b in
            if (a.letter == "Z") != (b.letter == "Z") { return a.letter == "Z" }
            return a.target.count > b.target.count
        }
        let path = folder.standardizedFileURL.path
        for drive in ordered {
            let base = URL(fileURLWithPath: drive.target).standardizedFileURL.path
            if path == base || path.hasPrefix(base == "/" ? "/" : base + "/") {
                let relative = path == base ? "" : String(path.dropFirst(base == "/" ? 1 : base.count + 1))
                return drive.letter + ":\\" + relative.replacingOccurrences(of: "/", with: "\\")
            }
        }
        throw NokError("This game folder isn't available inside EA's Windows environment. Add its drive under Game Drives first.")
    }
    public static func plan(folder selected: URL, host: InstalledGame, preferredLocale: String = Locale.current.identifier) throws -> Plan {
        guard PCLaunchers.kind(of: host) == .ea else { throw NokError("Choose your EA app in Nokcandu first.") }
        let folder = selected.standardizedFileURL, installer = folder.appendingPathComponent("__Installer")
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: installer, includingPropertiesForKeys: nil) else {
            throw NokError("Choose the game folder containing __Installer, downloaded by EA.")
        }
        let files = try ["Touchup.exe", "Touchup.dat", "installerdata.xml"].map { name -> URL in
            let matches = children.filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1 else { throw NokError("The EA setup package is missing a file or has ambiguous filenames. Choose the original game download folder.") }
            return matches[0]
        }
        guard folder.path.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\r\n")) == nil,
              installer.resolvingSymlinksInPath().deletingLastPathComponent() == folder.resolvingSymlinksInPath(),
              files.allSatisfy({ fm.isReadableFile(atPath: $0.path) && $0.resolvingSymlinksInPath().deletingLastPathComponent() == installer.resolvingSymlinksInPath() }),
              PEFile.inspect(files[0]) != nil else {
            throw NokError("Choose the EA game's folder containing __Installer, Touchup.exe and Touchup.dat. Its setup files must be intact.")
        }
        let locale = try manifestLocale(Data(contentsOf: files[2]), preferred: preferredLocale)
        let windows = try windowsFolder(folder, host: host)
        return Plan(folder: folder, program: files[0], locale: locale, windowsFolder: windows, hostApp: host.appURL.standardizedFileURL,
                    fingerprints: try Dictionary(uniqueKeysWithValues: files.map { ($0, try Hashing.sha256(file: $0)) }))
    }
    static func verifyUnchanged(_ plan: Plan) throws {
        guard plan.fingerprints.allSatisfy({ (try? Hashing.sha256(file: $0.key)) == $0.value }) else {
            throw NokError("EA's setup files changed. Wait for its download to finish, then choose the folder again.")
        }
    }
    static func installerEnvironment(_ original: [String: String]) -> [String: String] {
        var env = original, rules = CompatibilityFixes.overrides(original["WINEDLLOVERRIDES"])
        // EA Touchup has a supported fallback when the old Windows Games Explorer COM service
        // is unavailable. Wine's existing-game update can fail with ERROR_FILE_NOT_FOUND.
        // Scope this to setup; active games, prefix registry and saved renderer rules stay unchanged.
        rules["gameux"] = ""
        env["WINEDLLOVERRIDES"] = rules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        return env
    }
    /// User-requested recovery only. The EA client may remain open; the game must be closed.
    /// Calling the selected installer is equivalent to running a downloaded Windows installer.
    @discardableResult public static func finish(_ plan: Plan, host: InstalledGame) async throws -> URL {
        guard PCLaunchers.kind(of: host) == .ea, host.appURL.standardizedFileURL == plan.hostApp else { throw NokError("Choose the setup folder again for this EA app.") }
        try CompatibilityFixes.begin(host); defer { CompatibilityFixes.end(host) }
        try verifyUnchanged(plan)
        let logs = host.support.appendingPathComponent("Logs"); try NokPaths.ensure(logs)
        let log = logs.appendingPathComponent("ea-setup-\(CustomGames.slug(plan.name)).log")
        let ownLog = plan.program.deletingLastPathComponent().appendingPathComponent("InstallLog.txt")
        let previousLogSize = (try? ownLog.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let result = try await Shell.runAsync(host.support.appendingPathComponent("wine/bin/wine").path, plan.arguments,
            cwd: plan.program.deletingLastPathComponent(), env: installerEnvironment(WineTools.environment(contents: host.contents)), timeout: 1200)
        var diagnostic = "EA setup for \(plan.name)\nExit code: \(result.status)\n" + result.combined
        if let data = try? Data(contentsOf: ownLog), data.count < 8_000_000 {
            let current = data.count > previousLogSize ? Data(data.dropFirst(previousLogSize)) : data
            let encoding: String.Encoding = data.starts(with: [0xff, 0xfe]) || current.prefix(100).contains(0) ? .utf16LittleEndian : .utf8
            diagnostic += "\n" + (String(data: current, encoding: encoding) ?? "")
        }
        try Data(diagnostic.utf8).write(to: log, options: .atomic)
        guard result.ok else { throw NokError("EA's game setup didn't finish (exit \(result.status)). Details: \(log.path)") }
        return log
    }
}
