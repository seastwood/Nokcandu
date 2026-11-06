import XCTest
@testable import NokcanduCore

final class EngineLayoutTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-layout-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func makeEngine(_ name: String, folders: [String], files: [String] = []) throws -> URL {
        let contents = root.appendingPathComponent("\(name).app/Contents")
        let lib = contents.appendingPathComponent("SharedSupport/wine/lib/wine")
        for f in folders { try FileManager.default.createDirectory(at: lib.appendingPathComponent(f), withIntermediateDirectories: true) }
        for f in files { try Data().write(to: lib.appendingPathComponent(f)) }
        return contents
    }

    func testIntelLayoutIsTodaysEngine() throws {
        let c = try makeEngine("Intel", folders: ["x86_64-unix", "x86_64-windows", "i386-windows"])
        let l = EngineLayout(contents: c)
        XCTAssertEqual(l.arch, .x86_64)
        XCTAssertTrue(l.needsRosetta)
        XCTAssertTrue(l.loader.path.hasSuffix("lib/wine/x86_64-unix/wine"))
        XCTAssertEqual(l.relative("x86_64-unix/winemac.so"), "x86_64-unix/winemac.so")
        XCTAssertTrue(l.runs32BitX86 && l.runs64BitX86)
    }

    func testARMLayoutNeedsEmulatorsForIntelPrograms() throws {
        let bare = EngineLayout(contents: try makeEngine("ARM", folders: ["aarch64-unix", "aarch64-windows", "i386-windows"]))
        XCTAssertEqual(bare.arch, .arm64)
        XCTAssertFalse(bare.needsRosetta)
        XCTAssertTrue(bare.loader.path.hasSuffix("lib/wine/aarch64-unix/wine"))
        XCTAssertTrue(bare.unixLibrary("winecoreaudio.so").path.hasSuffix("aarch64-unix/winecoreaudio.so"))
        XCTAssertEqual(bare.relative("x86_64-unix/winemac.so"), "aarch64-unix/winemac.so")
        XCTAssertEqual(bare.relative("x86_64-windows/ws2_32.dll"), "aarch64-windows/ws2_32.dll")
        XCTAssertFalse(bare.runs32BitX86, "no 32-bit emulator")
        XCTAssertFalse(bare.runs64BitX86, "no ARM64EC emulator")

        let fex = EngineLayout(contents: try makeEngine("FEX", folders: ["aarch64-unix", "aarch64-windows", "i386-windows"],
                                                        files: ["aarch64-windows/libwow64fex.dll", "aarch64-windows/libarm64ecfex.dll"]))
        XCTAssertTrue(fex.runs32BitX86 && fex.runs64BitX86)
        let noI386 = EngineLayout(contents: try makeEngine("NoI386", folders: ["aarch64-unix", "aarch64-windows"],
                                                           files: ["aarch64-windows/libwow64fex.dll"]))
        XCTAssertFalse(noI386.runs32BitX86, "32-bit Windows libraries are needed as well")
    }

    func testBothLoadersBelongToTheEnvironment() {
        let support = "/Games/X.app/Contents/SharedSupport"
        XCTAssertTrue(WineTools.owns(executable: support + "/wine/lib/wine/x86_64-unix/wine", support: support))
        XCTAssertTrue(WineTools.owns(executable: support + "/wine/lib/wine/aarch64-unix/wine", support: support))
        XCTAssertFalse(WineTools.owns(executable: support + "/wine/lib/wine/aarch64-unix/winemac.so", support: support))
    }

    func testARMEngineReleasesAreRecognizedButNeverAutomatic() {
        let arm = EngineVersion(assetName: "WS12WineSikarugir11.0_2_arm64.tar.xz")
        XCTAssertEqual(arm, EngineVersion(major: 11, minor: 0, revision: 2, arch: .arm64))
        XCTAssertEqual(EngineVersion(assetName: "WS12WineSikarugir11.0-aarch64.tar.xz")?.isARM, true)
        XCTAssertEqual(arm?.tag, "11.0_2_arm64")
        XCTAssertEqual(WineSelection.parse("11.0_2_arm64"), arm, "the saved choice round-trips")
        XCTAssertEqual(EngineVersion(major: 11, minor: 0, revision: 2, arch: .x86_64), EngineVersion(major: 11, minor: 0, revision: 2))
        XCTAssertTrue(arm! < EngineVersion(major: 11, minor: 0, revision: 2), "Intel sorts above ARM at the same version")

        func asset(_ n: String) -> ReleaseAsset { ReleaseAsset(name: n, size: 1, url: URL(string: "https://example.com/\(n)")!, sha256: "x", updated: nil) }
        let cat = UpdateCatalog(checkedAt: Date(), engines: [asset("WS12WineSikarugir11.0_1.tar.xz"), asset("WS12WineSikarugir11.1_arm64.tar.xz")],
                                templates: [], lav: nil, nativeEngines: [])
        XCTAssertEqual(cat.latestEngine?.version, EngineVersion(major: 11, minor: 0, revision: 1))
        XCTAssertEqual(cat.armEngines, [EngineVersion(major: 11, minor: 1, revision: 0, arch: .arm64)])
    }

    func testOldSavedVersionsDecodeAsIntel() throws {
        let v = try JSONDecoder().decode(EngineVersion.self, from: Data(#"{"major":11,"minor":0,"revision":1}"#.utf8))
        XCTAssertFalse(v.isARM)
        XCTAssertEqual(v, EngineVersion(major: 11, minor: 0, revision: 1))
    }
}
