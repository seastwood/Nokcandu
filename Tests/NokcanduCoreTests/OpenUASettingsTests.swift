import XCTest
@testable import NokcanduCore

final class OpenUASettingsTests: XCTestCase {
    func pe() -> Data {
        var d = Data(repeating: 0, count: 1024)
        func put(_ value: UInt32, _ offset: Int) { for i in 0..<4 { d[offset+i] = UInt8((value >> (i*8)) & 255) } }
        d[0] = 0x4d; d[1] = 0x5a; put(0x80, 0x3c); put(0x4550, 0x80)
        d[0x86] = 1; d[0x94] = 0xe0; d[0x98] = 0x0b; d[0x99] = 1
        put(16, 0xf4); put(0x1000, 0x100)
        put(512, 0x180); put(0x1000, 0x184); put(512, 0x188); put(512, 0x18c)
        put(0x1030, 524)
        d.replaceSubrange(560..<573, with: Data("opengl32.dll\0".utf8))
        return d
    }
    func fixture() throws -> InstalledGame {
        var g = try ProfileCompletenessTests().fixture()
        var c = try XCTUnwrap(g.custom); c.exe = #"C:\Games\BF1942\UA_source.exe"#; c.graphics = .compatible
        try c.encoded().write(to: CustomGameConfig.url(in: g.contents)); g.custom = c
        let folder = try XCTUnwrap(CompatibilityFixes.program(g)).deletingLastPathComponent()
        try pe().write(to: folder.appendingPathComponent("UA_source.exe"))
        try NokPaths.ensure(folder.appendingPathComponent("DATA")); try NokPaths.ensure(folder.appendingPathComponent("LEVELS"))
        try Data().write(to: folder.appendingPathComponent("DATA/world.ini"))
        try Data("; keep this\r\ngfx.vbo = on ; comment\r\nmenu.windowed = on\r\ngfx.custommodes = 1920x1080\r\naudio.volume = 73\r\n".utf8).write(to: folder.appendingPathComponent("NUCLEUS.INI"))
        return g
    }
    func testExternalProgramAcceptedButEscapingExecutableRejected() throws {
        let fm = FileManager.default, g = try fixture()
        let external = fm.temporaryDirectory.appendingPathComponent("openua-external-" + UUID().uuidString)
        defer { try? fm.removeItem(at: g.appURL); try? fm.removeItem(at: external) }
        try NokPaths.ensure(external)
        try GameMover.moveFiles(g, to: external)
        XCTAssertTrue(OpenUASettings.supports(g))
        XCTAssertNil(CompatibilityFixes.unavailable(.borderless, for: g))
        XCTAssertNil(CompatibilityFixes.unavailable(.openUA, for: g))
        let exe = try XCTUnwrap(CompatibilityFixes.program(g)), outside = external.appendingPathComponent("other.exe")
        try pe().write(to: outside); try fm.removeItem(at: exe)
        try fm.createSymbolicLink(atPath: exe.path, withDestinationPath: outside.path)
        XCTAssertFalse(OpenUASettings.supports(g))
        XCTAssertNotNil(CompatibilityFixes.unavailable(.borderless, for: g))
    }
    func testRecipeIsIdempotentShareableAndUndoable() async throws {
        let fm = FileManager.default, g = try fixture()
        defer { try? fm.removeItem(at: g.appURL) }
        let ini = try XCTUnwrap(OpenUASettings.ini(g)), original = try Data(contentsOf: ini)
        XCTAssertTrue(OpenUASettings.supports(g)); XCTAssertFalse(OpenUASettings.isConfigured(g))
        try await CompatibilityFixes.install(.openUA, for: g) { _ in }
        XCTAssertTrue(OpenUASettings.isConfigured(g))
        let text = try String(contentsOf: ini, encoding: .isoLatin1)
        XCTAssertTrue(text.contains("audio.volume = 73\r\n")); XCTAssertTrue(text.contains("1920x1080")); XCTAssertTrue(text.contains("; comment"))
        XCTAssertEqual(OpenUASettings.configuredText(text), text)
        let profile = Profiles.make(from: CompatibilityFixes.fresh(g), rating: .playable, notes: nil, install: nil)
        XCTAssertTrue(profile.fixes?.contains("openua-display") == true)
        XCTAssertEqual(profile.problems, [])
        try CompatibilityFixes.undo(.openUA, for: g) { _ in }
        XCTAssertEqual(try Data(contentsOf: ini), original)
        XCTAssertFalse(CompatibilityFixes.isInstalled(.openUA, for: g))
    }
    func testManualSettingsAreSharedAndIniCannotEscapeGameFolder() throws {
        let fm = FileManager.default, g = try fixture()
        let outside = fm.temporaryDirectory.appendingPathComponent("openua-outside-" + UUID().uuidString)
        defer { try? fm.removeItem(at: g.appURL); try? fm.removeItem(at: outside) }
        let ini = try XCTUnwrap(OpenUASettings.ini(g)), data = try XCTUnwrap(OpenUASettings.plannedFiles(for: g)[ini])
        try data.write(to: ini)
        XCTAssertFalse(CompatibilityFixes.isInstalled(.openUA, for: g))
        let profile = Profiles.make(from: g, rating: .playable, notes: nil, install: nil)
        XCTAssertTrue(profile.fixes?.contains("openua-display") == true)
        try data.write(to: outside); try fm.removeItem(at: ini)
        try fm.createSymbolicLink(atPath: ini.path, withDestinationPath: outside.path)
        XCTAssertFalse(OpenUASettings.supports(g))
        XCTAssertThrowsError(try OpenUASettings.plannedFiles(for: g))
        XCTAssertEqual(try Data(contentsOf: outside), data)
    }
    func testWrongGameAndChangedIniAreProtected() async throws {
        let fm = FileManager.default, g = try fixture()
        defer { try? fm.removeItem(at: g.appURL) }
        var other = g; other.custom?.exe = #"C:\Games\BF1942\BF1942.exe"#
        XCTAssertFalse(OpenUASettings.supports(other))
        try await CompatibilityFixes.install(.openUA, for: g) { _ in }
        let ini = try XCTUnwrap(OpenUASettings.ini(g)), changed = Data("user changed this".utf8)
        try changed.write(to: ini)
        XCTAssertThrowsError(try CompatibilityFixes.undo(.openUA, for: g) { _ in })
        XCTAssertEqual(try Data(contentsOf: ini), changed)
        var profile = GameProfile(title: "Wrong game", match: .init(exeName: "Other.exe"), source: "folder", rating: .playable)
        profile.fixes = ["openua-display"]
        XCTAssertFalse(profile.problems.isEmpty)
    }
}
