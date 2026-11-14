import XCTest
@testable import NokcanduCore

/// Someone updating across several versions sees the notes of each one they missed, newest first, ten at most.
final class ReleaseNotesSelectionTests: XCTestCase {
    private let available = ["0.9.9", "0.12.15", "0.12.16", "0.12.17", "0.12.18", "0.13.0", "0.13.1", "0.14.0"]

    func testEveryMissedVersionNewestFirst() {
        let r = ReleaseNotesSelection.missed(available: available, seen: "0.12.15", current: "0.13.1")
        XCTAssertEqual(r.versions, ["0.13.1", "0.13.0", "0.12.18", "0.12.17", "0.12.16"])
        XCTAssertFalse(r.more)
    }
    func testAnOrdinaryUpdateShowsOneVersion() {
        XCTAssertEqual(ReleaseNotesSelection.missed(available: available, seen: "0.13.0", current: "0.13.1").versions, ["0.13.1"])
    }
    func testAlreadySeenOrNothingRecordedShowsThisVersion() {
        XCTAssertEqual(ReleaseNotesSelection.missed(available: available, seen: "0.13.1", current: "0.13.1").versions, ["0.13.1"])
        XCTAssertEqual(ReleaseNotesSelection.missed(available: available, seen: nil, current: "0.13.1").versions, ["0.13.1"])
        XCTAssertEqual(ReleaseNotesSelection.missed(available: available, seen: "0.14.0", current: "0.13.1").versions, ["0.13.1"], "after rolling back")
    }
    func testNotesOfLaterVersionsAreNeverShown() {
        XCTAssertFalse(ReleaseNotesSelection.missed(available: available, seen: "0.12.18", current: "0.13.1").versions.contains("0.14.0"))
    }
    func testAVersionWithoutNotesIsSkipped() {
        XCTAssertEqual(ReleaseNotesSelection.missed(available: available, seen: "0.13.0", current: "0.13.2").versions, ["0.13.1"])
        XCTAssertEqual(ReleaseNotesSelection.missed(available: [], seen: "0.13.0", current: "0.13.1").versions, [])
    }
    func testAtMostTenAndSaysThereWereMore() {
        let many = (1...25).map { "0.1.\($0)" }
        let r = ReleaseNotesSelection.missed(available: many, seen: "0.1.3", current: "0.1.25")
        XCTAssertEqual(r.versions, (16...25).reversed().map { "0.1.\($0)" })
        XCTAssertTrue(r.more)
        XCTAssertFalse(ReleaseNotesSelection.missed(available: many, seen: "0.1.15", current: "0.1.25").more, "exactly ten")
    }
    func testVersionsSortByNumberNotByText() {
        XCTAssertEqual(ReleaseNotesSelection.missed(available: ["0.9.9", "0.10.0", "0.9.10"], seen: "0.9.8", current: "0.10.0").versions, ["0.10.0", "0.9.10", "0.9.9"])
    }
    func testFileNames() {
        XCTAssertEqual(ReleaseNotesSelection.version(fileName: "v0.13.1.md"), "0.13.1")
        XCTAssertNil(ReleaseNotesSelection.version(fileName: "README.md"))
        XCTAssertNil(ReleaseNotesSelection.version(fileName: "v.md"))
        XCTAssertNil(ReleaseNotesSelection.version(fileName: "v0.13.1.txt"))
    }
}
