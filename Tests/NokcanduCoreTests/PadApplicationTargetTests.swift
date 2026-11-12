import XCTest
@testable import NokcanduCore
final class PadApplicationTargetTests: XCTestCase {
    let host = URL(fileURLWithPath: "/Games/Launcher.app")
    var helper: URL { host.appendingPathComponent("Contents/SharedSupport/GameApp/Example.app") }
    func testSelectedWrapperRecognizesOnlyItsOwnDirectHelper() {
        let modes = ["launcher": "automatic"]
        let paths = ["launcher": host.path]
        XCTAssertEqual(PadApplicationTarget.mode(bundleID: "helper", application: helper, modes: modes, selectedPaths: paths), .automatic)
        let other = URL(fileURLWithPath: "/Other/Launcher.app/Contents/SharedSupport/GameApp/Example.app")
        XCTAssertEqual(PadApplicationTarget.mode(bundleID: "helper", application: other, modes: modes, selectedPaths: paths), .disabled)
        XCTAssertNil(PadApplicationTarget.helperHost(host.appendingPathComponent("Contents/Helpers/Example.app")))
        XCTAssertEqual(PadApplicationTarget.mode(bundleID: "helper", application: helper, modes: modes, selectedPaths: [:]), .disabled)
    }
    func testChildDisabledAndDirectStreamingRulesTakePrecedence() {
        let modes = ["launcher": "automatic", "helper": "disabled", "stream": "manual"]
        XCTAssertEqual(PadApplicationTarget.mode(bundleID: "helper", application: helper, modes: modes, selectedPaths: ["launcher": host.path]), .disabled)
        XCTAssertEqual(PadApplicationTarget.mode(bundleID: "stream", application: URL(fileURLWithPath: "/Apps/Streaming.app"), modes: modes, selectedPaths: [:]), .manual)
    }
}
