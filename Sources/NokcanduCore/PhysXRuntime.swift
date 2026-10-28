import Foundation

/// NVIDIA's original runtime, installed into the selected Windows environment (never macOS).
/// Shared by every game in that environment. No loose DLL downloads or GPU driver installation.
public enum PhysXRuntime {
    public static func installed(contents: URL) -> Bool {
        let c = contents.appendingPathComponent("SharedSupport/prefix/drive_c")
        return PEFile.inspect(c.appendingPathComponent("Program Files (x86)/NVIDIA Corporation/PhysX/Common/PhysXLoader.dll"))?.is64Bit == false &&
            FileManager.default.fileExists(atPath: c.appendingPathComponent("Program Files (x86)/NVIDIA Corporation/PhysX/Engine/v2.8.1/PhysXCore.dll").path)
    }
    /// Read imports, not a game's title: a downloaded game that requires PhysX can request setup.
    public static func required(in folder: URL) -> Bool {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return false }
        var count = 0
        for case let file as URL in walk {
            let info = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if info?.isSymbolicLink == true { continue }
            if walk.level > 3 { if info?.isDirectory == true { walk.skipDescendants() }; continue }
            guard ["dll", "exe"].contains(file.pathExtension.lowercased()) else { continue }
            count += 1
            if count > 1000 { break }
            if PEFile.inspect(file)?.imports.contains(where: { $0.lowercased() == "physxloader.dll" || $0.lowercased() == "physxloader64.dll" }) == true { return true }
        }
        return false
    }
    public static func install(for game: InstalledGame, log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard let c = WineTools.hostContents(for: game) else { throw NokError("This game has no Windows environment.") }
        if installed(contents: c) { return }
        log("Downloading NVIDIA PhysX runtime…")
        let package = try await CompatibilityFixes.verifiedDownload("PhysX_9.23.1019_SystemSoftware.exe",
            url: "https://us.download.nvidia.com/Windows/9.23.1019/PhysX_9.23.1019_SystemSoftware.exe",
            sha: "9b42b84e881769d681e09f62a1b51532616b2e6a2d5d99d0ccae6eb5fbbc208c", log: log)
        log("Installing NVIDIA PhysX into this Windows environment…")
        let result = try await Shell.runAsync(c.appendingPathComponent("SharedSupport/wine/bin/wine").path,
            [package.path, "/s"], cwd: package.deletingLastPathComponent(), env: WineTools.environment(contents: c), timeout: 600)
        let file = c.appendingPathComponent("SharedSupport/Logs/physx-setup.log")
        try NokPaths.ensure(file.deletingLastPathComponent())
        try Data(("Exit code: \(result.status)\n" + result.combined).utf8).write(to: file, options: .atomic)
        guard result.ok, installed(contents: c) else { throw NokError("PhysX setup could not be confirmed. Details: \(file.path)") }
    }
}
