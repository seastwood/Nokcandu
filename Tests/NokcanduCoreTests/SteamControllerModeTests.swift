import XCTest
@testable import NokcanduCore
final class SteamControllerModeTests: XCTestCase {
    let original: SteamControllerMode.Settings = [7:3,8:0,9:1,48:4,49:2]
    func testWireFormatAndModePreservePacketVersionAndExistingIMUBits() throws {
        let captured = try XCTUnwrap(SteamControllerMode.captured(original))
        XCTAssertEqual(captured, [7:7,8:7,9:0,48:28,49:2])
        var response = try XCTUnwrap(SteamControllerMode.write(original)); response[0] = 0x89
        XCTAssertEqual(SteamControllerMode.decode(response), original)
        XCTAssertEqual(Array(SteamControllerMode.query.prefix(5)), [0x89,15,7,0,0])
        XCTAssertEqual(SteamControllerMode.write(captured)?.first, 0x87)
        XCTAssertNil(SteamControllerMode.write([48:24]))
    }
    func testBuiltInButtonActionsAreClearedAndReturnedWithValveCommands() {
        // Trigger clicks and button keys are digital mappings, not settings: 0x81 clears, 0x85 restores defaults.
        XCTAssertEqual(SteamControllerMode.clearDigitalMappings, [0x81] + [UInt8](repeating: 0, count: 63))
        XCTAssertEqual(SteamControllerMode.defaultDigitalMappings, [0x85] + [UInt8](repeating: 0, count: 63))
        XCTAssertFalse(SteamControllerMode.tags.contains(0x81))
    }
    func testTruncatedRepeatedUnknownAndUnexpectedRepliesAreRejected() throws {
        var response = try XCTUnwrap(SteamControllerMode.write(original)); response[0] = 0x89
        XCTAssertNil(SteamControllerMode.decode(Array(response.prefix(16))))
        response[5] = 7
        XCTAssertNil(SteamControllerMode.decode(response))
        response[5] = 255
        XCTAssertNil(SteamControllerMode.decode(response))
        response[0] = 0x83
        XCTAssertNil(SteamControllerMode.decode(response))
    }
    func testRecoveryCannotRestoreAnotherControllerOrOverwriteSteamChanges() throws {
        let lease = try XCTUnwrap(SteamControllerMode.Lease(device: 42, original: original))
        XCTAssertTrue(lease.canRestore(device: 42, current: lease.applied))
        XCTAssertFalse(lease.canRestore(device: 99, current: lease.applied))
        XCTAssertFalse(lease.canRestore(device: 42, current: original))
        var changed = lease.applied; changed[48] = 0
        XCTAssertFalse(lease.canRestore(device: 42, current: changed))
        XCTAssertEqual(try JSONDecoder().decode(SteamControllerMode.Lease.self, from: JSONEncoder().encode(lease)), lease)
    }
}
