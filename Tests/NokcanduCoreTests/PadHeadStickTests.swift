import XCTest
import NokcanduCore
import NokcanduPadEngine

final class PadHeadStickTests: XCTestCase {
    func testLegacyDefaultsMouseAndNewOutputRoundTrip() throws {
        let old=try JSONDecoder().decode(PadHeadMotionSettings.self,from:Data("{}".utf8))
        XCTAssertEqual(old.output,.mouse)
        let s=PadHeadMotionSettings(activation:.whileHeld,output:.rightStick,stickRange:0.4)
        XCTAssertEqual(try JSONDecoder().decode(PadHeadMotionSettings.self,from:JSONEncoder().encode(s)),s)
        XCTAssertEqual(s.normalized.output,.rightStick);XCTAssertEqual(s.normalized.stickRange,0.4)
    }
    func testHeldTurnReturnsSustainedStickAndCenterReleases() {
        var h=PadHeadStick()
        XCTAssertEqual(h.sample(yaw:0,pitch:0).0,0)
        XCTAssertEqual(h.sample(yaw:-0.25,pitch:0,smoothing:1).0,1)
        XCTAssertEqual(h.sample(yaw:-0.25,pitch:0,smoothing:1).0,1)
        XCTAssertEqual(h.sample(yaw:0,pitch:0,smoothing:1).0,0)
        XCTAssertEqual(h.sample(yaw:-0.25,pitch:0,active:false).0,0)
        XCTAssertEqual(h.sample(yaw:0.8,pitch:0,smoothing:1).0,0,"Reactivation takes a new neutral pose")
        XCTAssertEqual(h.sample(yaw:.nan,pitch:0).0,0)
    }
    func testYawWrapUsesShortDistanceAndInvalidRangeFailsClosed() {
        var h=PadHeadStick();_=h.sample(yaw:.pi-0.01,pitch:0)
        XCTAssertEqual(h.sample(yaw: -.pi+0.01,pitch:0,smoothing:1).0,-0.08,accuracy:0.0001)
        XCTAssertEqual(h.sample(yaw:0,pitch:0,range:0).0,0)
    }
    func testHeadStickDrivesWASDAndRemovalRestoresPhysicalStick() {
        var source=PadSourceState(), h=PadHeadStick()
        let r=PadRecorder("stick 0 mode=keys keys=13,1,0,2")
        func apply(_ c:PadSourceState.Changes,_ t:Double){for (a,v) in c.axes{pe_axis(r.engine,Int32(a),Int32(v),t)}}
        apply(source.update(source:"physical",buttons:[],axes:[0:-20000]),1)
        _=h.sample(yaw:0,pitch:0)
        let head=h.sample(yaw:-0.25,pitch:0,smoothing:1)
        apply(source.update(source:"head",buttons:[],axes:[0:Int(head.0*32767),1:Int(head.1*32767)]),2)
        apply(source.update(source:"head",buttons:[],axes:[:]),3)
        apply(source.update(source:"physical",buttons:[],axes:[:]),4)
        let events = r.take()
        XCTAssertEqual(events.filter { $0.hasPrefix("key 0 ") },["key 0 down","key 0 up","key 0 down","key 0 up"])
        XCTAssertEqual(events.filter { $0.hasPrefix("key 2 ") },["key 2 down","key 2 up"])
    }
    func testHeadStickSelectsHeldRadialMenuThroughExistingEngine() {
        let r=PadRecorder("menu 0 stick=1 s0=key:18 s1=key:19\nbind 0 rb press=menu:0")
        var h=PadHeadStick();_=h.sample(yaw:0,pitch:0)
        r.press("rb",true,1)
        let p=h.sample(yaw:0,pitch:0.25,smoothing:1)
        pe_axis(r.engine,Int32(PE_AXIS_RY),Int32(p.1*32767),1.1)
        r.press("rb",false,1.2)
        r.tick(1.3)
        XCTAssertEqual(r.take(),["key 18 down","key 18 up"])
    }
}

final class PadHeadSettleTests: XCTestCase {
    func testCentreFollowsSlowlyInsideButNotOutside() {
        var h = PadHeadStick()
        _ = h.sample(yaw: 0, pitch: 0, range: 0.5, deadZone: 0, smoothing: 1, settleTime: 1, settleBelow: 0.4, now: 0)
        // Held a little to the left (inside): drifts back toward the middle over a few seconds.
        var x = 0.0
        for i in 1...300 { x = h.sample(yaw: 0.1, pitch: 0, range: 0.5, deadZone: 0, smoothing: 1, settleTime: 1, settleBelow: 0.4, now: Double(i) / 60).0 }
        XCTAssertLessThan(abs(x), 0.02)
        // A deliberate turn (outside) is not settled away.
        var far = 0.0
        for i in 301...600 { far = h.sample(yaw: 0.1 + 0.4, pitch: 0, range: 0.5, deadZone: 0, smoothing: 1, settleTime: 1, settleBelow: 0.4, now: Double(i) / 60).0 }
        XCTAssertLessThan(far, -0.7)
    }

    func testOffWhenNoSettleTime() {
        var h = PadHeadStick()
        _ = h.sample(yaw: 0, pitch: 0, range: 0.5, deadZone: 0, smoothing: 1, now: 0)
        var x = 0.0
        for i in 1...300 { x = h.sample(yaw: 0.1, pitch: 0, range: 0.5, deadZone: 0, smoothing: 1, now: Double(i) / 60).0 }
        XCTAssertEqual(x, -0.2, accuracy: 0.001)
    }
}
