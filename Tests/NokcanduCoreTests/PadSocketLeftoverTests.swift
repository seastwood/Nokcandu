import XCTest
@testable import NokcanduCore

final class PadSocketLeftoverTests: XCTestCase {
    func testOnlyDeadHelpersOwnFilesAreChosen() {
        let names = ["nokcandu-pad-501-100.sock", "nokcandu-pad-501-100.sock.buttons", "nokcandu-pad-501-200.sock",
                     "nokcandu-pad-502-100.sock", "nokcandu-pad-501-abc.sock", "nokcandu-pad-501-100.sock.bak",
                     "nokcandu-pad-501-1.sock", "other-501-100.sock", "nokcandu-pad-501-100x.sock"]
        let stale = PadSocketLeftovers.stale(names, uid: 501) { $0 == 200 }
        XCTAssertEqual(stale, ["nokcandu-pad-501-100.sock", "nokcandu-pad-501-100.sock.buttons"])
        XCTAssertEqual(PadSocketLeftovers.stale(names, uid: 501) { _ in true }, [])
    }
}

/// November 14, 2026: the helper's sockets moved from /tmp itself into a folder only this user can enter.
final class PadSocketFolderTests: XCTestCase {
    func testOnlyARealPrivateFolderOfThisUserCounts() throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent("nok-sock-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let closed = base.appendingPathComponent("closed").path, open = base.appendingPathComponent("open").path, link = base.appendingPathComponent("link").path
        try fm.createDirectory(atPath: closed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(atPath: open, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try fm.createSymbolicLink(atPath: link, withDestinationPath: closed)
        XCTAssertTrue(PadSocketFolder.isPrivate(closed))
        XCTAssertFalse(PadSocketFolder.isPrivate(open), "others could enter")
        XCTAssertFalse(PadSocketFolder.isPrivate(link), "a link could point anywhere")
        XCTAssertFalse(PadSocketFolder.isPrivate(closed, uid: getuid() + 1), "someone else's")
        XCTAssertFalse(PadSocketFolder.isPrivate(base.appendingPathComponent("missing").path))
        XCTAssertEqual(PadSocketFolder.candidates("x.sock", folder: closed), [closed + "/x.sock", "/tmp/x.sock"])
        XCTAssertEqual(PadSocketFolder.candidates("x.sock", folder: open), ["/tmp/x.sock"])
        XCTAssertEqual(PadSocketFolder.path(uid: 501), "/tmp/nokcandu-501")
    }
}
