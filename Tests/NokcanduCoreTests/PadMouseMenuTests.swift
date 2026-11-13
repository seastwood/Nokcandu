import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

final class PadMouseMenuTests: XCTestCase {
    func testActionNamesAreAutomaticOnlyWhenTitleIsBlank() {
        var slice = PadProfiles.RadialMenu.Slice(title:"",outputs:[.key(13)])
        XCTAssertEqual(slice.displayTitle(),"W")
        slice.outputs = [.key(14)]
        XCTAssertEqual(slice.displayTitle(),"E")
        slice.title = "My action"
        XCTAssertEqual(slice.displayTitle(),"My action")
        XCTAssertEqual(PadProfiles.RadialMenu.Slice(title:"Up",outputs:[.key(13)]).displayTitle(),"Up")
    }
    let menu = "menu 0 stick=2 s0=key:12 s1=key:13 s2=key:14 s3=key:15\nbind 0 a press=menu:0"
    func testPointerDirectionsChooseOnReleaseAndIgnoreInvalidSamples() {
        for (x, y, key) in [(0.0,-40.0,12),(40,0,13),(0,40,14),(-40,0,15)] {
            let r = PadRecorder(menu)
            XCTAssertFalse(pe_menu_mouse(r.engine,x,y))
            r.press("a",true,1)
            XCTAssertTrue(pe_menu_mouse(r.engine,x,y))
            XCTAssertTrue(pe_menu_mouse(r.engine,0,0))
            XCTAssertTrue(pe_menu_mouse(r.engine,.nan,.infinity))
            XCTAssertTrue(r.take().isEmpty, "Selection must not activate its action before release")
            r.press("a",false,1.1); r.tick(1.3)
            XCTAssertEqual(r.take(),["key \(key) down","key \(key) up"])
            XCTAssertFalse(pe_menu_mouse(r.engine,10,0))
        }
    }
    func testLatestDirectionWinsAndFocusCancellationDoesNotCommit() {
        let r = PadRecorder(menu)
        r.press("a",true,1)
        _ = pe_menu_mouse(r.engine,0,-40); _ = pe_menu_mouse(r.engine,90,0)
        r.press("a",false,1.1); r.tick(1.3)
        XCTAssertEqual(r.take(),["key 13 down","key 13 up"])
        r.press("a",true,2); _ = pe_menu_mouse(r.engine,0,40)
        pe_release_all(r.engine,2.1); r.tick(2.3)
        XCTAssertTrue(r.take().isEmpty)
        r.press("a",true,3); r.press("a",false,3.1); r.tick(3.3)
        XCTAssertTrue(r.take().isEmpty,"A new menu must start with no selection")
    }
    func testGyroMouseSelectsWithoutMovingDesktopAndResumesAfterward() {
        let r = PadRecorder(menu + "\ngyro out=mouse on=1 min=10 max=10 smooth=0 tight=0 cal=off")
        r.press("a",true,1)
        for n in 0...10 { pe_gyro(r.engine,0,-1,0,1+Double(n)*0.01) }
        XCTAssertEqual(r.mouse.x,0); XCTAssertEqual(r.mouse.y,0)
        r.press("a",false,1.2); r.tick(1.3)
        XCTAssertEqual(r.take(),["key 13 down","key 13 up"])
        for n in 0...10 { pe_gyro(r.engine,0,-1,0,2+Double(n)*0.01) }
        XCTAssertGreaterThan(r.mouse.x,0)
    }
    func testExistingStickPickerRejectsPointerAndProfileRoundTripsNewPicker() throws {
        let r = PadRecorder(menu.replacingOccurrences(of:"stick=2",with:"stick=1"))
        r.press("a",true,1)
        XCTAssertFalse(pe_menu_mouse(r.engine,10,0))
        pe_axis(r.engine,Int32(PE_AXIS_RY),-32767,1.1)
        r.press("a",false,1.2); r.tick(1.4)
        XCTAssertEqual(r.take(),["key 12 down","key 12 up"])
        var profile = PadProfiles.Profile(name:"Pointer menu")
        profile.menus = [.init(name:"Pick",stick:2,slices:[.init(title:"W",outputs:[.key(13)])])]
        let decoded = try JSONDecoder().decode(PadProfiles.Profile.self,from:JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.menus?.first?.stick,2)
        XCTAssertTrue(PadProfiles.compile(decoded,all:[decoded]).contains("menu 0 stick=2"))
    }

    func testSmallMovementsDoNotFlickBetweenSlices() {
        let r = PadRecorder(menu)
        r.press("a",true,1)
        // A hand's wobble: tiny moves in every direction choose nothing.
        for n in 0..<40 { _ = pe_menu_mouse(r.engine, n % 2 == 0 ? 3 : -3, n % 3 == 0 ? 2 : -2) }
        r.press("a",false,1.1); r.tick(1.3)
        XCTAssertTrue(r.take().isEmpty, "nothing chosen from noise")
        // A steady push right, even with some wobble, chooses right and stays there.
        r.press("a",true,2)
        for n in 0..<20 { _ = pe_menu_mouse(r.engine, 4, n % 2 == 0 ? 3 : -3) }
        r.press("a",false,2.1); r.tick(2.3)
        XCTAssertEqual(r.take(),["key 13 down","key 13 up"])
    }
    func testGyroPicksEvenWhenItsNormallyOnlyOnWhileTouched() {
        let r = PadRecorder("gyro out=mouse on=1 min=10 max=10 cal=off\n" + menu)
        pe_gyro_touch(r.engine, true, false)
        r.press("a",true,1)
        // Turning right at 60 °/s for half a second.
        for n in 0...50 { pe_gyro(r.engine, 0, -60 * .pi / 180, 0, 1 + Double(n) * 0.01) }
        r.press("a",false,1.6); r.tick(1.8)
        XCTAssertEqual(r.take(),["key 13 down","key 13 up"])
        XCTAssertEqual(r.mouse.x, 0, "while picking, the gyro doesn't move the pointer")
    }
}
