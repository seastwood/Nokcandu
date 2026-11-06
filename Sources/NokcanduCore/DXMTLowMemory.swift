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

    public struct Release: Equatable, Sendable {
        public var tag: String, assetName: String, url: String, sha256: String
    }
    /// The build Nokcandu was tested with; used when GitHub can't be reached.
    static let pinned = Release(tag: version, assetName: "dxmt-ow2-pack-v0.2.tar.gz", url: url, sha256: sha256)

    /// The newest published Overwatch build (tags like v0.80-ow2-0.2) whose package has a GitHub-published SHA-256.
    /// Releases come newest first; drafts never appear and pre-releases aren't used.
    static func newest(from releases: [Updates.GHRelease]) -> Release? {
        for r in releases where r.tag_name.contains("-ow2-") && r.prerelease != true {
            for a in r.assets where a.name.hasPrefix("dxmt-ow2-pack") && a.name.hasSuffix(".tar.gz") {
                guard let d = a.digest, d.hasPrefix("sha256:") else { continue }
                return Release(tag: r.tag_name, assetName: a.name, url: a.browser_download_url.absoluteString, sha256: String(d.dropFirst(7)).lowercased())
            }
        }
        return nil
    }

    static func files(into folder: URL, work: URL, log: @escaping @Sendable (String) -> Void) async throws -> [URL: Data] {
        let release = ((try? await Updates.releases("NerRobDog/dxmt", perPage: 10)).flatMap(newest)) ?? pinned
        if release != pinned { log("Using the newest Overwatch DXMT build, \(release.tag).") }
        let archive = try await CompatibilityFixes.verifiedDownload(release.assetName, url: release.url, sha: release.sha256, log: log)
        let out = work.appendingPathComponent("dxmt")
        try NokPaths.ensure(out)
        let r = try Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", out.path], timeout: 120)
        guard r.ok else { throw NokError("The DXMT package couldn't be unpacked: \(r.combined.suffix(200))") }
        return try plannedFiles(from: packageRoot(out), into: folder)
    }

    /// The folder holding the architecture folders: the archive's single top folder, or the archive itself.
    static func packageRoot(_ out: URL) -> URL {
        let fm = FileManager.default
        if architectures.contains(where: { fm.fileExists(atPath: out.appendingPathComponent($0).path) }) { return out }
        let tops = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).filter { !$0.hasPrefix(".") }
        return tops.count == 1 ? out.appendingPathComponent(tops[0]) : out.appendingPathComponent("dxmt-ow2-pack")
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
