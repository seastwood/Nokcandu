import XCTest
@testable import NokcanduCore

final class AppSignerTeamTests: XCTestCase {
    func testTeamAndRequirement() {
        XCTAssertEqual(AppSigner.validTeam(" AB12CD34EF\n"), "AB12CD34EF")
        XCTAssertNil(AppSigner.validTeam("ab12cd34ef")); XCTAssertNil(AppSigner.validTeam("SHORT")); XCTAssertNil(AppSigner.validTeam("AB12CD34E\""))
        let r = AppSigner.requirement(team: "AB12CD34EF")
        XCTAssertTrue(r.contains("anchor apple generic")); XCTAssertTrue(r.contains("subject.OU] = \"AB12CD34EF\"")); XCTAssertTrue(r.hasSuffix("notarized"))
        var req: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(r as CFString, [], &req), errSecSuccess, "a valid code requirement")
        XCTAssertFalse(AppSigner.isTrustedDeveloperID(URL(fileURLWithPath: "/System/Applications/Calculator.app"), team: "AB12CD34EF"), "Apple's own app isn't this team's")
    }
}
