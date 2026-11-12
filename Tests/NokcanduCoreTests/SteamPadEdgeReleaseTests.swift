import XCTest
@testable import NokcanduCore
final class SteamPadEdgeReleaseTests: XCTestCase {
    func testMeasuredVerticalSwipeCannotLaunchSidewaysAfterEdgeRoll() {
        // Wireless capture: Y settles at the lower edge while the fingertip rolls
        // sideways for 88 ms before lift. The old recent median launched sideways.
        let samples:[(Double,Double,Double)] = [
            (0,-666,4896),(0.008,-462,4140),(0.016,-462,3630),(0.024,-108,1796),
            (0.036,564,-1470),(0.044,728,-3866),(0.052,14,-7306),(0.060,-482,-12822),
            (0.072,-1592,-17080),(0.080,-2064,-21166),(0.088,-2664,-24780),(0.096,-3402,-27620),
            (0.104,-3380,-30254),(0.116,-2720,-31702),(0.124,-1652,-32126),(0.132,-1268,-32532),
            (0.144,-736,-32492),(0.152,-348,-32286),(0.172,56,-32178),(0.180,8,-31834),
            (0.188,188,-32268),(0.196,236,-32498)]
        for direction in [1.0,-1.0] {
            var pad=PadSteamTrackpad();let settings=PadSteamTrackpadSettings(mode:.trackball)
            for (t,x,y) in samples { _=pad.touch(down:true,x:(x/32767+1)/2,y:(1-direction*y/32767)/2,at:1+t,settings:settings) }
            _=pad.touch(down:false,x:0.5,y:0.5,at:1.204,settings:settings)
            let coast=pad.tick(at:1.224,settings:settings)
            XCTAssertGreaterThan(Double(coast.y)*direction,0)
            XCTAssertLessThan(abs(Double(coast.x)),abs(Double(coast.y))*0.5)
        }
    }
    func testDiagonalEdgeFlickStaysDiagonalAndRestDoesNotReuseOldMomentum() {
        var pad=PadSteamTrackpad();let settings=PadSteamTrackpadSettings(mode:.trackball)
        _=pad.touch(down:true,x:0.5,y:0.5,at:1,settings:settings)
        for n in 1...10 { _=pad.touch(down:true,x:0.5+Double(n)*0.049,y:0.5+Double(n)*0.049,at:1+Double(n)*0.01,settings:settings) }
        _=pad.touch(down:false,x:0.5,y:0.5,at:1.108,settings:settings)
        let coast=pad.tick(at:1.128,settings:settings)
        XCTAssertGreaterThan(coast.x,0);XCTAssertEqual(coast.x,coast.y)
        pad.reset()
        _=pad.touch(down:true,x:0.5,y:0.5,at:2,settings:settings)
        _=pad.touch(down:true,x:0.99,y:0.99,at:2.01,settings:settings)
        for n in 2...30 { _=pad.touch(down:true,x:0.99,y:0.99,at:2+Double(n)*0.01,settings:settings) }
        _=pad.touch(down:false,x:0.5,y:0.5,at:2.308,settings:settings)
        XCTAssertEqual(pad.tick(at:2.328,settings:settings),.init())
    }
}
