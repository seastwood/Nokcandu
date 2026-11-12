import Foundation

/// Opt-in backport of DXVK PR #3797's per-game configuration, without replacing
/// the renderer or modifying BF2 files. Gameplay acceptance remains separate.
public enum BF2DeploymentUI {
    static let flag = "NOKCANDU_BF2_DEPLOYMENT_UI"
    static let option = "d3d9.deviceLossOnFocusLoss"
    static let fileData = Data("[BF2.exe]\nd3d9.deviceLossOnFocusLoss = True\n".utf8)
    static func configurationFile(_ g: InstalledGame) -> URL? { gameProgram(g)?.deletingLastPathComponent().appendingPathComponent("dxvk.conf") }
    static func destination(_ file: URL) -> URL {
        // Foundation may leave all parent links unresolved when the leaf does
        // not exist. Resolve the legitimate game folder before adding the leaf.
        file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent)
    }
    static func needsUpdate(_ g: InstalledGame) -> Bool {
        guard CompatibilityFixes.isInstalled(.bf2DeploymentUI, for: g), let file = configurationFile(g) else { return false }
        return !CompatibilityFixes.journal(.bf2DeploymentUI, g).touchedPaths.contains(destination(file).path)
    }
    static func unavailable(_ g: InstalledGame) -> String? {
        guard supports(g), let file = configurationFile(g) else { return "Requires a private BF2/BF2Hub environment with a supported DXVK renderer." }
        let selected = g.custom?.environment?["DXVK_CONFIG_FILE"]
        let owned = CompatibilityFixes.state(.bf2DeploymentUI, g)?.appliedEnvironment?["DXVK_CONFIG_FILE"]
        if (selected != nil && selected != owned) || g.custom?.environment?["DXVK_CONFIG"]?.contains(option) == true {
            return "Your custom DXVK configuration already controls this option or its configuration file. It was preserved; review it before using this component."
        }
        if FileManager.default.fileExists(atPath: file.path),
           !CompatibilityFixes.journal(.bf2DeploymentUI, g).touchedPaths.contains(destination(file).path) {
            return "BF2 already has a dxvk.conf. It was preserved; review that file before using this component."
        }
        return nil
    }
    static func plannedFiles(_ g: InstalledGame) throws -> [URL: Data] {
        if let reason = unavailable(g) { throw NokError(reason) }
        guard let logical = configurationFile(g) else { throw NokError("BF2's configuration path is unavailable.") }
        let file = destination(logical)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else { throw NokError("BF2's configuration path is linked; it was preserved.") }
        return [file: fileData]
    }
    static func environment(_ g: InstalledGame) throws -> [String: String] {
        guard let file = configurationFile(g), let windows = CustomGames.windowsPath(forUnix: file, prefix: g.prefix) else { throw NokError("BF2's configuration needs a Windows C: path.") }
        return [flag: "1", "DXVK_CONFIG_FILE": windows]
    }
    static var launcherExports: String {
        // Apply after performance and explicit environment exports. An explicit
        // user value always wins, including False. Avoid replacing DXVK_CONFIG.
        """
        case "${DXVK_CONFIG:-}" in
         *d3d9.deviceLossOnFocusLoss*) ;;
         *) export DXVK_CONFIG="${DXVK_CONFIG:+$DXVK_CONFIG; }d3d9.deviceLossOnFocusLoss = True" ;;
        esac

        """
    }
    public static func supports(_ g: InstalledGame) -> Bool {
        guard !SharedGameCompatibility.isShared(g), g.native == nil,
              g.custom?.graphics == .classic3D,
              gameProgram(g) != nil else { return false }
        // The compatibility renderer selected by DirectX 8 compatibility is
        // older than d9vk. Inspect the actual selected library, not its label.
        let renderer = g.custom?.legacyD3D9 == true ? "dxvk" : "d9vk"
        let dll = g.support.appendingPathComponent("renderer/\(renderer)/wine/i386-windows/d3d9.dll")
        guard let size = try? dll.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 32 * 1024 * 1024,
              let data = try? Data(contentsOf: dll, options: .mappedIfSafe),
              data.range(of: Data(option.utf8)) != nil,
              data.range(of: Data("DXVK_CONFIG_FILE".utf8)) != nil else { return false }
        return true
    }
    static func gameProgram(_ g: InstalledGame) -> URL? {
        guard let program = CompatibilityFixes.managedProgram(g) else { return nil }
        let name = program.lastPathComponent.lowercased()
        if name == "bf2.exe" {
            return FileManager.default.fileExists(atPath: program.deletingLastPathComponent().appendingPathComponent("mods/bf2").path) ? program : nil
        }
        guard name == "bf2hub.exe" else { return nil }
        // BF2Hub is the existing launch route. Don't replace it with BF2.exe.
        let games = g.prefix.appendingPathComponent("drive_c/Games")
        let children = (try? FileManager.default.contentsOfDirectory(at: games, includingPropertiesForKeys: nil)) ?? []
        guard children.count <= 128 else { return nil }
        let matches = children.filter { folder in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("BF2.exe").path) &&
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("mods/bf2").path)
        }
        return matches.count == 1 ? matches[0].appendingPathComponent("BF2.exe") : nil
    }
}
