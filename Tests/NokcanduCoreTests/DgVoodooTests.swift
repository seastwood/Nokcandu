import XCTest
@testable import NokcanduCore

final class DgVoodooTests: XCTestCase {
    let sample = "[General]\r\n\r\nOutputAPI                            = bestavailable\r\nAdapters                             = all\r\n\r\n[Glide]\r\n\r\nVRAM                                = 4\r\n\r\n[DirectX]\r\n\r\nVideoCard                           = internal3D\r\nVRAM                                = 256\r\ndgVoodooWatermark                   = true\r\n"
    func testConfigurationSetsOnlyWhatTheFixNeeds() {
        let out = DgVoodoo.configuration(sample)
        XCTAssertTrue(out.contains("OutputAPI                            = d3d11_fl11_0\r\n"))
        XCTAssertTrue(out.contains("dgVoodooWatermark                    = false\r\n"))
        XCTAssertTrue(out.contains("VRAM                                 = 1024\r\n"))
        XCTAssertTrue(out.contains("VRAM                                = 4\r\n"), "Glide's own setting untouched")
        XCTAssertTrue(out.contains("VideoCard                            = geforce_9800_gt\r\n"), "a card older games know")
        XCTAssertEqual(out.components(separatedBy: "\n").count, sample.components(separatedBy: "\n").count)
    }
    func testOverridesAndFilesMatchTheProgramsArchitecture() {
        XCTAssertEqual(DgVoodoo.overrides(is64Bit: false), ["d3d8": "n", "d3d9": "n"])
        XCTAssertEqual(DgVoodoo.overrides(is64Bit: true), ["d3d9": "n"])
        XCTAssertEqual(DgVoodoo.libraries(is64Bit: false).map(\.name), ["d3d8.dll", "d3d9.dll"])
        XCTAssertEqual(DgVoodoo.libraries(is64Bit: true).map(\.entry), ["MS/x64/D3D9.dll"])
        XCTAssertTrue(DgVoodoo.outputs.contains(.dxmt)); XCTAssertFalse(DgVoodoo.outputs.contains(.classic3D))
        XCTAssertEqual(CompatibilityFix.dgVoodoo.id, "dgvoodoo-d3d11")
    }
    /// The real package, when it has been downloaded (it is not part of the repository).
    func testPinnedPackageHasEverythingTheFixUses() throws {
        let cached = NokPaths.downloads.appendingPathComponent(DgVoodoo.assetName)
        let scratch = ProcessInfo.processInfo.environment["DGVOODOO_ZIP"].map(URL.init(fileURLWithPath:))
        guard let zip = [cached, scratch].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("package not downloaded") }
        XCTAssertEqual(try Hashing.sha256(file: zip), DgVoodoo.sha256)
        let list = try Shell.run("/usr/bin/unzip", ["-l", zip.path], timeout: 30).combined
        for entry in ["MS/x86/D3D8.dll", "MS/x86/D3D9.dll", "MS/x64/D3D9.dll", "dgVoodoo.conf", "dgVoodooCpl.exe"] { XCTAssertTrue(list.contains(entry), entry) }
    }
}
