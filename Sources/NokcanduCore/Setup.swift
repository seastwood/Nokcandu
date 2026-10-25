import Foundation

/// What a brand-new Mac needs before Nokcandu can install games: Apple silicon + Rosetta 2 (Wine is
/// Intel code) and the tested Wine engine with its graphics/wrapper files (downloaded from the
/// Sikarugir project on GitHub and checked byte-for-byte against the hashes Nokcandu was tested with).
public enum Setup {
    public static var isAppleSilicon: Bool {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var v: Int32 = 0
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }

    public static var rosettaInstalled: Bool {
        (try? Shell.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], timeout: 20))?.ok ?? false
    }

    /// Installs Rosetta 2 (macOS asks for an administrator password).
    public static func installRosetta() async throws {
        let script = #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
        let r = try await Shell.runAsync("/usr/bin/osascript", ["-e", script], timeout: 900)
        guard r.ok || rosettaInstalled else { throw NokError("Rosetta wasn't installed: \(r.combined.suffix(300))") }
    }

    public static var engineReady: Bool { RuntimeManager.isCached(RecipeCatalog.sikarugirWine10) }

    public static var needsAttention: Bool { !isAppleSilicon || !rosettaInstalled || !engineReady }

    // The exact downloads Nokcandu's recipes were validated with (sha256 from the GitHub releases,
    // re-checked on this Mac: their wine and renderer files match the recipes' pinned hashes).
    static let testedEngine = ReleaseAsset(
        name: "WS12WineSikarugir10.0_8.tar.xz", size: 166_321_980,
        url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_8.tar.xz")!,
        sha256: "2a6bcf2a3bf13cddf825599b6bc1e3659cbf71e1282c6d77141a92f6ac8d4c68", updated: nil)
    static let testedTemplate = ReleaseAsset(
        name: "Template-1.0.24.tar.xz", size: 96_198_448,
        url: URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.24.tar.xz")!,
        sha256: "4b5f89eeb9ef139936bdfad33d9b420b05ea4597cb7d63376674f7a8e171321c", updated: nil)

    /// Downloads and verifies the tested engine + template into Nokcandu's engine cache (~260 MB download).
    public static func downloadTestedEngine(log: @escaping @Sendable (String) -> Void) async throws {
        let spec = RecipeCatalog.sikarugirWine10
        if RuntimeManager.isCached(spec) { return }
        guard rosettaInstalled else { throw NokError("Install Rosetta first — Wine needs it.") }
        let cat = UpdateCatalog(checkedAt: Date(), engines: [testedEngine], templates: [testedTemplate], lav: nil, nativeEngines: [])
        let id = try await RuntimeManager.build(engine: .tested, template: .tested, catalog: cat, log: log)
        guard id == spec.id else { throw NokError("Unexpected engine id \(id).") }
        for (rel, want) in RuntimeManager.runtimePins(RecipeCatalog.zeroHour) {
            let got = try? Hashing.sha256(file: RuntimeManager.folder(for: id).appendingPathComponent("Contents/\(rel)"))
            guard got == want else {
                try? FileManager.default.removeItem(at: RuntimeManager.folder(for: id))
                throw NokError("Downloaded engine file \(rel) doesn't match the tested build; it was removed.")
            }
        }
        log("Tested engine ready.")
    }
}
