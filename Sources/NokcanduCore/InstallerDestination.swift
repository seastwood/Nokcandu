import Foundation

/// Select the already prepared game folder using a recognized installer's documented
/// directory switch. Unknown installers keep their interactive destination selection.
public enum InstallerDestination {
    public static func preferredDirectory(in ctx: InstallContext) -> String? {
        guard let selected = ctx.input("filesFolder"), CustomInstall.source(ctx) == .installer,
              ctx.input("launcherKind") == nil else { return nil }
        let folder = CustomInstall.gamesFolder(ctx)
        let expected = URL(fileURLWithPath: selected).appendingPathComponent(folder.lastPathComponent)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil,
              folder.resolvingSymlinksInPath().standardizedFileURL.path == expected.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return CustomGames.windowsPath(forUnix: folder, prefix: ctx.prefix)
    }

    static func isInnoSetup(_ installer: URL) -> Bool {
        guard installer.pathExtension.lowercased() == "exe", let file = try? FileHandle(forReadingFrom: installer) else { return false }
        defer { try? file.close() }
        // The loader signature lives near the beginning, even with a multi-GB payload.
        // False negatives fall back to the visible destination instruction and safe relocation.
        guard let data = try? file.read(upToCount: 4 * 1024 * 1024), PEFile.parse(data) != nil else { return false }
        return data.range(of: Data("Inno Setup Setup Data (".utf8)) != nil
    }

    static func arguments(for installer: URL, in ctx: InstallContext) -> [String] {
        var args = ["start", "/unix", installer.path]
        if let directory = preferredDirectory(in: ctx), isInnoSetup(installer) {
            args.append("/DIR=" + directory)
        }
        return args
    }
}
