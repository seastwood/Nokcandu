import XCTest
@testable import NokcanduCore
final class SteamControllerTransportTests: XCTestCase {
    func testOnlyOriginalVendorInterfacesAreAccepted() {
        XCTAssertEqual(SteamControllerTransport.identify(vendor:0x28de,product:0x1102,page:0xff00,usage:1,interface:2),.cable)
        for slot in 1...4 { XCTAssertEqual(SteamControllerTransport.identify(vendor:0x28de,product:0x1142,page:0xff00,usage:1,interface:slot),.receiver) }
        for (vendor,product,page,usage,slot) in [(0x28de,0x1142,1,6,0),(0x28de,0x1142,0xff00,1,0),(0x28de,0x1142,0xff00,1,5),(0x28de,0x1105,0xff00,1,2),(0x28de,0x1205,0xff00,1,2),(0x1234,0x1142,0xff00,1,1)] {
            XCTAssertNil(SteamControllerTransport.identify(vendor:vendor,product:product,page:page,usage:usage,interface:slot))
        }
    }
    func testRadioRetriesAreBoundedAndCableDoesNotRetry() {
        var attempts=0, pauses=0
        XCTAssertTrue(SteamControllerTransport.receiver.transfer(attempt:{attempts += 1;return attempts==4},pause:{pauses += 1}))
        XCTAssertEqual(attempts,4);XCTAssertEqual(pauses,3)
        attempts=0;pauses=0
        XCTAssertFalse(SteamControllerTransport.receiver.transfer(attempt:{attempts += 1;return false},pause:{pauses += 1}))
        XCTAssertEqual(attempts,50);XCTAssertEqual(pauses,49)
        attempts=0;pauses=0
        XCTAssertFalse(SteamControllerTransport.cable.transfer(attempt:{attempts += 1;return false},pause:{pauses += 1}))
        XCTAssertEqual(attempts,1);XCTAssertEqual(pauses,0)
    }
    func testWirelessEventsAndInputReset() {
        XCTAssertEqual(SteamControllerTransport.event([1,0,3,1,1]),.disconnected)
        XCTAssertEqual(SteamControllerTransport.event([1,0,3,1,2]),.connected)
        XCTAssertEqual(SteamControllerTransport.event([1,0,3,1,3]),.connected)
        for b:[UInt8] in [[1,0,3,1],[1,0,3,9,1],[1,0,3,1,9],[1,0,1,1,1],[0,1,3,1,1]] { XCTAssertNil(SteamControllerTransport.event(b)) }
        var packet=[UInt8](repeating:0,count:64);packet[0]=1;packet[2]=1;packet[3]=60;packet[4]=1;packet[8]=128
        var stream=SteamControllerStream()
        XCTAssertEqual(stream.accept(packet,at:1)?.buttons,[.a])
        stream.reset() // radio disconnect must clear the old sequence and held input
        XCTAssertNil(stream.state)
        packet[8]=0
        XCTAssertEqual(stream.accept(packet,at:2)?.buttons,[])
    }
    func testOutputCancellationDoesNotAffectNextSession() {
        let old=SteamControllerOutputGate(),next=SteamControllerOutputGate()
        XCTAssertTrue(old.isActive);old.cancel();old.cancel()
        XCTAssertFalse(old.isActive);XCTAssertTrue(next.isActive)
    }
}
