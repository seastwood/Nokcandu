import XCTest
@testable import NokcanduCore
final class SteamPadSteadinessTests: XCTestCase {
    func testSlowVerticalTravelSuppressesSmallLateralWobbleWithoutAxisLock() {
        var settings=PadSteamTrackpadSettings(mode:.mouse)
        settings.sensitivity=1000;settings.steadiness=2
        var pad=PadSteamTrackpad();var total=PadSteamTrackpad.Motion()
        _=pad.touch(down:true,x:0.5,y:0.5,at:1,settings:settings)
        for n in 1...100 {
            let out=pad.touch(down:true,x:0.5+(n%2==0 ? 0.001 : -0.001),y:0.5+Double(n)*0.0005,at:1+Double(n)*0.01,settings:settings)
            XCTAssertEqual(out.x,0)
            total.x += out.x;total.y += out.y
        }
        XCTAssertGreaterThanOrEqual(total.y,40,"Slow intentional travel accumulates rather than being discarded (less the landing guard)")
        let diagonal=pad.touch(down:true,x:0.52,y:0.57,at:2.01,settings:settings)
        XCTAssertGreaterThan(diagonal.x,0);XCTAssertGreaterThan(diagonal.y,0)
        _=pad.touch(down:false,x:0,y:0,at:2.02,settings:settings)
        XCTAssertEqual(pad.touch(down:true,x:0.1,y:0.1,at:2.03,settings:settings),.init())
    }
    func testOptionalSteadinessDefaultsToUnchangedRawMotionAndRoundTrips() throws {
        var raw=PadSteamTrackpadSettings(mode:.mouse)
        raw.sensitivity=1000
        var explicit=raw;explicit.steadiness=0
        var a=PadSteamTrackpad(),b=PadSteamTrackpad()
        for n in 0...20 {
            let x=0.3+Double(n)*0.003,y=0.4+Double(n)*0.002,t=1+Double(n)*0.01
            XCTAssertEqual(a.touch(down:true,x:x,y:y,at:t,settings:raw),b.touch(down:true,x:x,y:y,at:t,settings:explicit))
        }
        explicit.steadiness=1.5
        XCTAssertEqual(try JSONDecoder().decode(PadSteamTrackpadSettings.self,from:JSONEncoder().encode(explicit)),explicit)
    }
}
