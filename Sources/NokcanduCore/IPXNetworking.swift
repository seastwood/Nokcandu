import Foundation

/// Optional Winsock 1 / legacy DirectPlay IPX-over-UDP for private game environments.
/// Never changes the Mac network, the engine, service-provider registration or another game.
public enum IPXNetworking {
    public static let version = "0.7.2"
    static let archiveSHA = "a32255f528533be0add8eeabb0794fcbf8b025110cb4624b79dbb82698e6a404"
    static let dlls = ["ipxwrapper.dll", "mswsock.dll", "wsock32.dll", "dpwsockx.dll"]
    static let overrides = Dictionary(uniqueKeysWithValues: (dlls + ["dplayx.dll"]).map { (String($0.dropLast(4)), "n,b") })

    /// The first component revision initialized successfully but crashed on CreatePlayer
    /// with Wine's builtin DirectPlay and IPXWrapper's legacy callback table.
    public static func needsUpdate(_ g: InstalledGame) -> Bool {
        guard let state = CompatibilityFixes.state(.ipxNetworking, g) else { return false }
        return state.appliedOverrides["dplayx"] == nil
    }

    public static func supports(_ g: InstalledGame) -> Bool {
        guard g.custom != nil, !g.usesSharedSteam, g.hosted == nil, g.battleNet == nil, g.native == nil,
              let exe = CompatibilityFixes.managedProgram(g), let pe = PEFile.inspectWithLoadedDLLs(exe), !pe.is64Bit else { return false }
        // Networking may be loaded through COM or a game engine rather than a static import.
        // Offer the opt-in component to all private 32-bit programs; the game must itself
        // support legacy Winsock 1 / DirectPlay IPX. This does not add IPX to Winsock 2 APIs.
        return true
    }

    static func plannedFiles(_ payload: [String: Data], for g: InstalledGame) throws -> [URL: Data] {
        guard supports(g), let exe = CompatibilityFixes.managedProgram(g) else {
            throw NokError("IPX networking is available for 32-bit games using legacy Winsock or DirectPlay in their own Windows environment.")
        }
        let root = exe.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var result: [URL: Data] = [:]
        let members = dlls + ["ipxconfig.exe", "license.txt", "readme.txt"]
        for name in members {
            guard let data = payload[name] else { throw NokError("The IPX package is incomplete. Nothing was installed.") }
            if name.hasSuffix(".dll") || name.hasSuffix(".exe") {
                // Inspect actual archive bytes before any game files change.
                guard let parsed = PEFile.parse(data), !parsed.is64 else { throw NokError("The IPX package has an unsupported program architecture.") }
            }
            let targetName = name == "license.txt" ? "ipxwrapper-license.txt" : name == "readme.txt" ? "ipxwrapper-readme.txt" : name
            let target = root.appendingPathComponent(targetName)
            guard target.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL else {
                throw NokError("\(targetName) is a link. It was left untouched.")
            }
            if FileManager.default.fileExists(atPath: target.path), (try? Data(contentsOf: target)) != data {
                throw NokError("\(targetName) already exists and differs from this IPX release. It was left untouched.")
            }
            result[target] = data
        }
        for name in ["dplayx.dll", "dpwsockx.dll", "dplaysvr.exe"] {
            guard let data = payload["directplay/" + name], let pe = PEFile.parse(data), !pe.is64 else {
                throw NokError("The legacy DirectPlay package is incomplete or has the wrong architecture.")
            }
            result[g.prefix.appendingPathComponent("drive_c/windows/syswow64/" + name)] = data
        }
        try validateDestinations(result, for: g)
        return result
    }

    /// COM and IPXWrapper's forwarding loader use the private 32-bit system folder.
    /// Replace only an exact untouched copy of this game's bundled Wine file.
    static func validateDestinations(_ files: [URL: Data], for g: InstalledGame) throws {
        for (target, data) in files {
            guard target.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL else {
                throw NokError("An IPX destination is a link. It was left untouched.")
            }
            guard FileManager.default.fileExists(atPath: target.path), (try? Data(contentsOf: target)) != data else { continue }
            let system = g.prefix.appendingPathComponent("drive_c/windows/syswow64").standardizedFileURL
            let bundled = g.support.appendingPathComponent("wine/lib/wine/i386-windows/" + target.lastPathComponent)
            guard target.deletingLastPathComponent().standardizedFileURL == system,
                  ["dplayx.dll", "dpwsockx.dll", "dplaysvr.exe"].contains(target.lastPathComponent),
                  let original = try? Data(contentsOf: bundled), (try? Data(contentsOf: target)) == original else {
                throw NokError("\(target.lastPathComponent) differs from the managed release. It was left untouched.")
            }
        }
    }

    static func download(for g: InstalledGame, work: URL, log: @escaping @Sendable (String) -> Void) async throws -> [URL: Data] {
        let zip = try await CompatibilityFixes.verifiedDownload("ipxwrapper-\(version).zip",
            url: "https://github.com/solemnwarning/ipxwrapper/releases/download/ipxwrapper-\(version)/ipxwrapper-\(version).zip",
            sha: archiveSHA, log: log)
        let members = dlls + ["ipxconfig.exe", "license.txt", "readme.txt"]
        let result = try await Shell.runAsync("/usr/bin/unzip", ["-j", "-q", zip.path] + members.map { "ipxwrapper-\(version)/\($0)" } + ["-d", work.path], timeout: 30)
        guard result.ok else { throw NokError("Couldn't extract the verified IPX release.") }
        var payload: [String: Data] = [:]
        for name in members { payload[name] = try Data(contentsOf: work.appendingPathComponent(name)) }
        // June 2010 no longer contains the legacy DirectPlay core. Use the exact
        // February package pinned by Winetricks; the original Microsoft URL is gone.
        let redist = try await CompatibilityFixes.verifiedDownload("directx_feb2010_redist.exe",
            url: "https://files.holarse-linuxgaming.de/mirrors/microsoft/directx_feb2010_redist.exe",
            sha: "f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f", log: log)
        guard let cab = NokPaths.bundledResource("cabextract", executable: true) else { throw NokError("Nokcandu's installer reader is missing.") }
        let outer = try await Shell.runAsync(cab.path, ["-q", "-L", "-F", "dxnt.cab", "-d", work.path, redist.path], timeout: 120)
        guard outer.ok else { throw NokError("Couldn't extract the legacy DirectPlay package.") }
        let native = work.appendingPathComponent("directplay"); try NokPaths.ensure(native)
        let pins = ["dplayx.dll": "f50362966d69446f3f562946e77cb72ba8058abcddfadac4d2b0841e07434c3c",
                    "dpwsockx.dll": "0725598871b2f1f65ccd0235683873346c8024a38dead045bce20526af65654d",
                    "dplaysvr.exe": "e3ee1e2d903237131ba42c770f07e7eceaa3574b4ce718062a4e3c1f9cdbf893"]
        for (name, sha) in pins {
            let extracted = try await Shell.runAsync(cab.path, ["-q", "-L", "-F", name, "-d", native.path, work.appendingPathComponent("dxnt.cab").path], timeout: 120)
            guard extracted.ok else { throw NokError("Couldn't extract legacy DirectPlay's \(name).") }
            let data = try Data(contentsOf: native.appendingPathComponent(name))
            guard Hashing.sha256(data: data) == sha else { throw NokError("The legacy DirectPlay library did not match its fingerprint.") }
            payload["directplay/" + name] = data
        }
        return try plannedFiles(payload, for: g)
    }

    public static func configure(_ g: InstalledGame) throws {
        guard CompatibilityFixes.isInstalled(.ipxNetworking, for: g), let exe = CompatibilityFixes.managedProgram(g) else {
            throw NokError("Install IPX networking first.")
        }
        let config = exe.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("ipxconfig.exe")
        let ledger = CompatibilityFixes.journal(.ipxNetworking, g)
        guard let expected = ledger.entries.last(where: { $0.path == config.path })?.shaAfter,
              (try? Hashing.sha256(file: config)) == expected else { throw NokError("The IPX settings tool changed. Undo and reinstall the fix.") }
        try WineTools.runProgram(config, for: g)
    }
}
