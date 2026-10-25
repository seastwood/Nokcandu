import XCTest
@testable import NokcanduCore

final class ProfileTests: XCTestCase {
    func sample() -> GameProfile {
        GameProfile(title: "Counter-Strike: Source", match: .init(steamAppID: 240), source: "steam", install: nil, graphics: .classic3D,
                    arguments: "-novid -fullscreen +m_rawinput 1", environment: ["DXVK_HUD": "fps"], rawMouse: 1, performance: nil,
                    fixes: nil, rating: .works, tested: nil, notes: "Smooth with raw mouse.")
    }

    func testValidProfileRoundTripsThroughIssueBody() throws {
        let p = sample()
        XCTAssertEqual(p.problems, [])
        let body = "### Profile\n\n```json\n\(p.json())\n```\n\n### Anything else?\n\n_No response_"
        XCTAssertEqual(try GameProfile.parse(body), p)
    }

    func testRejectsDangerousSettings() {
        var p = sample()
        p.environment = ["DYLD_INSERT_LIBRARIES": "x", "VK_ICD_FILENAMES": "x", "WINEDLLOVERRIDES": "/tmp/evil", "PATH": "x"]
        p.match = .init(exeName: "../evil.exe")
        p.rawMouse = 50
        let problems = p.problems.joined(separator: "\n")
        for word in ["DYLD_INSERT_LIBRARIES", "VK_ICD_FILENAMES", "PATH", "WINEDLLOVERRIDES", "exeName", "rawMouse"] {
            XCTAssertTrue(problems.contains(word), "expected a problem about \(word):\n\(problems)")
        }
        XCTAssertTrue(GameProfile.envNameAllowed("WINEDLLOVERRIDES"))
        XCTAssertTrue(GameProfile.envNameAllowed("ROSETTA_ADVERTISE_AVX"))
        XCTAssertFalse(GameProfile.envNameAllowed("NOKCANDU_RAW_MOUSE_SCALE"))
    }

    func testSubmitURLCarriesProfile() {
        let u = Profiles.submitURL(sample()).absoluteString
        XCTAssertTrue(u.hasPrefix("https://github.com/seastwood/Nokcandu/issues/new?template=game-profile.yml"))
        XCTAssertTrue(u.contains("profile="))
    }

    func testBrokenReports() {
        let e = CatalogEntry(number: 1, url: URL(string: "https://x")!, author: "a", up: 1, down: 4, comments: 0, updated: "", profile: sample())
        XCTAssertTrue(e.reportedBroken)
    }
}
