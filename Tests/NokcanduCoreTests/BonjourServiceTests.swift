import XCTest
@testable import NokcanduCore

final class BonjourServiceTests: XCTestCase {
    func testPointsGameServiceAtStandIn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonjour-\(UUID().uuidString)")
        let prefix = dir.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("stub.exe")
        try Data("MZ".utf8).write(to: stub)
        let reg = #"""
        WINE REGISTRY Version 2

        [System\\ControlSet001\\Services\\Bonjour Service] 1793335414
        #time=1dd682938c3ae58
        "DisplayName"="Bonjour Service"
        "ImagePath"="C:\\Program Files\\Blizzard\\Bonjour Service\\mDNSResponder.exe"
        "Start"=dword:00000002
        "WOW64"=dword:00000001

        [System\\ControlSet001\\Services\\Eventlog] 1792891535
        "WOW64"=dword:00000001
        """#
        try Data(reg.utf8).write(to: prefix.appendingPathComponent("system.reg"))

        XCTAssertTrue(try BonjourService.fix(prefix: prefix, stub: stub))
        let out = try String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)
        XCTAssertTrue(out.contains(#""ImagePath"="C:\\windows\\system32\\nokcandu-bonjour-service.exe""#))
        XCTAssertFalse(out.contains("mDNSResponder.exe\""))
        XCTAssertEqual(out.components(separatedBy: #""WOW64"="#).count, 2)     // the other service's stays
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/nokcandu-bonjour-service.exe").path))
        XCTAssertFalse(try BonjourService.fix(prefix: prefix, stub: stub))      // nothing left to do
    }

    func testNoServiceNoChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bonjour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("stub.exe")
        try Data("MZ".utf8).write(to: stub)
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: dir.appendingPathComponent("system.reg"))
        XCTAssertFalse(try BonjourService.fix(prefix: dir, stub: stub))
    }
}
