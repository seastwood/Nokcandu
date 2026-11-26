import XCTest
import NokcanduPadEngine
@testable import NokcanduCore

final class PadRemapExtrasTests: XCTestCase {
    func testReleaseActionFiresOnLetGoAndTheButtonStaysItself() {
        let r = PadRecorder("bind 0 a release=key:13")
        r.press("a", true, 1); r.press("a", false, 1.5); r.tick(2)
        XCTAssertEqual(r.take(), ["pad a down", "pad a up", "key 13 down", "key 13 up"])
    }

    func testReleaseActionAfterAHold() {
        let r = PadRecorder("bind 0 a press=key:12 release=key:13")
        r.press("a", true, 1); r.press("a", false, 1.5); r.tick(2)
        XCTAssertEqual(r.take(), ["key 12 down", "key 12 up", "key 13 down", "key 13 up"])
    }

    func testCycleDoesTheNextEachPress() {
        let r = PadRecorder("bind 0 a cycle=key:18|key:19|key:20")
        for i in 0..<4 { let t = Double(i); r.press("a", true, t); r.press("a", false, t + 0.1) }
        XCTAssertEqual(r.take(), ["key 18 down", "key 18 up", "key 19 down", "key 19 up", "key 20 down", "key 20 up", "key 18 down", "key 18 up"])
    }

    func testLongHoldTakesOverFromTheHold() {
        let r = PadRecorder("bind 0 b tap=key:8 hold=key:59 holdtime=0.2 longhold=key:31 longtime=0.8")
        r.press("b", true, 1); r.tick(1.3)
        XCTAssertEqual(r.take(), ["key 59 down"])
        r.tick(1.9)
        XCTAssertEqual(r.take(), ["key 59 up", "key 31 down"])
        r.press("b", false, 2)
        XCTAssertEqual(r.take(), ["key 31 up"])
        // A quick tap is still a tap.
        r.press("b", true, 3); r.press("b", false, 3.05); r.tick(3.5)
        XCTAssertEqual(r.take(), ["key 8 down", "key 8 up"])
    }

    func testInstantTapFiresOnPressAndNotAgain() {
        let r = PadRecorder("bind 0 b tap=key:8 hold=key:59 holdtime=0.2 instant=1")
        r.press("b", true, 1)
        XCTAssertEqual(r.take(), ["key 8 down"])
        r.press("b", false, 1.05); r.tick(1.5)
        XCTAssertEqual(r.take(), ["key 8 up"])
        // Held, the hold follows the tap.
        r.press("b", true, 2); r.tick(2.3)
        XCTAssertEqual(r.take(), ["key 8 down", "key 8 up", "key 59 down"])
        r.press("b", false, 2.4)
        XCTAssertEqual(r.take(), ["key 59 up"])
    }

    func testOuterRingHoldsPastTheRingAndLetsGoInside() {
        let r = PadRecorder("stick 0 ring=0.8\nbind 0 lsring press=key:56")
        pe_axis(r.engine, Int32(PE_AXIS_LX), Int32(32767 * 0.9), 1)
        XCTAssertEqual(r.take(), ["key 56 down"])
        pe_axis(r.engine, Int32(PE_AXIS_LX), Int32(32767 * 0.78), 1.1)      // just inside: still held
        XCTAssertEqual(r.take(), [])
        pe_axis(r.engine, Int32(PE_AXIS_LX), Int32(32767 * 0.5), 1.2)
        XCTAssertEqual(r.take(), ["key 56 up"])
    }

    func testSidewaysScroll() {
        let r = PadRecorder("bind 0 a press=hwheel:left\nbind 0 b press=hwheel:right")
        r.press("a", true, 1); r.press("a", false, 1.1); r.press("b", true, 2); r.press("b", false, 2.1)
        XCTAssertEqual(r.take(), ["hwheel -1", "hwheel 1"])
    }

    func testProfilesCompileTheNewParts() {
        var b = PadProfiles.Binding(tap: [.key(8)], hold: [.key(59)])
        b.release = [.key(13)]; b.longHold = [.key(31)]; b.longTime = 0.9; b.instantTap = true
        var c = PadProfiles.Binding(); c.cycle = [[.key(18)], [.key(19)]]
        var p = PadProfiles.Profile(name: "t")
        p.layers[0][.b] = b; p.layers[0][.a] = c
        p.leftStick = PadProfiles.Stick(); p.leftStick?.ring = 0.75
        let text = PadProfiles.compile(p, all: [p])
        XCTAssertTrue(text.contains("release=key:13"))
        XCTAssertTrue(text.contains("longhold=key:31 longtime=0.9"))
        XCTAssertTrue(text.contains("instant=1"))
        XCTAssertTrue(text.contains("cycle=key:18|key:19"))
        XCTAssertTrue(text.contains("ring=0.75"))
        XCTAssertEqual(PadProfiles.Output(token: "hwheel:left"), .hwheel(right: false))
    }
}
