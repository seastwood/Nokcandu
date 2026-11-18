import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

final class AdvancedRemappingTests:XCTestCase {
    func axis(_ r:PadRecorder,_ n:Int,_ v:Double,_ time:Double) { pe_axis(r.engine,Int32(n),Int32(v*32767),time) }
    func trigger(_ mode:Int) -> PadRecorder {
        PadRecorder("trigger 0 soft=0.3 full=0.9 behavior=\(mode) delay=0.15 distance=0.1\nbind 0 lt press=key:12\nbind 0 ltfull press=key:13")
    }
    func testStandardTriggersRetainImmediateTwoStageBehavior() {
        let r = trigger(0);axis(r,PE_AXIS_LT,0.5,1);XCTAssertEqual(r.take(),["key 12 down"])
        axis(r,PE_AXIS_LT,1,1.05);XCTAssertEqual(r.take(),["key 13 down"])
        axis(r,PE_AXIS_LT,0,1.1);XCTAssertEqual(r.take(),["key 13 up","key 12 up"])
    }
    func testFastFullPullSkipsSoftAndNeverFiresItLater() {
        for mode in 1...2 {
            let r = trigger(mode);axis(r,PE_AXIS_LT,0.5,1);XCTAssertEqual(r.take(),[])
            XCTAssertEqual(pe_next_deadline(r.engine),1.15,accuracy:0.001)
            axis(r,PE_AXIS_LT,1,1.05);XCTAssertEqual(r.take(),["key 13 down"])
            r.tick(2);XCTAssertEqual(r.take(),[])
            axis(r,PE_AXIS_LT,0.5,2.1);XCTAssertEqual(r.take(),["key 13 up"])
            r.tick(2.4);XCTAssertEqual(r.take(),[])
            axis(r,PE_AXIS_LT,0,3)
            axis(r,PE_AXIS_LT,0.5,4);r.tick(4.16);XCTAssertEqual(r.take(),["key 12 down"])
        }
    }
    func testSlowSoftPullGetsTimerAndExclusiveModeSuppressesFull() {
        for mode in 1...2 {
            let r = trigger(mode);axis(r,PE_AXIS_LT,0.5,1);r.tick(1.16)
            XCTAssertEqual(r.take(),["key 12 down"])
            axis(r,PE_AXIS_LT,1,1.3)
            XCTAssertEqual(r.take(),mode == 2 ? []:["key 13 down"])
            pe_release_all(r.engine,1.5)
            XCTAssertEqual(r.take(),mode == 2 ? ["key 12 up"]:["key 12 up","key 13 up"])
            r.tick(2);XCTAssertTrue(r.take().isEmpty)
        }
    }
    func testShortPartialPullDoesNotFireAndReleaseMainCancelsDecision() {
        let r = trigger(1);axis(r,PE_AXIS_LT,0.5,1);axis(r,PE_AXIS_LT,0,1.05);r.tick(2)
        XCTAssertTrue(r.take().isEmpty)
        axis(r,PE_AXIS_LT,0.5,3);pe_release_main(r.engine,3.01);r.tick(4)
        XCTAssertTrue(r.take().isEmpty);XCTAssertEqual(pe_next_deadline(r.engine),0)
    }
    func testHairTriggerRetriggersWithoutReturningToRestAndDoesNotBounce() {
        let r = trigger(3);axis(r,PE_AXIS_LT,0.8,1);XCTAssertEqual(r.take(),["key 12 down"])
        axis(r,PE_AXIS_LT,0.65,1.1);XCTAssertEqual(r.take(),["key 12 up"])
        axis(r,PE_AXIS_LT,0.65,1.2);XCTAssertEqual(r.take(),[])
        axis(r,PE_AXIS_LT,0.8,1.3);XCTAssertEqual(r.take(),["key 12 down"])
        pe_release_main(r.engine,1.4);XCTAssertEqual(r.take(),["key 12 up"])
        axis(r,PE_AXIS_LT,0.1,2);XCTAssertEqual(r.take(),[])
    }
    func testGridAndHorizontalMenusChooseByPositionAndDoNotMoveGameStick() {
        for (layout,x,y,expected) in [(1,0.9,0.9,13),(2,0.9,0.0,15)] {
            let r = PadRecorder("menu 0 stick=1 layout=\(layout) s0=key:12 s1=key:13 s2=key:14 s3=key:15\nbind 0 rb press=menu:0")
            r.press("rb",true,1);axis(r,PE_AXIS_RX,x,1.1);axis(r,PE_AXIS_RY,-y,1.2)
            XCTAssertEqual(r.axes[2],0);XCTAssertEqual(r.axes[3],0)
            r.press("rb",false,1.3);r.tick(1.4)
            XCTAssertEqual(r.take(),["key \(expected) down","key \(expected) up"])
        }
    }
    func testShortcutMenuStaysOpenConsumesChoiceAndCanCancel() {
        let r = PadRecorder("menu 0 stick=1 layout=3 s0=key:12 s1=key:13\nbind 0 rb press=menu:0")
        r.press("rb",true,1);r.press("rb",false,1.1);XCTAssertTrue(r.take().isEmpty)
        r.press("b",true,2);r.press("b",false,2.01);r.tick(2.1)
        XCTAssertEqual(r.take(),["key 13 down","key 13 up"])
        r.press("rb",true,3);r.press("rb",false,3.1)
        r.press("guide",true,3.2);r.press("guide",false,3.3);XCTAssertTrue(r.take().isEmpty)
        r.press("a",true,4);r.press("a",false,4.1)
        XCTAssertEqual(r.take(),["pad a down","pad a up"])
    }
    func testMenuFocusLossDiscardsSelectionWithoutExecutingIt() {
        for layout in 0...3 {
            let r = PadRecorder("menu 0 stick=1 layout=\(layout) s0=key:12 s1=key:13\nbind 0 rb press=menu:0")
            r.press("rb",true,1);axis(r,PE_AXIS_RY,-1,1.1)
            pe_release_outputs(r.engine,1.2);r.press("rb",false,1.3);r.tick(2)
            XCTAssertTrue(r.take().isEmpty)
        }
    }
    func testAbsolutePadSelectsGridMenuWithoutMovingGamePointer() {
        let r = PadRecorder("menu 0 stick=2 layout=1 s0=key:12 s1=key:13 s2=key:14 s3=key:15\nbind 0 rb press=menu:0")
        r.press("rb",true,1);XCTAssertTrue(pe_menu_absolute(r.engine,0.9,0.9))
        XCTAssertEqual(r.mouse.x,0);XCTAssertEqual(r.mouse.y,0)
        r.press("rb",false,1.1);r.tick(1.2)
        XCTAssertEqual(r.take(),["key 15 down","key 15 up"])
        XCTAssertFalse(pe_menu_absolute(r.engine,0.5,0.5))
    }
    func testQuickMenuPulseBelongsToItsControllerOnDisconnect() {
        let r = PadRecorder("menu 0 stick=1 layout=3 s0=key:12\nbind 0 rb press=menu:0")
        r.press("rb",true,1);r.press("rb",false,1.1);r.press("a",true,2)
        XCTAssertEqual(r.take(),["key 12 down"])
        pe_release_main(r.engine,2.001);XCTAssertEqual(r.take(),["key 12 up"])
        r.tick(3);XCTAssertTrue(r.take().isEmpty)
    }
    func testVirtualGestureInputsCanMapAndCleanUp() {
        for side in 0..<2 { for n in 0..<4 {
            let input = PadProfiles.Input.padGesture(side,n)
            XCTAssertTrue(input.isVirtual);XCTAssertFalse(PadProfiles.Input.padButtons.contains(input))
            let code = pe_input_named(input.rawValue);XCTAssertGreaterThanOrEqual(code,0)
            let r = PadRecorder("bind 0 \(input.rawValue) press=key:12")
            pe_pad_zone(r.engine,code,true,1);pe_release_main(r.engine,1.1);r.tick(2)
            XCTAssertEqual(r.take(),["key 12 down","key 12 up"])
        } }
    }
    func testDefaultsCompileIdenticallyAndNewSettingsRoundTrip() throws {
        var profile = PadProfiles.Profile(name:"Fixture")
        let legacy = PadProfiles.compile(profile,all:[profile])
        XCTAssertFalse(legacy.contains("behavior="));XCTAssertFalse(legacy.contains("layout="))
        var triggers = PadProfiles.Triggers();triggers.behavior = .exclusive;triggers.decisionTime = 0.2
        profile.triggers = triggers
        var menu = PadProfiles.RadialMenu(name:"Grid",slices:[.init(title:"Go",outputs:[.key(12)])]);menu.layout = .grid
        profile.menus = [menu]
        var pad = PadSteamTrackpadSettings(mode:.gestures);pad.gesturePatterns = ["UL","DR"];pad.region = PadMouseRegion()
        profile.steamLeftTrackpad = pad
        let data = try JSONEncoder().encode(profile),restored = try JSONDecoder().decode(PadProfiles.Profile.self,from:data)
        XCTAssertEqual(restored,profile)
        let compiled = PadProfiles.compile(restored,all:[restored])
        XCTAssertTrue(compiled.contains("layout=1"));XCTAssertTrue(compiled.contains("behavior=2 delay=0.2"))
        let old = try JSONDecoder().decode(PadProfiles.Triggers.self,from:Data(#"{"soft":0.3,"full":0.95}"#.utf8))
        XCTAssertNil(old.behavior)
    }
}
