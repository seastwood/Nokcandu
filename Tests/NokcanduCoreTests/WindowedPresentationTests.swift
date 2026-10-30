import XCTest
@testable import NokcanduCore

final class WindowedPresentationTests: XCTestCase {
    func prefix(_ user: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nok-wp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try user.write(to: d.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        return d
    }
    func user(_ p: URL) throws -> String { try String(contentsOf: p.appendingPathComponent("user.reg"), encoding: .utf8) }

    func testAddsToExistingSectionAndRemoves() throws {
        let p = try prefix("WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\Mac Driver] 2\n#time=1\n\"AllowSetGamma\"=dword:00000000\n")
        try WindowedPresentation.setMacDriver(["WindowedFullscreen": "y", "WindowedResolution": "1280x720"], prefix: p)
        var u = try user(p)
        XCTAssertTrue(u.contains("#time=1\n\"WindowedFullscreen\"=\"y\"\n\"WindowedResolution\"=\"1280x720\"\n\"AllowSetGamma\""), u)
        XCTAssertTrue(WindowedPresentation.registryOn(prefix: p))
        // Changing the resolution replaces, never duplicates.
        try WindowedPresentation.setMacDriver(["WindowedFullscreen": "y", "WindowedResolution": "800x600"], prefix: p)
        u = try user(p)
        XCTAssertEqual(u.components(separatedBy: "WindowedResolution").count, 2, u)
        XCTAssertTrue(u.contains("\"WindowedResolution\"=\"800x600\""))
        try WindowedPresentation.setMacDriver(["WindowedFullscreen": nil, "WindowedResolution": nil], prefix: p)
        u = try user(p)
        XCTAssertFalse(u.contains("Windowed"), u)
        XCTAssertTrue(u.contains("\"AllowSetGamma\"=dword:00000000"))
        XCTAssertFalse(WindowedPresentation.registryOn(prefix: p))
    }

    func testCreatesSection() throws {
        let p = try prefix("WINE REGISTRY Version 2\n")
        try WindowedPresentation.setMacDriver(["WindowedFullscreen": "y"], prefix: p)
        XCTAssertTrue(try user(p).hasSuffix("\n[Software\\\\Wine\\\\Mac Driver] 0\n\"WindowedFullscreen\"=\"y\"\n"))
    }

    func testEngineStateRecognisesStockAndForeignDrivers() throws {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("nok-wp-host-\(UUID().uuidString)")
        let lib = WindowedPresentation.lib(h)
        XCTAssertEqual(WindowedPresentation.engineState(host: h), .missing)
        for f in WindowedPresentation.files {
            let u = lib.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("something else".utf8).write(to: u)
        }
        XCTAssertEqual(WindowedPresentation.engineState(host: h), .unsupported)
        // An older build of Nokcandu's own driver is recognised (to be updated), not refused.
        try Data("abc%s/.nokcandu-virtual-display\0xyz".utf8).write(to: lib.appendingPathComponent(WindowedPresentation.files[0]))
        XCTAssertEqual(WindowedPresentation.engineState(host: h), .outdated)
    }

    func testBuiltDriverCarriesItsMarker() throws {
        let so = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/winemac-10.0/x86_64-unix/winemac.so")
        guard FileManager.default.fileExists(atPath: so.path) else { throw XCTSkip("driver not built here") }
        XCTAssertTrue(WindowedPresentation.isOurs(so))
        // Vulkan surfaces (DXVK, MoltenVK) must be built in: the stock driver has them.
        let d = try Data(contentsOf: so)
        XCTAssertNil(d.range(of: Data("built without Vulkan".utf8)), "driver was built without Vulkan support")
        XCTAssertNotNil(d.range(of: Data("macdrv_vulkan_surface_create".utf8)))
    }

    func testDriverGoesOnlyIntoEnginesOfItsWineVersion() throws {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("nok-wp-ver-\(UUID().uuidString)")
        let lib = WindowedPresentation.lib(h)
        for f in WindowedPresentation.files {
            let u = lib.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("a newer Sikarugir revision's own driver".utf8).write(to: u)
        }
        WindowedPresentation.driversForTesting = ["10.0": h]
        defer { WindowedPresentation.driversForTesting = nil }
        let version = h.appendingPathComponent("SharedSupport/wine/version")
        // Another revision of Wine 10.0: its own driver can be swapped for Nokcandu's.
        try "wine sikarugir 10.0 (revision 9)".write(to: version, atomically: true, encoding: .utf8)
        XCTAssertEqual(WindowedPresentation.engineState(host: h), .stock)
        XCTAssertTrue(WindowedPresentation.supports(EngineVersion(major: 10, minor: 0, revision: 12)))
        // A newer Wine: not until Nokcandu has a driver built for it.
        try "wine sikarugir 11.0".write(to: version, atomically: true, encoding: .utf8)
        XCTAssertEqual(WindowedPresentation.engineState(host: h), .unsupported)
        XCTAssertFalse(WindowedPresentation.supports(EngineVersion(major: 11, minor: 0, revision: 0)))
        XCTAssertEqual(WindowedPresentation.supportedWine, ["10.0"])
    }
}
