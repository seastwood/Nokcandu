import XCTest
@testable import NokcanduCore
final class PadAdvancedTouchTests:XCTestCase {
    func testRegionScalesToWindowScreenAndNegativeDisplayCoordinates() throws {
        var region = PadMouseRegion();region.x = 0.5;region.y = 0.25;region.width = 0.5;region.height = 0.25
        XCTAssertEqual(region.point(x:0,y:0),CGPoint(x:0.5,y:0.25))
        XCTAssertEqual(region.point(x:1,y:1),CGPoint(x:1,y:0.5))
        XCTAssertEqual(region.point(x:1,y:1,in:CGRect(x:-1920,y:-500,width:1920,height:1000)),CGPoint(x:-1,y:-0.5))
        XCTAssertEqual(region.point(x:-1,y:2),CGPoint(x:0.5,y:0.5))
        region.width = -.infinity;XCTAssertNil(region.point(x:0,y:0))
        region.width = 0;XCTAssertNil(region.point(x:0,y:0))
    }
    func testRegionOverFullSizeLetsARoundPadReachTheCorners() throws {
        var region = PadMouseRegion();region.width = 1.5;region.height = 1.5
        // A round pad's corner touch (about 0.16 in from each edge) reaches the screen corner.
        let corner = try XCTUnwrap(region.point(x:0.16,y:0.16))
        XCTAssertEqual(corner.x,0,accuracy:0.001);XCTAssertEqual(corner.y,0,accuracy:0.001)
        let center = try XCTUnwrap(region.point(x:0.5,y:0.5))
        XCTAssertEqual(center.x,0.5,accuracy:0.001);XCTAssertEqual(center.y,0.5,accuracy:0.001)
        XCTAssertEqual(region.point(x:1,y:1),CGPoint(x:1,y:1))
    }
    func testGestureFiresOnlyOnLiftAndUsesOrderedDirections() {
        var r = PadGestureRecognizer()
        XCTAssertNil(r.update(down:true,x:0.5,y:0.8));XCTAssertNil(r.update(down:true,x:0.5,y:0.3))
        XCTAssertNil(r.update(down:true,x:0.9,y:0.3))
        XCTAssertEqual(r.update(down:false,x:0.9,y:0.3),"UR")
        XCTAssertNil(r.update(down:false,x:0.9,y:0.3))
        XCTAssertEqual(PadGestureRecognizer.match("UR",patterns:["U","UR","DL"]),1)
    }
    func testNoiseTouchAndResetNeverEmitCommands() {
        var r = PadGestureRecognizer();_ = r.update(down:true,x:0.5,y:0.5)
        _ = r.update(down:true,x:0.52,y:0.49);XCTAssertNil(r.update(down:false,x:0.52,y:0.49))
        _ = r.update(down:true,x:0.5,y:0.5);_ = r.update(down:true,x:0.9,y:0.5);r.reset()
        XCTAssertNil(r.update(down:false,x:0.9,y:0.5))
        _ = r.update(down:true,x:0.5,y:0.5);XCTAssertNil(r.update(down:true,x:.nan,y:0));XCTAssertNil(r.update(down:false,x:0,y:0))
    }
    func testToleranceIsOptInAndBoundedWithDeterministicTies() {
        XCTAssertNil(PadGestureRecognizer.match("URD",patterns:["UR"]))
        XCTAssertEqual(PadGestureRecognizer.match("URD",patterns:["UR","UL"],tolerance:0.34),0)
        XCTAssertNil(PadGestureRecognizer.match("R",patterns:["L"],tolerance:1))
        XCTAssertNil(PadGestureRecognizer.match("",patterns:[""]))
        XCTAssertEqual(PadGestureRecognizer.normalized("u u, r r d"),"URD")
    }
    func testOversizedGesturesAreCancelledRatherThanMatchingATruncatedPrefix() {
        var r = PadGestureRecognizer();_ = r.update(down:true,x:0,y:0.5)
        for i in 0..<60 { _ = r.update(down:true,x:i%2 == 0 ? 1:0,y:0.5) }
        XCTAssertLessThanOrEqual(r.path.count,24);XCTAssertNil(r.update(down:false,x:0,y:0.5))
    }
    func testPadAngleRotatesAbsoluteAndGestureCoordinates() {
        var s = PadSteamTrackpadSettings(mode:.absolute);s.rotation = 0
        let upright = s.normalizedTouch(x:0,y:1);XCTAssertEqual(upright.x,0.5);XCTAssertEqual(upright.y,0)
        s.rotation = 45
        let rotated = s.normalizedTouch(x:1,y:0)
        XCTAssertGreaterThan(rotated.x,0.8);XCTAssertLessThan(rotated.y,0.2)
    }
}
