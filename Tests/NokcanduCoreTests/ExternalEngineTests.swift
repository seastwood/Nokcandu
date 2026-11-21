import XCTest
@testable import NokcanduCore

final class ExternalEngineTests: XCTestCase {
    func testVersionStringRoundTrips() {
        let text = ExternalEngines.versionString(id: "ext-metalsharp-v8.0", wine: "11.20")
        XCTAssertEqual(text, "wine external ext-metalsharp-v8.0 11.20")
        let v = EngineVersion(versionString: text)!
        XCTAssertEqual(v.external, "ext-metalsharp-v8.0")
        XCTAssertEqual(v.major, 11); XCTAssertEqual(v.minor, 20)
        XCTAssertTrue(v.isARM)
        XCTAssertEqual(v.tag, "ext-metalsharp-v8.0")
        XCTAssertEqual(v.versionString, text)
        XCTAssertNil(EngineVersion(versionString: "wine sikarugir 11.0 (revision 1)")!.external)
    }

    /// An imported Intel engine keeps its processor in its version text.
    func testIntelImports() {
        let text = ExternalEngines.versionString(id: "ext-gcenx-11.21", wine: "11.21", arch: .x86_64)
        XCTAssertEqual(text, "wine external ext-gcenx-11.21 11.21 x86_64")
        let v = EngineVersion(versionString: text)!
        XCTAssertFalse(v.isARM); XCTAssertEqual(v.external, "ext-gcenx-11.21"); XCTAssertEqual(v.versionString, text)
        XCTAssertTrue(v.description.hasSuffix("(imported)"))
    }

    /// A copied (unsigned) engine can be adjusted by Nokcandu; a signed one, or one Nokcandu can't read, can't.
    func testSealedComesFromTheEngineRecord() throws {
        let fm = FileManager.default
        let wine = fm.temporaryDirectory.appendingPathComponent("ext-sealed-\(UUID().uuidString)")
        try fm.createDirectory(at: wine, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: wine) }
        XCTAssertFalse(EngineLayout(wine: wine).isSealed, "Sikarugir's engines have no record")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        func record(sealed: Bool) throws {
            let i = ExternalEngines.Info(id: "ext-a", name: "A", source: nil, release: "1", wineVersion: "11.0", installedAt: Date(),
                                         engine: "x", from: "y", license: nil, sealed: sealed, arch: .x86_64)
            try enc.encode(i).write(to: wine.appendingPathComponent("engine.json"))
        }
        try record(sealed: false); XCTAssertFalse(EngineLayout(wine: wine).isSealed)
        try record(sealed: true); XCTAssertTrue(EngineLayout(wine: wine).isSealed)
        let old = #"{"id":"ext-a","name":"A","release":"1","wineVersion":"11.20","installedAt":"2026-11-20T00:00:00Z","engine":"x","from":"y"}"#
        try Data(old.utf8).write(to: wine.appendingPathComponent("engine.json"))
        XCTAssertTrue(EngineLayout(wine: wine).isSealed, "records from before Intel imports were sealed ARM engines")
    }

    /// Sikarugir's Intel build of a Wine version sorts above an ARM one and above another project's.
    func testOrdering() {
        let ext = EngineVersion(major: 11, minor: 0, revision: 0, arch: .arm64, external: "ext-a")
        let sik = EngineVersion(major: 11, minor: 0, revision: 0)
        XCTAssertLessThan(ext, sik)
        XCTAssertLessThan(ext, EngineVersion(major: 11, minor: 0, revision: 0, arch: .arm64, external: "ext-b"))
        XCTAssertGreaterThan(EngineVersion(major: 11, minor: 20, revision: 0, arch: .arm64, external: "ext-a"), sik, "a newer Wine is newer")
    }

    func testSpecUsesTheRuntimeID() {
        let ext = EngineVersion(major: 11, minor: 20, revision: 0, arch: .arm64, external: "ext-x")
        XCTAssertEqual(WineSelection.spec(for: ext).id, "ext-x")
    }

    func testSlugAndBuiltInSource() throws {
        XCTAssertEqual(ExternalEngines.slug("metalsharp-v8.0"), "metalsharp-v8.0")
        XCTAssertEqual(ExternalEngines.slug("Owner/Some Repo"), "owner-some-repo")
        let ms = try XCTUnwrap(ExternalEngines.builtIn.first)
        let re = try Regex(ms.asset)
        XCTAssertNotNil("MetalSharp-Wine-8.0-arm64.zip".wholeMatch(of: re))
        XCTAssertNil("MetalSharp-Wine-8.0-x86_64.zip".wholeMatch(of: re))
    }

    /// System files a fresh environment of the engine has are traced to the engine's own files and added to an
    /// environment that lacks them, never replacing one it has.
    func testMissingSystemFilesComeFromTheEngine() throws {
        let fm = FileManager.default
        let id = "ext-sysfiles-\(UUID().uuidString.prefix(6).lowercased())"
        let runtime = RuntimeManager.folder(for: id)
        defer { try? fm.removeItem(at: runtime) }
        let wine = runtime.appendingPathComponent("Contents/SharedSupport/wine")
        try fm.createDirectory(at: wine.appendingPathComponent("lib/extra/i386-windows"), withIntermediateDirectories: true)
        try Data("gl32".utf8).write(to: wine.appendingPathComponent("lib/extra/i386-windows/bridge.dll"))
        let info = ExternalEngines.Info(id: id, name: "T", source: nil, release: "1", wineVersion: "11.0", installedAt: Date(),
                                        engine: "Contents/SharedSupport/wine", from: "x", license: nil, sealed: false, arch: .arm64)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(info).write(to: wine.appendingPathComponent("engine.json"))
        let fresh = fm.temporaryDirectory.appendingPathComponent("fresh-\(UUID().uuidString)")
        let game = fm.temporaryDirectory.appendingPathComponent("game-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fresh); try? fm.removeItem(at: game) }
        for p in [fresh, game] { try fm.createDirectory(at: p.appendingPathComponent("drive_c/windows/syswow64"), withIntermediateDirectories: true) }
        try Data("gl32".utf8).write(to: fresh.appendingPathComponent("drive_c/windows/syswow64/bridge.dll"))
        try Data("made at setup".utf8).write(to: fresh.appendingPathComponent("drive_c/windows/syswow64/generated.dll"))
        ExternalEngines.recordSystemFiles(id: id, freshPrefix: fresh)
        XCTAssertEqual(ExternalEngines.addMissingSystemFiles(id: id, prefix: game), 1, "only files traced to the engine")
        XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("drive_c/windows/syswow64/bridge.dll")), Data("gl32".utf8))
        XCTAssertEqual(ExternalEngines.addMissingSystemFiles(id: id, prefix: game), 0, "nothing replaced")
    }

    /// The engine is found inside an app (its Contents) or a folder, a few levels down.
    func testFindsTheEngineRoot() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ext-engine-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Engine X.app/Contents")
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("lib/wine/aarch64-unix"), withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent("bin/wine").path, contents: Data())
        XCTAssertEqual(ExternalEngines.findRoot(dir)?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(EngineLayout(wine: root).arch, .arm64)
        XCTAssertFalse(EngineLayout(wine: root).isSealed)
        fm.createFile(atPath: root.appendingPathComponent("engine.json").path, contents: Data("{}".utf8))
        XCTAssertTrue(EngineLayout(wine: root).isSealed)
    }
}
