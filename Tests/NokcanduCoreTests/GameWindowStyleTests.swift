import XCTest
@testable import NokcanduCore

final class GameWindowStyleTests: XCTestCase {
    func testHostedSettingsRoundTrip() {
        var s = HostedSettings.Settings()
        XCTAssertEqual(GameWindowStyle.current(s), .gameDefault)
        for style in GameWindowStyle.allCases {
            GameWindowStyle.set(style, in: &s)
            XCTAssertEqual(GameWindowStyle.current(s), style)
        }
        GameWindowStyle.set(.gameDefault, in: &s)
        XCTAssertNil(s.borderless); XCTAssertNil(s.macFullScreen)
    }
}
