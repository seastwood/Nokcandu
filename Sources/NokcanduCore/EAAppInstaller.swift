import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

/// Shared MSI command construction: properties containing spaces must be quoted at the value,
/// not as a whole NAME=value argument. A batch file avoids Wine's host argv reconstruction.
enum WindowsMSI {
    static func command(package: String, log: String, properties: [String: String]) throws -> String {
        func quoted(_ value: String) throws -> String {
            guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }),
                  value.rangeOfCharacter(from: CharacterSet(charactersIn: "\"%!^&|<>")) == nil else {
                throw NokError("An installer property contains unsupported command characters.")
            }
            return "\"" + value + "\""
        }
        let args = try properties.sorted { $0.key < $1.key }.map { key, value in
            guard key.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil else {
                throw NokError("An installer property name is invalid.")
            }
            return key + "=" + (try quoted(value))
        }
        return "@echo off\r\nmsiexec /i \(try quoted(package)) /qn /norestart /l*v \(try quoted(log)) " + args.joined(separator: " ") + "\r\nexit /b %errorlevel%\r\n"
    }
}

/// Reads EA's current signed WiX bundle metadata, rather than pinning a quickly obsolete MSI URL.
/// Only official EA payload locations, plain filenames, version numbers and GUIDs are accepted.
enum EAAppInstaller {
    struct Package: Equatable {
        var name: String, url: URL, sha1: String, size: Int64, version: String, provider: String
    }
    private final class ManifestReader: NSObject, XMLParserDelegate {
        var payloads: [[String: String]] = [], registration: [String: String] = [:], version = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if elementName == "Payload", attributes["Packaging"] == "external", attributes["FilePath"]?.hasSuffix(".msi") == true { payloads.append(attributes) }
            if elementName == "Registration" { registration = attributes }
            if elementName == "Variable", attributes["Id"] == "CLIENT_VERSION" { version = attributes["Value"] ?? "" }
        }
    }
    static func package(from data: Data) throws -> Package {
        guard data.count < 1_000_000 else { throw NokError("EA's installer metadata is too large.") }
        let reader = ManifestReader(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), reader.payloads.count == 1, let a = reader.payloads.first,
              let name = a["FilePath"], name.range(of: "^EAapp-[A-Za-z0-9._-]+\\.msi$", options: .regularExpression) != nil,
              let url = a["DownloadUrl"].flatMap(URL.init(string:)), official(url), url.lastPathComponent == name,
              let hash = a["Hash"], hash.range(of: "^[A-Fa-f0-9]{40}$", options: .regularExpression) != nil,
              let size = a["FileSize"].flatMap(Int64.init), (1_000_000...1_000_000_000).contains(size),
              reader.version.range(of: "^[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil,
              let provider = reader.registration["ProviderKey"],
              provider.range(of: "^\\{[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}\\}$", options: .regularExpression) != nil,
              reader.registration["ExecutableName"] == "EAappInstaller.exe" else {
            throw NokError("EA's installer format changed. Nokcandu couldn't verify its Windows package; nothing was installed.")
        }
        return Package(name: name, url: url, sha1: hash.lowercased(), size: size, version: reader.version, provider: provider)
    }
    static func official(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "origin-a.akamaihd.net" && url.port == nil && url.user == nil && url.password == nil &&
        url.query == nil && url.fragment == nil && url.path.hasPrefix("/EA-Desktop-Client-Download/installer-releases/")
    }
    static func verifies(_ file: URL, package: Package) -> Bool {
        guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(package.size),
              let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        var sha = Insecure.SHA1()
        do {
            while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        } catch { return false }
        return sha.finalize().map { String(format: "%02x", $0) }.joined() == package.sha1
    }
    static func configureClient(_ game: InstalledGame, log: @escaping @Sendable (String) -> Void) async throws {
        // Shared optional components, referenced by the same IDs in saved and shared profiles.
        for fix in [CompatibilityFix.bundledVC, .crossProcessWindows] {
            let current = CompatibilityFixes.fresh(game)
            if !CompatibilityFixes.isInstalled(fix, for: current) {
                try await CompatibilityFixes.install(fix, for: current, log: log)
            }
        }
    }
    static let program = #"C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\EADesktop.exe"#
    static func run(_ ctx: InstallContext, installer: URL) async throws {
        guard let cab = NokPaths.bundledResource("cabextract") else { throw NokError("Nokcandu's installer reader is missing. Update Nokcandu first.") }
        let work = ctx.workDir.appendingPathComponent("ea-package")
        try NokPaths.ensure(work)
        ctx.reportProgress("Reading EA's Windows package")
        let unpack = try await Shell.runAsync(cab.path, ["-q", "-F", "0", "-d", work.path, installer.path], timeout: 60)
        guard unpack.ok else { throw NokError("Couldn't read EA's installer. Download it again from EA.") }
        let info = try package(from: Data(contentsOf: work.appendingPathComponent("0")))
        let msi = NokPaths.downloads.appendingPathComponent(info.name)
        if !verifies(msi, package: info) {
            ctx.reportProgress("Downloading EA app \(info.version)")
            let (temp, response) = try await URLSession.shared.download(from: info.url)
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.url.map(official) == true, verifies(temp, package: info) else {
                throw NokError("EA's Windows package download didn't match its installer metadata. Try again.")
            }
            try NokPaths.ensure(NokPaths.downloads)
            if FileManager.default.fileExists(atPath: msi.path) { try FileManager.default.removeItem(at: msi) }
            try FileManager.default.moveItem(at: temp, to: msi)
        }
        try Task.checkCancellation()
        // Reproduce the bootstrapper's own cache and registration, required by EA's registry action.
        // All changes are in this new app's private prefix; EA's original binaries are never patched.
        let cache = ctx.prefix.appendingPathComponent("drive_c/ProgramData/Package Cache/\(info.provider)")
        try NokPaths.ensure(cache)
        try Data(contentsOf: installer).write(to: cache.appendingPathComponent("EAappInstaller.exe"), options: .atomic)
        let stage = ctx.prefix.appendingPathComponent("drive_c/nokcandu/ea-install")
        try NokPaths.ensure(stage)
        let stagedMSI = stage.appendingPathComponent("setup.msi")
        if FileManager.default.fileExists(atPath: stagedMSI.path) { try FileManager.default.removeItem(at: stagedMSI) }
        try FileManager.default.cloneItem(at: msi, to: stagedMSI)
        defer { try? FileManager.default.removeItem(at: stagedMSI) }
        let reg = "Windows Registry Editor Version 5.00\n\n[HKEY_LOCAL_MACHINE\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\\(info.provider)]\n\"DisplayName\"=\"EA app\"\n"
        try reg.write(to: stage.appendingPathComponent("cache.reg"), atomically: true, encoding: .utf8)
        let imported = try await ctx.runWine(["regedit", "/S", #"C:\nokcandu\ea-install\cache.reg"#], timeout: 120)
        guard imported.ok else { throw NokError("Couldn't prepare EA's installer cache. See the setup log.") }
        let script = try WindowsMSI.command(package: #"C:\nokcandu\ea-install\setup.msi"#, log: #"C:\nokcandu\ea-install\install.log"#,
            properties: ["EAX_DISABLE_SYMLINKS": "1", "INSTALL_ROOT": #"C:\Program Files\Electronic Arts\EA Desktop"#,
                         "CLIENT_VERSION": info.version, "EAX_LAUNCH_CLIENT": "0", "BUNDLE_PROVIDERKEY": info.provider,
                         "EAX_BUNDLE_EXECUTABLE_NAME": "EAappInstaller.exe"])
        try script.write(to: stage.appendingPathComponent("install.cmd"), atomically: true, encoding: .utf8)
        ctx.log("Installing EA app \(info.version) with EA's directory-link option disabled. Original installer files are unchanged.")
        ctx.reportProgress("Installing EA app")
        let result = try await ctx.runWine(["cmd", "/c", #"C:\nokcandu\ea-install\install.cmd"#], timeout: 1800)
        let diagnostic = ctx.support.appendingPathComponent("Logs/ea-install.log")
        if let log = try? Data(contentsOf: stage.appendingPathComponent("install.log")) { try? log.write(to: diagnostic, options: .atomic) }
        let exe = ctx.prefix.appendingPathComponent("drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe")
        guard result.ok, PEFile.inspect(exe) != nil else {
            throw NokError("EA setup didn't complete (exit \(result.status)). Installer details: \(diagnostic.path). You can retry this step.")
        }
        ctx.state.inputs["exe"] = program
        if ctx.input("graphics") == nil { ctx.state.inputs["graphics"] = GraphicsPreset.dxmt.rawValue }
        ctx.state.inputs["launcherKind"] = PCLauncher.ea.rawValue
        ctx.state.inputs["acquire.finished"] = "1"
        try ctx.saveState()
        ctx.log("EA app installed and its program verified. Sign in when you open it.")
    }
}
