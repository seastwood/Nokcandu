import XCTest
import NokcanduCore
import NokcanduPadEngine

final class SteamControllerReportTests: XCTestCase {
    func packet(_ n: UInt32 = 1, flags: UInt32 = 0, x: Int16 = 0, y: Int16 = 0) -> [UInt8] {
        var p = [UInt8](repeating:0,count:64); p[0]=1;p[2]=1;p[3]=60
        for i in 0..<4 { p[4+i]=UInt8(truncatingIfNeeded:n>>(8*i)) }
        for i in 0..<3 { p[8+i]=UInt8(truncatingIfNeeded:flags>>(8*i)) }
        put(&p,16,x);put(&p,18,y);return p
    }
    func put(_ p: inout [UInt8], _ i: Int, _ v: Int16) { let v=UInt16(bitPattern:v);p[i]=UInt8(v&255);p[i+1]=UInt8(v>>8) }
    func testFramingMalformedAndStatusPacketsDoNotMutateMultiplexedState() throws {
        var d=SteamControllerReport()
        var valid=packet(1,x:20000)
        XCTAssertNotNil(d.decode(valid));XCTAssertNil(d.decode(valid))
        for i in [0,1,2,3] { var bad=packet(2);bad[i] ^= 1;XCTAssertNil(d.decode(bad)) }
        var compact = packet(3); compact[3] = 44
        var compactDecoder = SteamControllerReport(); XCTAssertNotNil(compactDecoder.decode(compact))
        XCTAssertNil(d.decode(Array(valid.dropLast())));XCTAssertNil(d.decode(valid+[0]))
        valid=packet(2,flags:(1<<19)|(1<<23),x:10000)
        let s=try XCTUnwrap(d.decode(valid));XCTAssertEqual(s.stick.x,Float(20000)/32767,accuracy:0.0001)
        XCTAssertTrue(s.leftTouch)
    }
    func testEveryButtonGripsAndLegacyPadClickUseExistingEngineNames() throws {
        let expected:[(Int,PadProfiles.Input)] = [(2,.rb),(3,.lb),(4,.y),(5,.b),(6,.x),(7,.a),(8,.up),(9,.right),(10,.left),(11,.down),(12,.back),(13,.guide),(14,.start),(15,.paddle2),(16,.paddle1),(18,.rs),(22,.ls)]
        for (bit,input) in expected { var d=SteamControllerReport();XCTAssertEqual(d.decode(packet(flags:1<<bit))?.buttons,[input]) }
        var d=SteamControllerReport();XCTAssertEqual(d.decode(packet(flags:1<<17))?.buttons,[.ls])
        XCTAssertEqual(d.decode(packet(2,flags:(1<<17)|(1<<19)))?.buttons,[.touchpad])
    }
    func testInterleavedPadsRetainStickAndNeutralizeWhenReleased() throws {
        var d=SteamControllerReport()
        _=d.decode(packet(1,x:16000,y:-8000))
        let touched=try XCTUnwrap(d.decode(packet(2,flags:(1<<19)|(1<<20)|(1<<23),x:-20000,y:7000)))
        XCTAssertTrue(touched.leftTouch);XCTAssertTrue(touched.rightTouch)
        XCTAssertEqual(touched.stick.x,Float(16000)/32767,accuracy:0.0001)
        let next=try XCTUnwrap(d.decode(packet(3,flags:1<<23,x:18000)))
        XCTAssertTrue(next.leftTouch);XCTAssertEqual(next.leftPad,touched.leftPad)
        let off=try XCTUnwrap(d.decode(packet(4)))
        XCTAssertFalse(off.leftTouch);XCTAssertEqual(off.leftPad,.init())
        XCTAssertEqual(off.axes[2],0);XCTAssertEqual(off.axes[3],0)
    }
    func testAnalogTriggersMotionAndSignedBounds() throws {
        var p=packet(x: .min,y:.max);p[11]=128;p[12]=255
        put(&p,28,16384);put(&p,34,16384);put(&p,36,-16384)
        var d=SteamControllerReport();let s=try XCTUnwrap(d.decode(p))
        XCTAssertEqual(s.stick.x,-1);XCTAssertEqual(s.stick.y,1)
        XCTAssertEqual(s.leftTrigger,Float(128)/255);XCTAssertEqual(s.rightTrigger,1)
        XCTAssertEqual(s.acceleration[0],1)
        XCTAssertEqual(s.gyro[0],Float(1000*Double.pi/180),accuracy:0.0001)
        XCTAssertEqual(s.gyro[1],-s.gyro[0])
        var full=packet(2,flags:3);full[11]=0;full[12]=0
        let f=try XCTUnwrap(d.decode(full));XCTAssertEqual(f.axes[4],32767);XCTAssertEqual(f.axes[5],32767)
    }
    func testDecodedGripToggleAndReleaseWorkThroughRealEngine() throws {
        var d=SteamControllerReport();let r=PadRecorder("bind 0 paddle2 press=keytoggle:49")
        for (i,flags) in [UInt32(1<<15),0,1<<15,0].enumerated() {
            let s=try XCTUnwrap(d.decode(packet(UInt32(i+1),flags:flags)))
            r.press("paddle2",s.buttons.contains(.paddle2),Double(i+1))
        }
        XCTAssertEqual(r.take(),["key 49 down","key 49 up"])
    }
    func testStreamReleasesStaleHoldsAndDoesNotTreatHeartbeatAsInput() throws {
        var stream=SteamControllerStream();let held=packet(flags:1<<7)
        XCTAssertNotNil(stream.accept(held,at:1))
        XCTAssertNil(stream.accept(held,at:1.2),"Duplicate counters do not duplicate motion")
        XCTAssertFalse(stream.expire(at:1.4),"Valid repeated input keeps a physical hold alive")
        var heartbeat=held;heartbeat[2]=4
        XCTAssertNil(stream.accept(heartbeat,at:1.45))
        XCTAssertTrue(stream.expire(at:1.6));XCTAssertNil(stream.state)
        XCTAssertNotNil(stream.accept(held,at:2),"Same counter can start a fresh connection")
        stream.reset();XCTAssertNil(stream.state)
    }
    func testSourceSettingRoundTripsAndDoesNotOptOldProfilesIn() throws {
        var p=PadProfiles.Profile(name:"Steam input")
        XCTAssertNil(p.controllerSource)
        p.controllerSource = .steamUSB
        XCTAssertEqual(try JSONDecoder().decode(PadProfiles.Profile.self,from:JSONEncoder().encode(p)),p)
        var child=PadProfiles.Profile(name:"Child",buildsOn:[p.id])
        XCTAssertEqual(PadProfiles.top(child,all:[p,child],\.controllerSource),.steamUSB)
        child.controllerSource = .automatic
        XCTAssertEqual(PadProfiles.top(child,all:[p,child],\.controllerSource),.automatic)
    }
}
