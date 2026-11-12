import XCTest
@testable import NokcanduCore
final class PadProfileLabelTests: XCTestCase {
    func testChoicesStayWithTheirOwnProfileAndCompileIdentically() throws {
        var steam=PadProfiles.Profile(name:"Steam")
        steam.controllerSource = .steamUSB
        var pro=PadProfiles.Profile(name:"Pro")
        pro.controllerLabels="nintendo"
        var xbox=PadProfiles.Profile(name:"Xbox")
        xbox.controllerLabels="xbox"
        XCTAssertEqual(PadProfiles.controllerLabelFamily(steam,all:[steam,pro,xbox],connected:.nintendo),.valve)
        XCTAssertEqual(PadProfiles.controllerLabelFamily(pro,all:[steam,pro,xbox],connected:.valve),.nintendo)
        XCTAssertNil(PadProfiles.controllerLabelFamily(xbox,all:[steam,pro,xbox],connected:.nintendo))
        let before=PadProfiles.compile(pro,all:[pro])
        pro.controllerLabels="playstation"
        XCTAssertEqual(PadProfiles.compile(pro,all:[pro]),before,"Display labels never remap an input")
        XCTAssertEqual(PadProfiles.controllerLabelFamily(steam,all:[steam,pro],connected:.nintendo),.valve)
        XCTAssertEqual(try JSONDecoder().decode(PadProfiles.Profile.self,from:JSONEncoder().encode(pro)),pro)
    }
    func testOlderUnknownAndInheritedLabelsDoNotContaminateProfiles() throws {
        var base=PadProfiles.Profile(name:"Base")
        base.controllerLabels="valve"
        var child=PadProfiles.Profile(name:"Child",buildsOn:[base.id])
        XCTAssertEqual(PadProfiles.controllerLabelFamily(child,all:[base,child],connected:.nintendo),.nintendo)
        child.controllerLabels="future-controller"
        XCTAssertEqual(PadProfiles.controllerLabelFamily(child,all:[base,child],connected:.playstation),.playstation)
        base.controllerSource = .steamUSB
        XCTAssertEqual(PadProfiles.controllerLabelFamily(child,all:[base,child],connected:.nintendo),.valve)
        let old=Data("{\"id\":\"old\",\"name\":\"Old\",\"buildsOn\":[],\"layers\":[{\"id\":\"base\",\"name\":\"Base\",\"bindings\":{}}]}".utf8)
        let decoded=try JSONDecoder().decode(PadProfiles.Profile.self,from:old)
        XCTAssertNil(decoded.controllerLabels)
    }
}
