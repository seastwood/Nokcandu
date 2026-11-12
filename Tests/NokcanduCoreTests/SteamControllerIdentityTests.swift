import XCTest
@testable import NokcanduCore
final class SteamControllerIdentityTests: XCTestCase {
    func reply(_ serial:String)->[UInt8] {
        var b=[UInt8](repeating:0,count:64);b[0]=0xae;b[1]=21;b[2]=1
        for (i,c) in serial.utf8.prefix(20).enumerated(){b[3+i]=c};return b
    }
    func testIdentityIsBoundedAndOnlyDigestIsRetained() throws {
        let bytes=reply("TEST123456")
        let id=try XCTUnwrap(SteamControllerIdentity.fingerprint(bytes))
        XCTAssertEqual(id.count,64)
        XCTAssertEqual(SteamControllerIdentity.fingerprint(bytes),id)
        XCTAssertNotEqual(SteamControllerIdentity.fingerprint(reply("OTHER12345")),id)
        XCTAssertNil(SteamControllerIdentity.fingerprint(Array(bytes.prefix(8))))
        XCTAssertNil(SteamControllerIdentity.fingerprint(reply("XXXXXXXXXX")))
        XCTAssertNil(SteamControllerIdentity.fingerprint(reply("0000000000")))
        XCTAssertNil(SteamControllerIdentity.fingerprint([0xae,0,0]))
        var wrong=bytes;wrong[2]=2;XCTAssertNil(SteamControllerIdentity.fingerprint(wrong))
    }
    func testRecoveryAcrossReceiverSessionsRequiresSameRemoteAndSameMode() throws {
        let original:SteamControllerMode.Settings=[7:3,8:0,9:1,48:0,49:2]
        let id=try XCTUnwrap(SteamControllerIdentity.fingerprint(reply("TEST123456")))
        let other=try XCTUnwrap(SteamControllerIdentity.fingerprint(reply("OTHER12345")))
        let receipt=try XCTUnwrap(SteamControllerIdentity.Recovery(fingerprint:id,original:original))
        let decoded=try JSONDecoder().decode(SteamControllerIdentity.Recovery.self,from:JSONEncoder().encode(receipt))
        XCTAssertEqual(decoded.recoveredOriginal(identity:id,current:receipt.applied),original)
        XCTAssertNil(decoded.recoveredOriginal(identity:other,current:receipt.applied))
        var changed=receipt.applied;changed[9]=1
        XCTAssertNil(decoded.recoveredOriginal(identity:id,current:changed))
        let json=String(decoding:try JSONEncoder().encode(receipt),as:UTF8.self)
        XCTAssertFalse(json.contains("TEST123456"))
    }
}
