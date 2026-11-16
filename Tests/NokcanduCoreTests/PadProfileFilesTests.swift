import XCTest
@testable import NokcanduCore

final class PadProfileFilesTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NokcanduProfileFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func sample() -> [PadProfiles.Profile] {
        let base = PadProfiles.Profile(name: "Base")
        var top = PadProfiles.Profile(name: "CS2", buildsOn: [base.id])
        top.base[.a] = .as(.key(49))
        var odd = PadProfiles.Profile(name: "Racing: wheel/pedals")
        odd.base[.b] = .as(.key(50))
        return [base, top, odd]
    }

    func testFileNames() {
        var taken = Set<String>()
        XCTAssertEqual(PadProfiles.fileName("Racing: wheel/pedals", taken: &taken), "Racing- wheel-pedals.nokpad.json")
        XCTAssertEqual(PadProfiles.fileName("CS2", taken: &taken), "CS2.nokpad.json")
        XCTAssertEqual(PadProfiles.fileName("cs2", taken: &taken), "cs2 (2).nokpad.json")       // file names ignore case
        XCTAssertEqual(PadProfiles.fileName(" ", taken: &taken), "Profile.nokpad.json")
        XCTAssertEqual(PadProfiles.fileName(".hidden", taken: &taken), "hidden.nokpad.json")
    }

    func testArchiveRoundTrip() throws {
        let all = sample()
        let zip = folder.appendingPathComponent("all.zip")
        try PadProfiles.exportArchive(all, all: all, to: zip)
        XCTAssertTrue(PadProfiles.archiveHasProfiles(zip))
        // On a Mac with none of them: each comes in once (Base is in two of the files), linked as before.
        let fresh = try PadProfiles.importFiles([zip], existing: [])
        XCTAssertEqual(fresh.added.map(\.name).sorted(), ["Base", "CS2", "Racing: wheel/pedals"])
        XCTAssertTrue(fresh.alreadyHere.isEmpty); XCTAssertTrue(fresh.unreadable.isEmpty)
        let base = try XCTUnwrap(fresh.added.first { $0.name == "Base" }), top = try XCTUnwrap(fresh.added.first { $0.name == "CS2" })
        XCTAssertNotEqual(base.id, all[0].id)
        XCTAssertEqual(top.buildsOn, [base.id]); XCTAssertEqual(top.base[.a], .as(.key(49)))
        XCTAssertLessThan(fresh.added.firstIndex(of: base)!, fresh.added.firstIndex(of: top)!)
        // Where they all still are: nothing is added twice.
        let again = try PadProfiles.importFiles([zip], existing: all)
        XCTAssertTrue(again.added.isEmpty); XCTAssertEqual(again.alreadyHere.sorted(), ["Base", "CS2", "Racing: wheel/pedals"])
        // Exporting over an existing zip replaces it.
        try PadProfiles.exportArchive([all[2]], all: all, to: zip)
        XCTAssertEqual(try PadProfiles.importFiles([zip], existing: []).added.map(\.name), ["Racing: wheel/pedals"])
    }

    func testChangedProfilesComeInAsCopies() throws {
        let all = sample()
        let zip = folder.appendingPathComponent("all.zip")
        try PadProfiles.exportArchive(all, all: all, to: zip)
        var here = all
        here[0].base[.x] = .as(.key(51))               // Base was changed here since the backup
        let r = try PadProfiles.importFiles([zip], existing: here)
        // The backup's Base differs, so it and what builds on it come in beside the ones here; nothing is overwritten.
        XCTAssertEqual(r.added.map(\.name), ["Base (2)", "CS2 (2)"])
        XCTAssertEqual(r.added[1].buildsOn, [r.added[0].id])
        XCTAssertEqual(r.alreadyHere, ["Racing: wheel/pedals"])
    }

    func testSingleFilesFoldersAndOtherFiles() throws {
        let all = sample()
        let files = try PadProfiles.exportFiles(all, all: all, to: folder.appendingPathComponent("out"))
        XCTAssertEqual(files.map(\.lastPathComponent), ["Base.nokpad.json", "CS2.nokpad.json", "Racing- wheel-pedals.nokpad.json"])
        XCTAssertTrue(PadProfiles.folderHasProfiles(folder.appendingPathComponent("out")))
        // One file alone carries what it builds on.
        let one = try PadProfiles.importFiles([files[1]], existing: [])
        XCTAssertEqual(one.added.map(\.name), ["Base", "CS2"])
        // A folder of them, with a file that isn't one.
        let other = folder.appendingPathComponent("out/notes.json")
        try Data(#"{"hello": 1}"#.utf8).write(to: other)
        let mixed = try PadProfiles.importFiles([folder.appendingPathComponent("out")], existing: [])
        XCTAssertEqual(mixed.added.count, 3); XCTAssertEqual(mixed.unreadable, ["notes.json"])
        XCTAssertThrowsError(try PadProfiles.importFiles([other], existing: []))
        XCTAssertTrue(PadProfiles.isProfileText(try String(contentsOf: files[0], encoding: .utf8)))
        XCTAssertFalse(PadProfiles.isProfileText("hello"))
    }
}
