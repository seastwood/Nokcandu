import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

final class SteamPadEnhancementTests: XCTestCase {
    func testIndependentAxisSensitivityAndOldSettingsDecode() throws {
        let old = Data(#"{"mode":"trackball","sensitivity":1500,"halfLife":0.16,"invertY":false}"#.utf8)
        var settings = try JSONDecoder().decode(PadSteamTrackpadSettings.self,from:old)
        XCTAssertNil(settings.sensitivityX); XCTAssertNil(settings.gyroWhileTouched)
        settings.sensitivityX=2000; settings.sensitivityY=500
        var pad=PadSteamTrackpad()
        _=pad.touch(down:true,x:0.5,y:0.5,at:1,settings:settings)
        let motion=pad.touch(down:true,x:0.6,y:0.6,at:1.02,settings:settings)
        XCTAssertEqual(Double(motion.x),200,accuracy:1)
        XCTAssertEqual(Double(motion.y),50,accuracy:1)
        XCTAssertEqual(try JSONDecoder().decode(PadSteamTrackpadSettings.self,from:JSONEncoder().encode(settings)),settings)
    }
    func testMeasuredLiftTailCannotReverseOrDominateFlickDirection() {
        // Coordinates from a deliberately horizontal hardware swipe: the final
        // two still-touched samples roll vertically/reverse before touch clears.
        let samples:[(Double,Double,Double)] = [
            (0,8890,6630),(0.008,6894,6200),(0.016,4578,5684),(0.028,2260,5164),
            (0.036,-1946,5368),(0.044,-7380,4520),(0.052,-13854,3496),(0.064,-20738,1448),
            (0.072,-26742,-564),(0.080,-30490,-1848),(0.088,-27908,-12756),(0.100,-24976,-20908)]
        for direction in [1.0,-1.0] {
            var pad=PadSteamTrackpad();let settings=PadSteamTrackpadSettings(mode:.trackball)
            for (time,x,y) in samples { _=pad.touch(down:true,x:(direction*x/32767+1)/2,y:(1-y/32767)/2,at:1+time,settings:settings) }
            _=pad.touch(down:false,x:0.5,y:0.5,at:1.108,settings:settings)
            let coast=pad.tick(at:1.128,settings:settings)
            XCTAssertLessThan(Double(coast.x)*direction,0)
            XCTAssertLessThan(abs(Double(coast.y)),abs(Double(coast.x))*0.5)
        }
    }
    func testTouchGyroOverridesDefaultButOffHoldAndRoutingStillWin() {
        let r=PadRecorder("gyro out=mouse on=0 min=10 max=10 smooth=0 tight=0 cal=off\nbind 0 a press=gyro:off")
        pe_gyro_touch(r.engine,true,false)
        pe_gyro(r.engine,0,1,0,1);pe_gyro(r.engine,0,1,0,1.01)
        XCTAssertEqual(r.mouse.x,0)
        pe_gyro_touch(r.engine,true,true)
        pe_gyro(r.engine,0,1,0,1.02);pe_gyro(r.engine,0,1,0,1.03)
        XCTAssertNotEqual(r.mouse.x,0)
        r.press("a",true,1.04)
        let prior=r.mouse.x
        pe_gyro(r.engine,0,1,0,1.05);XCTAssertEqual(r.mouse.x,prior)
        r.press("a",false,1.06)
        pe_gyro_touch(r.engine,true,false)
        pe_gyro(r.engine,0,1,0,1.07);XCTAssertEqual(r.mouse.x,prior)
        pe_gyro_touch(r.engine,true,true);pe_release_main(r.engine,1.08)
        XCTAssertEqual(pe_active_gyro(r.engine),0)
        let native=PadRecorder("gyro out=mouse on=1 cal=off\nroute gyro native")
        pe_gyro_touch(native.engine,true,true)
        pe_gyro(native.engine,0,1,0,1);pe_gyro(native.engine,0,1,0,1.01)
        XCTAssertEqual(native.mouse.x,0)
    }
    func testTouchReleaseImmediatelyCentersGyroStickWithoutResettingOtherHolds() {
        let r=PadRecorder("gyro out=rstick on=0 cal=off\nbind 0 b press=key:12")
        r.press("b",true,1)
        pe_gyro_touch(r.engine,true,true)
        pe_gyro(r.engine,0,1,0,1.01);pe_gyro(r.engine,0,1,0,1.02)
        XCTAssertNotEqual(r.axes[2],0)
        pe_gyro_touch(r.engine,true,false)
        XCTAssertEqual(r.axes[2],0);XCTAssertEqual(r.axes[3],0)
        XCTAssertFalse(r.events.contains("key 12 up"))
    }
    func testTouchGateSuppressesAlwaysOnGyroAcrossLiveTuning() {
        let r=PadRecorder("gyro out=mouse on=1 min=10 max=10 smooth=0 tight=0 cal=off")
        pe_gyro_touch(r.engine,true,false)
        pe_gyro(r.engine,0,1,0,1);pe_gyro(r.engine,0,1,0,1.01)
        XCTAssertEqual(r.mouse.x,0)
        XCTAssertTrue(pe_update_profile(r.engine,"nokpad 1\ngyro out=mouse on=1 min=20 max=20 smooth=0 tight=0 cal=off"))
        pe_gyro(r.engine,0,1,0,1.02);XCTAssertEqual(r.mouse.x,0)
        pe_gyro_touch(r.engine,true,true)
        pe_gyro(r.engine,0,1,0,1.03);pe_gyro(r.engine,0,1,0,1.04)
        XCTAssertNotEqual(r.mouse.x,0)
        let prior=r.mouse.x
        pe_gyro_touch(r.engine,true,false)
        pe_gyro(r.engine,0,1,0,1.05);XCTAssertEqual(r.mouse.x,prior)
    }
    func testFiniteHapticPacketAndSharedRateLimit() throws {
        let pulse=try XCTUnwrap(SteamControllerHaptics.pulse(side:1,strength:0.35))
        XCTAssertEqual(pulse.count,64);XCTAssertEqual(Array(pulse.prefix(3)),[0x8f,7,0])
        XCTAssertEqual(SteamControllerHaptics.pulse(side:0,strength:0.35)?[2],1)
        XCTAssertEqual(pulse[7],3);XCTAssertTrue(pulse.dropFirst(8).allSatisfy{$0==0})
        XCTAssertNil(SteamControllerHaptics.pulse(side:2,strength:1))
        XCTAssertNil(SteamControllerHaptics.pulse(side:1,strength:.nan))
        var feedback=SteamControllerHaptics()
        XCTAssertNil(feedback.movement(side:1,dx:0,dy:0,strength:0.35,at:1))
        XCTAssertNotNil(feedback.movement(side:1,dx:1,dy:0,strength:0.35,at:1))
        XCTAssertNil(feedback.movement(side:1,dx:1,dy:0,strength:0.35,at:1.01))
        XCTAssertNotNil(feedback.movement(side:0,dx:1,dy:0,strength:0.35,at:1.01))
        XCTAssertNotNil(feedback.movement(side:1,dx:1,dy:0,strength:0.35,at:1.03))
    }
}
