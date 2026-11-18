import XCTest
import Network
@testable import NokcanduCore

final class DSUProtocolTests:XCTestCase {
    func request(_ type:UInt32,_ body:[UInt8] = []) -> Data { DSUProtocol.frame(type:type,body:body,id:42,client:true) }
    func testCRCMatchesStandardKnownVector() {
        XCTAssertEqual(DSUProtocol.crc32(Array("123456789".utf8)),0xcbf43926)
        XCTAssertEqual(DSUProtocol.read([1,2],at:Int.max,count:2),0)
        XCTAssertEqual(DSUProtocol.read([1,2],at:0,count:-1),0)
    }
    func testRequestsValidateLengthsCountsFlagsVersionsAndCRC() {
        XCTAssertEqual(DSUProtocol.request(request(0x100000)),.version)
        XCTAssertEqual(DSUProtocol.request(request(0x100001,[2,0,0,0,0,3])),.ports([0,3]))
        XCTAssertEqual(DSUProtocol.request(request(0x100002,[1,2,0,0,0,0,0,0])),.subscribe(flags:1,slot:2,mac:[0,0,0,0,0,0]))
        for bad in [request(0x100001,[5,0,0,0,0,1,2,3,4]),request(0x100001,[1,0,0,0,4]),request(0x100002,[8,0,0,0,0,0,0,0]),request(0x100002,[1,4,0,0,0,0,0,0]),request(0x999999)] {
            XCTAssertNil(DSUProtocol.request(bad))
        }
        var corrupt = request(0x100000);corrupt[12] ^= 1;XCTAssertNil(DSUProtocol.request(corrupt))
        var newer = request(0x100000);newer[4] = 0xff;XCTAssertNil(DSUProtocol.request(newer))
        for length in 0..<20 { XCTAssertNil(DSUProtocol.request(Data(repeating:0,count:length))) }
        XCTAssertNil(DSUProtocol.request(Data(request(0x100002,[1,0,0,0,0,0,0,0]).dropLast())))
    }
    func testVersionReplyMatchesIndependentPythonStructAndZlibFixture() {
        let packet = DSUProtocol.frame(type:0x100000,body:[0xe9,3,0,0],id:0x01020304)
        // This fixture is filled from Python struct.pack + zlib.crc32, independently of this encoder.
        XCTAssertEqual(packet.map { String(format:"%02x",$0) }.joined(),"44535553e90308002315ae590403020100001000e9030000")
    }
    func testMotionFrameOffsetsUnitsNeutralControlsAndCRC() throws {
        let data = try XCTUnwrap(DSUProtocol.motion(slot:2,mac:[2,3,4,5,6,7],counter:123,micros:1_234_567,gyro:[.pi,0,-.pi],acceleration:[0,1,-0.5],id:42))
        var bytes = Array(data)
        XCTAssertEqual(bytes.count,100);XCTAssertEqual(DSUProtocol.read(bytes,at:6,count:2),84)
        XCTAssertEqual(bytes[20],2);XCTAssertEqual(Array(bytes[40..<44]),[128,128,128,128])
        XCTAssertEqual(DSUProtocol.read(bytes,at:32,count:4),123)
        XCTAssertEqual(DSUProtocol.read(bytes,at:68,count:8),1_234_567)
        func float(_ at:Int) -> Float { Float(bitPattern:UInt32(DSUProtocol.read(bytes,at:at,count:4))) }
        XCTAssertEqual(float(80),1);XCTAssertEqual(float(84),-0.5)
        XCTAssertEqual(float(88),180,accuracy:0.001);XCTAssertEqual(float(96),-180,accuracy:0.001)
        let crc = DSUProtocol.read(bytes,at:8,count:4);for i in 8..<12 { bytes[i] = 0 }
        XCTAssertEqual(UInt64(DSUProtocol.crc32(bytes)),crc)
        XCTAssertNil(DSUProtocol.motion(slot:0,mac:[],counter:0,micros:0,gyro:[.nan,0,0],acceleration:[0,0,0],id:42))
        XCTAssertNil(DSUProtocol.motion(slot:0,mac:[],counter:0,micros:0,gyro:[0],acceleration:[0,0,0],id:42))
    }
    func testSlotsBoundedStableStaleAndReconnectCounter() throws {
        var state = DSUMotionState()
        for n in 0..<4 { XCTAssertEqual(state.publish(id:"pad-\(n)",gyro:[0,0,0],acceleration:[0,1,0],now:1),n) }
        XCTAssertNil(state.publish(id:"extra",gyro:[0,0,0],acceleration:[0,1,0],now:1.1))
        XCTAssertEqual(state.publish(id:"pad-2",gyro:[1,0,0],acceleration:[0,1,0],now:1.2),2)
        XCTAssertEqual(state.sources[2]?.counter,2);XCTAssertTrue(state.connected(2,now:1.3))
        XCTAssertFalse(state.connected(2,now:3))
        XCTAssertEqual(state.publish(id:"extra",gyro:[0,0,0],acceleration:[0,1,0],now:4),0)
        XCTAssertEqual(state.sources.count,4)
        XCTAssertNil(state.publish(id:"extra",gyro:[0,0,0],acceleration:[0,1,0],now:3.9))
        XCTAssertNil(state.publish(id:"invalid",gyro:[.infinity,0,0],acceleration:[0,1,0],now:4))
    }
    func testSubscriptionsExpireAndFilterSlotsAndMACs() throws {
        var state = DSUMotionState();_ = state.publish(id:"pad",gyro:[0,0,0],acceleration:[0,1,0],now:1)
        let source = try XCTUnwrap(state.sources[0])
        let all = DSUMotionState.Subscription(flags:0,slot:0,mac:[],until:6)
        XCTAssertTrue(all.includes(slot:0,source:source,now:5.99));XCTAssertFalse(all.includes(slot:0,source:source,now:6))
        let slot = DSUMotionState.Subscription(flags:1,slot:2,mac:[],until:6)
        XCTAssertFalse(slot.includes(slot:0,source:source,now:2));XCTAssertTrue(slot.includes(slot:2,source:source,now:2))
        let mac = DSUMotionState.Subscription(flags:2,slot:3,mac:source.mac,until:6)
        XCTAssertTrue(mac.includes(slot:0,source:source,now:2))
    }
    func testDisconnectedPortInfoKeepsRequestedSlot() {
        let packet = Array(DSUProtocol.info(slot:3,connected:false,mac:[],id:42))
        XCTAssertEqual(packet.count,32);XCTAssertEqual(packet[20],3);XCTAssertEqual(packet[21],0)
    }
    func testOptionalLocalUDPVersionRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["NOKCANDU_DSU_E2E"] == "1" else { throw XCTSkip("Set NOKCANDU_DSU_E2E=1 for a local UDP transport check") }
        final class StatusBox:@unchecked Sendable {
            let lock = NSLock();var value = ""
            func store(_ text:String) -> Bool { lock.lock();defer { lock.unlock() };guard value.isEmpty else { return false };value = text;return true }
            func load() -> String { lock.lock();defer { lock.unlock() };return value }
        }
        let status = StatusBox()
        let port = UInt16.random(in:50000...60000),ready = expectation(description:"DSU ready"),reply = expectation(description:"DSU reply")
        let server = DSUServer(port:port)
        server.onStatus = { line in if status.store(line) { ready.fulfill() } }
        server.start();defer { server.stop() }
        await fulfillment(of:[ready],timeout:3)
        guard status.load().hasPrefix("Listening") else { throw XCTSkip("Local UDP listener unavailable in this environment: " + status.load()) }
        let connection = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:.udp)
        defer { connection.cancel() }
        connection.start(queue:.global())
        connection.receiveMessage { data,_,_,error in
            XCTAssertNil(error);XCTAssertEqual(data?.count,24);XCTAssertEqual(data.map { String(decoding:$0.prefix(4),as:UTF8.self) },"DSUS");reply.fulfill()
        }
        connection.send(content:request(0x100000),completion:.idempotent)
        await fulfillment(of:[reply],timeout:3)
        server.publish(source:"fixture",gyro:[0,0,0],acceleration:[0,1,0])
        let motion = expectation(description:"DSU subscription motion")
        connection.receiveMessage { data,_,_,error in
            XCTAssertNil(error);XCTAssertEqual(data?.count,32)
            connection.receiveMessage { data,_,_,error in
                XCTAssertNil(error);XCTAssertEqual(data?.count,100)
                let bytes = Array(data ?? Data())
                XCTAssertEqual(DSUProtocol.read(bytes,at:16,count:4),0x100002)
                XCTAssertEqual(Float(bitPattern:UInt32(DSUProtocol.read(bytes,at:80,count:4))),1)
                motion.fulfill()
            }
            server.publish(source:"fixture",gyro:[1,0,0],acceleration:[0,1,0])
        }
        connection.send(content:request(0x100002,[0,0,0,0,0,0,0,0]),completion:.idempotent)
        connection.send(content:request(0x100001,[1,0,0,0,0]),completion:.idempotent)
        await fulfillment(of:[motion],timeout:3)
        let stopped = expectation(description:"DSU released port")
        server.stop { stopped.fulfill() }
        await fulfillment(of:[stopped],timeout:3)
        let replacement = DSUServer(port:port), rebound = expectation(description:"DSU restart on same port")
        replacement.onStatus = { line in XCTAssertTrue(line.hasPrefix("Listening"),line); rebound.fulfill() }
        replacement.start();defer { replacement.stop() }
        await fulfillment(of:[rebound],timeout:3)
    }
}
