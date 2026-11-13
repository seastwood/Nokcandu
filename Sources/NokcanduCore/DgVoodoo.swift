import Foundation

/// dgVoodoo2 (freeware by Dege): Direct3D 8 and 9 implemented on Direct3D 11. Placed beside the game's
/// program with its configuration, it hands an older game's DirectX 8–9 to the game's DirectX 11 renderer —
/// DXMT, which draws with Metal directly — instead of translating it to Vulkan first. Downloaded from the
/// author's GitHub releases and checked against the checksum Nokcandu was tested with.
public enum DgVoodoo {
    public static let version = "2.87.6"
    static let assetName = "dgVoodoo2_87_6.zip"
    static let url = "https://github.com/dege-diosg/dgVoodoo2/releases/download/2.87.6/dgVoodoo2_87_6.zip"
    static let sha256 = "9afa493396feec7108f42a2d97661eef96bbaac5addf0dfb5cfbc3001cd76a0a"
    /// DirectX 10–11 renderers dgVoodoo's output can go to (DXMT is the one it's meant for here).
    public static let outputs: Set<GraphicsPreset> = [.dxmt, .modern3D, .appleMetal]
    static let settingsProgram = "dgVoodooCpl.exe"

    /// Opens dgVoodoo's settings program in the game's Windows environment, for the game's own copy.
    public static func openSettings(for g: InstalledGame) throws {
        guard CompatibilityFixes.isInstalled(.dgVoodoo, for: g), let exe = CompatibilityFixes.program(g) else {
            throw NokError("Install DirectX 8–9 through Metal (dgVoodoo2) first.")
        }
        let folder = exe.deletingLastPathComponent(), cpl = folder.appendingPathComponent(settingsProgram)
        guard FileManager.default.fileExists(atPath: cpl.path) else {
            throw NokError("dgVoodoo's settings program isn't beside the game. Undo the fix and install it again to add it.")
        }
        try WineTools.run([cpl.path], for: g, cwd: folder)
    }

    /// The package's DLLs for this program, by the name they take beside it.
    static func libraries(is64Bit: Bool) -> [(entry: String, name: String)] {
        is64Bit ? [("MS/x64/D3D9.dll", "d3d9.dll")] : [("MS/x86/D3D8.dll", "d3d8.dll"), ("MS/x86/D3D9.dll", "d3d9.dll")]
    }
    static func overrides(is64Bit: Bool) -> [String: String] {
        is64Bit ? ["d3d9": "n"] : ["d3d8": "n", "d3d9": "n"]
    }

    /// dgVoodoo's own configuration with the settings this fix needs: DirectX 11 output, a GeForce 9800 GT as
    /// the card games see, no watermark, and more video memory than its 256 MB default (later DirectX 9 games
    /// run out). Everything else is dgVoodoo's.
    static func configuration(_ original: String) -> String {
        var section = ""
        let lines = original.components(separatedBy: "\n").map { raw -> String in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw, cr = raw.hasSuffix("\r") ? "\r" : ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { section = trimmed; return raw }
            func set(_ key: String, _ value: String) -> String? {
                guard trimmed.hasPrefix(key), trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=") else { return nil }
                return key.padding(toLength: max(key.count, 37), withPad: " ", startingAt: 0) + "= " + value + cr
            }
            switch section {
            case "[General]": if let s = set("OutputAPI", "d3d11_fl11_0") { return s }
            case "[DirectX]":
                // dgVoodoo's own card exposes more than many older games handle (Battlefield 2 crashed at start
                // with it); its release notes recommend this card for such games, and they know it by name.
                if let s = set("VideoCard", "geforce_9800_gt") { return s }
                if let s = set("dgVoodooWatermark", "false") { return s }
                if let s = set("VRAM", "1024") { return s }
            default: break
            }
            return raw
        }
        return lines.joined(separator: "\n")
    }

    /// Files for the game's program folder, from the verified package.
    static func plannedFiles(for program: URL, work: URL, log: @escaping @Sendable (String) -> Void) async throws -> [URL: Data] {
        guard let pe = PEFile.inspect(program) else { throw NokError("The game's program couldn't be read.") }
        let archive = try await CompatibilityFixes.verifiedDownload(assetName, url: url, sha: sha256, log: log)
        let out = work.appendingPathComponent("dgvoodoo"); try NokPaths.ensure(out)
        let wanted = libraries(is64Bit: pe.is64Bit).map(\.entry) + ["dgVoodoo.conf", "dgVoodooCpl.exe"]
        let r = try Shell.run("/usr/bin/unzip", ["-q", "-o", archive.path] + wanted + ["-d", out.path], timeout: 120)
        guard r.ok else { throw NokError("dgVoodoo2's package couldn't be unpacked: \(r.combined.suffix(200))") }
        let folder = program.deletingLastPathComponent()
        var files: [URL: Data] = [:]
        for (entry, name) in libraries(is64Bit: pe.is64Bit) {
            let source = out.appendingPathComponent(entry)
            guard let data = try? Data(contentsOf: source), data.count > 100_000 else { throw NokError("dgVoodoo2's \(name) is missing from its package. Nothing was installed.") }
            files[folder.appendingPathComponent(name)] = data
        }
        guard let conf = try? String(contentsOf: out.appendingPathComponent("dgVoodoo.conf"), encoding: .utf8) else {
            throw NokError("dgVoodoo2's configuration is missing from its package. Nothing was installed.")
        }
        files[folder.appendingPathComponent("dgVoodoo.conf")] = Data(configuration(conf).utf8)
        // dgVoodoo's own settings program, beside its configuration (it edits the file in its own folder).
        if let cpl = try? Data(contentsOf: out.appendingPathComponent("dgVoodooCpl.exe")), cpl.count > 100_000 {
            files[folder.appendingPathComponent(settingsProgram)] = cpl
        }
        return files
    }
}
