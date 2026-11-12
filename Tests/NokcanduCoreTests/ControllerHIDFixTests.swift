import XCTest
@testable import NokcanduCore

final class ControllerHIDFixTests: XCTestCase {
    let idle = ProcessSnapshot(rows: [], reliable: true)
    func fixture() throws -> (URL, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nok-hid-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let c = root.appendingPathComponent("Game.app/Contents"), b = root.appendingPathComponent("bundle")
        try NokPaths.ensure(ControllerHIDFix.target(c).deletingLastPathComponent()); try NokPaths.ensure(b)
        try Data("original module".utf8).write(to: ControllerHIDFix.target(c))
        try Data("wine sikarugir 11.0 (revision 1)".utf8).write(to: c.appendingPathComponent("SharedSupport/wine/version"))
        let original = try XCTUnwrap(ControllerHIDFix.hash(ControllerHIDFix.target(c)))
        try source(b, original: original, text: "corrected module")
        return (c,b,original)
    }
    func source(_ b: URL, original: String, text: String) throws {
        try Data(text.utf8).write(to: b.appendingPathComponent("winebus.so"))
        let m = ControllerHIDFix.Manifest(version: "11.0", sourceSHA256: try XCTUnwrap(ControllerHIDFix.hash(b.appendingPathComponent("winebus.so"))), stockSHA256: [original])
        try JSONEncoder().encode(m).write(to: b.appendingPathComponent("manifest.json"))
    }
    func testMigrationAndUpdateKeepFirstOriginalAndUndoIsSticky() throws {
        let (c,b,original) = try fixture()
        XCTAssertTrue(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in }))
        XCTAssertEqual(ControllerHIDFix.state(contents: c, bundle: b), .installed)
        XCTAssertFalse(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in XCTFail("idempotent update signed") }))
        try source(b, original: original, text: "newer corrected module")
        XCTAssertTrue(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in }))
        XCTAssertEqual(ControllerHIDFix.hash(ControllerHIDFix.backup(c,original)), original)
        try ControllerHIDFix.setEnabled(false, contents: c, bundle: b, snapshot: idle, sign: { _ in })
        XCTAssertEqual(ControllerHIDFix.hash(ControllerHIDFix.target(c)), original)
        XCTAssertEqual(ControllerHIDFix.state(contents: c, bundle: b), .disabled)
        XCTAssertFalse(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in XCTFail("opt-out ignored") }))
        try ControllerHIDFix.setEnabled(true, contents: c, bundle: b, snapshot: idle, sign: { _ in })
        XCTAssertEqual(ControllerHIDFix.state(contents: c, bundle: b), .installed)
    }
    func testUnknownProcessesAndUnsupportedVersionLeaveEngineUntouched() throws {
        let (c,b,original) = try fixture()
        XCTAssertFalse(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: ProcessSnapshot(rows: [], reliable: false), sign: { _ in XCTFail() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ControllerHIDFix.folder(c).path))
        try Data("wine sikarugir 11.1".utf8).write(to: c.appendingPathComponent("SharedSupport/wine/version"))
        XCTAssertFalse(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in XCTFail() }))
        XCTAssertEqual(ControllerHIDFix.hash(ControllerHIDFix.target(c)), original)
    }
    func testManualModuleAndCorruptBundleOrBackupArePreserved() throws {
        let (c,b,original) = try fixture()
        try Data("manual module".utf8).write(to: ControllerHIDFix.target(c))
        XCTAssertThrowsError(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in XCTFail() }))
        XCTAssertEqual(try String(contentsOf: ControllerHIDFix.target(c)), "manual module")
        try Data("original module".utf8).write(to: ControllerHIDFix.target(c))
        try Data("corrupt source".utf8).write(to: b.appendingPathComponent("winebus.so"))
        XCTAssertThrowsError(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in XCTFail() }))
        try source(b, original: original, text: "corrected module")
        try NokPaths.ensure(ControllerHIDFix.backup(c,original).deletingLastPathComponent())
        try Data("manual backup".utf8).write(to: ControllerHIDFix.backup(c,original))
        XCTAssertThrowsError(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in XCTFail() }))
        XCTAssertEqual(ControllerHIDFix.hash(ControllerHIDFix.target(c)), original)
        XCTAssertEqual(try String(contentsOf: ControllerHIDFix.backup(c,original)), "manual backup")
    }
    func testSigningFailureAndLinkedModuleDoNotReplaceOriginal() throws {
        let (c,b,original) = try fixture()
        XCTAssertThrowsError(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in throw NokError("sign failed") }))
        XCTAssertEqual(ControllerHIDFix.hash(ControllerHIDFix.target(c)), original)
        let other = c.deletingLastPathComponent().appendingPathComponent("manual-module")
        try FileManager.default.moveItem(at: ControllerHIDFix.target(c), to: other)
        try FileManager.default.createSymbolicLink(at: ControllerHIDFix.target(c), withDestinationURL: other)
        XCTAssertThrowsError(try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in XCTFail() }))
        XCTAssertEqual(ControllerHIDFix.hash(other), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: ControllerHIDFix.target(c).path), other.path)
    }
    func testUndoRefusesModifiedInstalledDriver() throws {
        let (c,b,_) = try fixture()
        try ControllerHIDFix.install(contents: c, bundle: b, snapshot: idle, sign: { _ in })
        try Data("manual after update".utf8).write(to: ControllerHIDFix.target(c))
        XCTAssertThrowsError(try ControllerHIDFix.setEnabled(false, contents: c, bundle: b, snapshot: idle, sign: { _ in }))
        XCTAssertEqual(try String(contentsOf: ControllerHIDFix.target(c)), "manual after update")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ControllerHIDFix.disabled(c).path))
    }
}
