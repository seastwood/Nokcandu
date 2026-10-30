import XCTest
@testable import NokcanduCore

final class WineEnvironmentTests: XCTestCase {
    func script(_ block: String) -> String { "#!/bin/bash\nCONTENTS=x\n\(block)\nexec wine game.exe\n" }

    func testEveryOlderExportBlockUpgradesToTheCurrentOne() {
        let current = script(WineEnvironment.exportLine("CONTENTS"))
        for old in WineEnvironment.versions("CONTENTS") {
            XCTAssertEqual(WineEnvironment.upgradeExports(script(old)), current, old)
        }
        XCTAssertTrue(WineEnvironment.exportLine().contains("SikarugirAppWine11=1"))
        XCTAssertTrue(WineEnvironment.exportLine().contains("ROSETTA_ADVERTISE_AVX=1"))
    }

    func testFingerprintsSeeTheOriginalLine() {
        let original = script(WineEnvironment.legacyLine("HC"))
        for block in WineEnvironment.versions("HC") {
            XCTAssertEqual(WineEnvironment.originalExports(script(block)), original, block)
        }
    }

    func testProgramsNokcanduStartsGetTheSameVariables() {
        var env: [String: String] = [:]
        WineEnvironment.apply(contents: URL(fileURLWithPath: "/Apps/Game.app/Contents"), to: &env)
        XCTAssertEqual(env["SikarugirAppWine11"], "1")
        XCTAssertEqual(env["CX_ROOT"], "/Apps/Game.app/Contents/SharedSupport/wine")
        XCTAssertEqual(env["GST_PLUGIN_PATH"], "/Apps/Game.app/Contents/Frameworks/GStreamer.framework/Libraries/gstreamer-1.0")
    }
}
