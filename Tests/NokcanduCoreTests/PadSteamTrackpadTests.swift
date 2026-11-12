import XCTest
@testable import NokcanduCore
final class PadSteamTrackpadTests: XCTestCase {
    func flick(_ pad: inout PadSteamTrackpad, settings: PadSteamTrackpadSettings, at start: Double = 1) {
        _ = pad.touch(down: true,x:0.5,y:0.5,at:start,settings:settings)
        _ = pad.touch(down: true,x:0.6,y:0.5,at:start+0.01,settings:settings)
        _ = pad.touch(down: false,x:0.6,y:0.5,at:start+0.02,settings:settings)
    }
    func testRelativeFingerMovementDoesNotBehaveLikeDeflectedJoystick() {
        var pad = PadSteamTrackpad(); let settings = PadSteamTrackpadSettings(mode: .mouse)
        XCTAssertEqual(pad.touch(down:true,x:0.2,y:0.3,at:1,settings:settings),.init())
        let moved = pad.touch(down:true,x:0.4,y:0.4,at:1.01,settings:settings)
        XCTAssertEqual(Double(moved.x),300,accuracy:1)
        XCTAssertEqual(Double(moved.y),150,accuracy:1)
        XCTAssertEqual(pad.touch(down:true,x:0.4,y:0.4,at:1.02,settings:settings),.init())
        XCTAssertEqual(pad.tick(at:1.03,settings:settings),.init())
        _ = pad.touch(down:false,x:0,y:0,at:1.04,settings:settings)
        XCTAssertEqual(pad.tick(at:1.05,settings:settings),.init())
    }
    func testLiftCoastsButTouchStopsImmediatelyWithoutRecenteringJump() {
        var pad = PadSteamTrackpad(); let settings = PadSteamTrackpadSettings(mode:.trackball)
        flick(&pad,settings:settings)
        XCTAssertGreaterThan(pad.tick(at:1.03,settings:settings).x,0)
        XCTAssertEqual(pad.touch(down:true,x:0.1,y:0.9,at:1.04,settings:settings),.init())
        XCTAssertEqual(pad.tick(at:1.05,settings:settings),.init())
        _ = pad.touch(down:false,x:0.1,y:0.9,at:1.06,settings:settings)
        XCTAssertEqual(pad.tick(at:1.07,settings:settings),.init())
    }
    func testMomentumIsTimeBasedAndUpHeartbeatCannotEraseItsClock() {
        let settings = PadSteamTrackpadSettings(mode:.trackball)
        func travel(step:Double,heartbeat:Bool)->Int {
            var pad=PadSteamTrackpad();flick(&pad,settings:settings)
            var total=0,t=1.02
            while t<1.52-0.000001 {
                t=min(1.52,t+step)
                if heartbeat { _=pad.touch(down:false,x:0.6,y:0.5,at:t,settings:settings) }
                total += pad.tick(at:t,settings:settings).x
            }
            return total
        }
        XCTAssertEqual(Double(travel(step:0.01,heartbeat:false)),Double(travel(step:0.02,heartbeat:false)),accuracy:2)
        XCTAssertEqual(travel(step:0.01,heartbeat:false),travel(step:0.01,heartbeat:true))
    }
    func testRestingFingerGapInvalidSamplesAndResetCancelMomentum() {
        let settings=PadSteamTrackpadSettings(mode:.trackball)
        var pad=PadSteamTrackpad();flick(&pad,settings:settings)
        XCTAssertEqual(pad.tick(at:2,settings:settings),.init())
        flick(&pad,settings:settings,at:3);pad.reset()
        XCTAssertEqual(pad.tick(at:3.03,settings:settings),.init())
        _=pad.touch(down:true,x:0.5,y:0.5,at:4,settings:settings)
        _=pad.touch(down:true,x:0.6,y:0.5,at:4.01,settings:settings)
        _=pad.touch(down:true,x:0.6,y:0.5,at:4.08,settings:settings)
        _=pad.touch(down:false,x:0.6,y:0.5,at:4.09,settings:settings)
        XCTAssertEqual(pad.tick(at:4.1,settings:settings),.init())
        XCTAssertEqual(pad.touch(down:true,x:.nan,y:0,at:4.2,settings:settings),.init())
    }
    func testMousePadCannotAlsoDriveRightJoystickButKeepsPhysicalStickAndTriggers() throws {
        var bytes = [UInt8](repeating:0,count:64)
        bytes[0]=1;bytes[2]=1;bytes[3]=60;bytes[4]=1;bytes[10]=0x10
        bytes[16]=255;bytes[17]=127;bytes[20]=255;bytes[21]=127;bytes[11]=128
        var decoder = SteamControllerReport()
        let state = try XCTUnwrap(decoder.decode(bytes))
        XCTAssertNotEqual(state.axes[2],0)
        let mapped = state.mappingAxes(rightTrackpadAsStick:false)
        XCTAssertEqual(mapped[2],0);XCTAssertEqual(mapped[3],0)
        XCTAssertEqual(mapped[0],state.axes[0]);XCTAssertEqual(mapped[4],state.axes[4])
        XCTAssertEqual(state.mappingAxes(rightTrackpadAsStick:true),state.axes)
    }
    func testPadsAreIndependentAndOldProfilesKeepExistingMappings() throws {
        var profile=PadProfiles.Profile(name:"Steam")
        XCTAssertEqual(PadProfiles.steamTrackpad(0,profile:profile,all:[]).mode,.existing)
        XCTAssertEqual(PadProfiles.steamTrackpad(1,profile:profile,all:[]).mode,.existing)
        profile.steamRightTrackpad=PadSteamTrackpadSettings(mode:.trackball)
        profile.steamLeftTrackpad=PadSteamTrackpadSettings(mode:.mouse)
        let decoded=try JSONDecoder().decode(PadProfiles.Profile.self,from:JSONEncoder().encode(profile))
        XCTAssertEqual(decoded,profile)
        XCTAssertEqual(PadProfiles.steamTrackpad(0,profile:decoded,all:[]).mode,.mouse)
        XCTAssertEqual(PadProfiles.steamTrackpad(1,profile:decoded,all:[]).mode,.trackball)
        profile.routingMode = .native
        XCTAssertEqual(PadProfiles.steamTrackpad(1,profile:profile,all:[]).mode,.existing)
        profile.routingMode = .selective;profile.controlRoutes=["rstick":.disabled]
        XCTAssertEqual(PadProfiles.steamTrackpad(1,profile:profile,all:[]).mode,.existing)
        XCTAssertEqual(PadProfiles.steamTrackpad(0,profile:profile,all:[]).mode,.mouse)
    }
}
