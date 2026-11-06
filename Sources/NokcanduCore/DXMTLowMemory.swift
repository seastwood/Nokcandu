import Foundation

/// NerRobDog's DXMT build for Overwatch 2 (upstream DXMT v0.80 plus d3d11.releaseShaderIR, on by default):
/// the same layout as Nokcandu's DXMT (renderer/dxmt/wine/<arch>/…), installed beside the game's program and
/// selected for that game alone through WINEDLLPATH_DXMT. Includes arm64 builds for native ARM Wine.
public enum DXMTLowMemory {
    public static let version = "v0.80-ow2-0.2"
    static let url = "https://github.com/NerRobDog/dxmt/releases/download/v0.80-ow2-0.2/dxmt-ow2-pack-v0.2.tar.gz"
    static let sha256 = "8d4e778ff9868883a064d7b9bfb372ed6e286e4233f60c053075ca983b2bc256"
    static let folderName = "nokcandu-dxmt-low-memory"
    /// Only these architecture folders and library types are taken from the package.
    static let architectures = ["i386-windows", "x86_64-windows", "x86_64-unix", "aarch64-windows", "aarch64-unix"]

    static func files(into folder: URL, work: URL, log: @escaping @Sendable (String) -> Void) async throws -> [URL: Data] {
        let archive = try await CompatibilityFixes.verifiedDownload("dxmt-ow2-pack-v0.2.tar.gz", url: url, sha: sha256, log: log)
        let out = work.appendingPathComponent("dxmt")
        try NokPaths.ensure(out)
        let r = try Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", out.path], timeout: 120)
        guard r.ok else { throw NokError("The DXMT package couldn't be unpacked: \(r.combined.suffix(200))") }
        return try plannedFiles(from: out.appendingPathComponent("dxmt-ow2-pack"), into: folder)
    }

    /// Package files → destinations. Anything that isn't a DLL or a unix library in a known folder is ignored.
    static func plannedFiles(from package: URL, into folder: URL) throws -> [URL: Data] {
        let fm = FileManager.default
        var files: [URL: Data] = [:]
        for arch in architectures {
            let dir = package.appendingPathComponent(arch)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".dll") || name.hasSuffix(".so") {
                guard !name.contains("/"), !name.hasPrefix(".") else { continue }
                var isLink = false
                if let type = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.type] as? FileAttributeType { isLink = type == .typeSymbolicLink }
                guard !isLink else { continue }
                files[folder.appendingPathComponent("wine/\(arch)/\(name)")] = try Data(contentsOf: dir.appendingPathComponent(name))
            }
        }
        guard files.keys.contains(where: { $0.path.hasSuffix("x86_64-windows/d3d11.dll") }),
              files.keys.contains(where: { $0.path.hasSuffix("x86_64-unix/winemetal.so") }) else {
            throw NokError("The DXMT package is missing its 64-bit libraries. Nothing was installed.")
        }
        return files
    }
}
